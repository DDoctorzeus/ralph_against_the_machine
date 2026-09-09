#!/usr/bin/env bash
set -Eeuo pipefail

# Dual-provider Ralph-style implementation orchestrator.
#
# Flow:
#   1. Preflight git/jq/codex/claude and authentication.
#   2. Ask Codex to turn the user prompt into dependency-aware implementation tasks.
#   3. Print the task plan.
#   4. Run ready tasks in parallel git worktrees, alternating Codex and Claude.
#   5. Each worker gets fresh-context Ralph passes until it writes STATUS: DONE.
#   6. Cherry-pick completed task commits into a temporary integration branch.
#   7. Ask Codex to validate the complete implementation.
#   8. Ask whether to cross-reference each task with the opposite provider.
#
# Required: bash 4+, git, jq, codex, claude
#
# Useful environment variables:
#   RALPH_MAX_WORKERS=2       Parallel workers per dependency wave.
#   RALPH_MAX_PASSES=4        Fresh-context passes per task.
#   RALPH_KEEP_WORKTREES=0    Keep temporary worktrees when set to 1.
#   RALPH_ALLOW_DIRTY=0       Allow starting from a dirty repository when set to 1.
#   RALPH_AUTO_YES=0          Skip the "start workers?" prompt when set to 1.
#   RALPH_RUN_ROOT            Parent directory for logs/task state/worktrees.
#                             Defaults to <repo>/.ralph, which is added to
#                             .gitignore automatically.
#   RALPH_AGENT_FAILOVER=1    Fail a task over to the other provider when its
#                             assigned agent reports a usage/credit/rate limit.
#                             Set to 0 to disable and fail the task instead.
#
# Usage:
#   ./ratm.sh "Implement ..."
#   ./ratm.sh -f prompt.md
#   cat prompt.md | ./ratm.sh

MAX_WORKERS="${RALPH_MAX_WORKERS:-2}"
MAX_PASSES="${RALPH_MAX_PASSES:-4}"
KEEP_WORKTREES="${RALPH_KEEP_WORKTREES:-0}"
ALLOW_DIRTY="${RALPH_ALLOW_DIRTY:-0}"
AUTO_YES="${RALPH_AUTO_YES:-0}"
# Left empty (rather than defaulted here) because the default lives inside
# the target repo and REPO_ROOT isn't known until after preflight, below.
RUN_ROOT="${RALPH_RUN_ROOT:-}"
AGENT_FAILOVER="${RALPH_AGENT_FAILOVER:-1}"

PROMPT_FILE=""
USER_PROMPT=""

usage() {
    cat <<'USAGE'
Usage:
  ratm.sh "implementation prompt"
  ratm.sh -f prompt.md
  cat prompt.md | ratm.sh

Environment:
  RALPH_MAX_WORKERS=2
  RALPH_MAX_PASSES=4
  RALPH_KEEP_WORKTREES=0
  RALPH_ALLOW_DIRTY=0
  RALPH_AUTO_YES=0
  RALPH_RUN_ROOT=<repo>/.ralph
  RALPH_AGENT_FAILOVER=1
USAGE
}

# Colour-coded logging helpers used throughout the script.
log()  { printf '\033[1;34m[ralph]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Portable stand-in for GNU `realpath -m` (canonicalize, allow missing
# components), which isn't available on macOS/BSD. Only the parent directory
# needs to already exist; the final path component itself may not.
abspath() {
    local path="$1" dir base
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
        return
    fi
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    mkdir -p "$dir"
    printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
}

# When the run root lives inside the target repository (the default,
# <repo>/.ralph), make sure it's excluded from version control so run
# artefacts (logs, task/plan state, worktrees) never get accidentally
# committed. A no-op if the run root is outside the repo, or already ignored.
ensure_run_root_gitignored() {
    local run_root="$1"
    local repo_root="$2"

    case "$run_root" in
        "$repo_root"/*) ;;
        *) return 0 ;;
    esac

    local rel="${run_root#"$repo_root"/}"
    local pattern="/${rel}/"
    local gitignore="$repo_root/.gitignore"

    touch "$gitignore"
    grep -qxF "$pattern" "$gitignore" && return 0

    if [[ -s "$gitignore" ]] && [[ "$(tail -c1 "$gitignore")" != $'\n' ]]; then
        printf '\n' >> "$gitignore"
    fi
    printf '%s\n' "$pattern" >> "$gitignore"
    log "Added $pattern to .gitignore for Ralph run artefacts. This is an uncommitted change to $gitignore -- commit it when convenient."
}

# Parse CLI args: -f/--file <path>, -h/--help, a bare prompt string, or
# nothing (in which case the prompt is read from stdin below).
while (($#)); do
    case "$1" in
        -f|--file)
            (($# >= 2)) || die "$1 requires a file"
            PROMPT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            USER_PROMPT="$*"
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            USER_PROMPT="$*"
            break
            ;;
    esac
done

if [[ -n "$PROMPT_FILE" ]]; then
    [[ -r "$PROMPT_FILE" ]] || die "Cannot read prompt file: $PROMPT_FILE"
    USER_PROMPT="$(cat "$PROMPT_FILE")"
elif [[ -z "$USER_PROMPT" && ! -t 0 ]]; then
    USER_PROMPT="$(cat)"
fi

[[ -n "${USER_PROMPT//[[:space:]]/}" ]] || {
    usage
    die "No implementation prompt supplied"
}

is_positive_int "$MAX_WORKERS" || die "RALPH_MAX_WORKERS must be a positive integer"
is_positive_int "$MAX_PASSES" || die "RALPH_MAX_PASSES must be a positive integer"
[[ "$AGENT_FAILOVER" == "0" || "$AGENT_FAILOVER" == "1" ]] || die "RALPH_AGENT_FAILOVER must be 0 or 1"
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || die "Bash 4+ is required"

for cmd in git jq codex claude; do
    require_cmd "$cmd"
done

# Everything below assumes the repo root as the working directory and derives
# a unique, filesystem-safe run directory from the repo name, timestamp and PID.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this from inside a git repository"
cd "$REPO_ROOT"

# Default run root lives inside the repo (so a run's logs/task state/
# worktrees are easy to find) and is normalised to an absolute path so the
# containment check in ensure_run_root_gitignored() works reliably.
RUN_ROOT="$(abspath "${RUN_ROOT:-$REPO_ROOT/.ralph}")"

BASE_COMMIT="$(git rev-parse HEAD)"
REPO_NAME="$(basename "$REPO_ROOT" | tr -cs 'A-Za-z0-9._-' '-')"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

# Cache --help output so both the feature checks below and codex_exec()'s
# flag detection (further down) can grep it without re-invoking the CLIs.
CODEX_HELP="$(codex --help 2>&1 || true)"
CODEX_EXEC_HELP="$(codex exec --help 2>&1 || true)"
CLAUDE_HELP="$(claude --help 2>&1 || true)"

[[ "$CODEX_EXEC_HELP" == *"--output-schema"* ]] || die "Codex CLI is too old: codex exec lacks --output-schema"
[[ "$CODEX_EXEC_HELP" == *"--output-last-message"* || "$CODEX_EXEC_HELP" == *"-o,"* ]] || die "Codex CLI is too old: codex exec lacks --output-last-message/-o"
[[ "$CODEX_EXEC_HELP" == *"--sandbox"* ]] || die "Codex CLI is too old: codex exec lacks --sandbox"
[[ "$CLAUDE_HELP" == *"--print"* || "$CLAUDE_HELP" == *"-p"* ]] || die "Claude Code CLI lacks non-interactive print mode"

# Checked before touching anything on disk (including .gitignore, below) so
# this check reflects the repo's pristine state rather than our own bootstrap.
if [[ "$ALLOW_DIRTY" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
    die "Repository is dirty. Commit/stash first or set RALPH_ALLOW_DIRTY=1 (workers always start from HEAD)."
fi

# Only touches .gitignore when the run root is the in-repo default; a custom
# RALPH_RUN_ROOT outside the repo is left alone. Safe to call on every run:
# it's a no-op once the ignore pattern is already present.
ensure_run_root_gitignored "$RUN_ROOT" "$REPO_ROOT"

RUN_DIR="$RUN_ROOT/ralph-${REPO_NAME}-${RUN_ID}"
WORKTREE_DIR="$RUN_DIR/worktrees"
LOG_DIR="$RUN_DIR/logs"
TASK_DIR="$RUN_DIR/tasks"
REVIEW_DIR="$RUN_DIR/reviews"
mkdir -p "$WORKTREE_DIR" "$LOG_DIR" "$TASK_DIR" "$REVIEW_DIR"

PLAN_SCHEMA="$RUN_DIR/plan.schema.json"
PLAN_JSON="$RUN_DIR/tasks.json"
PLAN_PROMPT="$RUN_DIR/plan.prompt.md"
VALIDATION_SCHEMA="$RUN_DIR/validation.schema.json"
VALIDATION_JSON="$RUN_DIR/validation.json"
VALIDATION_PROMPT="$RUN_DIR/validation.prompt.md"
ASSIGNMENTS="$RUN_DIR/assignments.tsv"
: > "$ASSIGNMENTS"

INTEGRATION_BRANCH="ralph/$RUN_ID"
INTEGRATION_WT="$WORKTREE_DIR/integration"

log "Preflight"
printf '  git:    %s\n' "$(git --version)"
printf '  jq:     %s\n' "$(jq --version)"
printf '  codex:  %s\n' "$(codex --version 2>&1 | head -n1)"
printf '  claude: %s\n' "$(claude --version 2>&1 | head -n1)"

CODEX_LOGIN="$(codex login status 2>&1 || true)"
if grep -qiE 'not logged|logged out|unauthenticated' <<<"$CODEX_LOGIN"; then
    die "Codex is not authenticated: $CODEX_LOGIN"
fi
ok "Codex auth: ${CODEX_LOGIN//$'\n'/ }"

if claude auth status --json >"$RUN_DIR/claude-auth.json" 2>/dev/null; then
    if jq -e 'if has("loggedIn") then .loggedIn == true elif has("logged_in") then .logged_in == true else true end' \
        "$RUN_DIR/claude-auth.json" >/dev/null 2>&1; then
        CLAUDE_SUB="$(jq -r '.subscriptionType // .subscription_type // "authenticated"' "$RUN_DIR/claude-auth.json" 2>/dev/null || echo authenticated)"
        ok "Claude auth: $CLAUDE_SUB"
    else
        die "Claude Code reports that it is not authenticated"
    fi
else
    warn "Could not query 'claude auth status --json'; authentication will be verified by the first Claude worker."
fi

# Run one non-interactive Codex pass reading its prompt from stdin.
# sandbox: read-only|workspace-write, cwd: directory codex operates in,
# prompt_file: piped in as the instruction, output_file: final message dest,
# schema_file: optional JSON schema forcing structured output.
codex_exec() {
    local sandbox="$1"
    local cwd="$2"
    local prompt_file="$3"
    local output_file="$4"
    local schema_file="${5:-}"
    local -a cmd=(codex)

    # Current Codex puts --ask-for-approval at the top level rather than after
    # 'exec'. Detect it so the wrapper also works across older/newer releases.
    if [[ "$CODEX_HELP" == *"--ask-for-approval"* ]]; then
        cmd+=(--ask-for-approval never)
    fi

    cmd+=(exec --sandbox "$sandbox")

    if [[ "$CODEX_EXEC_HELP" == *"--ephemeral"* ]]; then
        cmd+=(--ephemeral)
    fi

    if [[ "$CODEX_EXEC_HELP" == *"--cwd"* || "$CODEX_EXEC_HELP" == *"-C,"* ]]; then
        cmd+=(-C "$cwd")
    fi

    cmd+=(--output-last-message "$output_file")

    if [[ -n "$schema_file" ]]; then
        cmd+=(--output-schema "$schema_file")
    fi

    cmd+=(-)

    if [[ "$CODEX_EXEC_HELP" == *"--cwd"* || "$CODEX_EXEC_HELP" == *"-C,"* ]]; then
        "${cmd[@]}" < "$prompt_file"
    else
        (cd "$cwd" && "${cmd[@]}" < "$prompt_file")
    fi
}

# Run one non-interactive Claude Code pass in acceptEdits mode, restricted to
# a fixed tool set (no --dangerously-skip-permissions).
claude_worker_exec() {
    local cwd="$1"
    local prompt_file="$2"
    local log_file="$3"

    # Explicit tool allow-list keeps print mode non-interactive without using
    # --dangerously-skip-permissions.
    (
        cd "$cwd"
        claude -p "$(cat "$prompt_file")" \
            --output-format json \
            --permission-mode acceptEdits \
            --allowedTools Read Write Edit Glob Grep Bash
    ) > "$log_file" 2>&1
}

# Loose heuristic for spotting a provider usage/credit/rate-limit error in a
# worker's captured output, used to trigger RALPH_AGENT_FAILOVER. Deliberately
# broad since Codex and Claude Code do not share a common error format.
is_credit_limit_error() {
    grep -qiE \
        'usage limit|rate.?limit|too many requests|quota exceeded|insufficient[ _]quota|insufficient credit|out of credits|credit limit|billing hard limit|exceeded your current quota|usage cap|upgrade your plan|\b429\b' \
        "$1" 2>/dev/null
}

# Registered as an EXIT trap so worker/integration worktrees are always torn
# down (unless RALPH_KEEP_WORKTREES=1), even on error or early die().
cleanup_worktrees() {
    [[ "$KEEP_WORKTREES" == "1" ]] && return 0

    if [[ -d "$WORKTREE_DIR" ]]; then
        while IFS= read -r -d '' wt; do
            git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
        done < <(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    fi
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup_worktrees EXIT

# JSON schema forced onto Codex's planning pass output: a project summary plus
# a dependency-aware list of implementation tasks (id, title, description,
# acceptance criteria, dependency task IDs).
cat > "$PLAN_SCHEMA" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "project_summary": { "type": "string", "minLength": 1 },
    "tasks": {
      "type": "array",
      "minItems": 1,
      "maxItems": 12,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "id": { "type": "string", "pattern": "^T[0-9]{2}$" },
          "title": { "type": "string", "minLength": 1 },
          "description": { "type": "string", "minLength": 1 },
          "acceptance_criteria": {
            "type": "array",
            "minItems": 1,
            "items": { "type": "string", "minLength": 1 }
          },
          "dependencies": {
            "type": "array",
            "items": { "type": "string", "pattern": "^T[0-9]{2}$" }
          }
        },
        "required": ["id", "title", "description", "acceptance_criteria", "dependencies"]
      }
    }
  },
  "required": ["project_summary", "tasks"]
}
JSON

cat > "$PLAN_PROMPT" <<EOF
You are the planning/orchestration pass for an autonomous implementation run.

Repository: $REPO_ROOT
Base commit: $BASE_COMMIT

User implementation request:

---
$USER_PROMPT
---

Inspect the repository thoroughly enough to produce the implementation plan.
Return ONLY data matching the supplied JSON schema.

Planning rules:
1. Produce implementation tasks, not research-only or management tasks.
2. Prefer 2-8 cohesive tasks. Do not fragment trivial edits into many tickets.
3. Each task must be independently understandable by a fresh coding agent.
4. Add explicit acceptance criteria that can be checked from code/tests.
5. Add dependencies only where a task genuinely requires another task's code.
6. Tasks with no dependency relationship should minimise overlapping files so they can run in parallel worktrees.
7. Order task IDs approximately in implementation order: T01, T02, ...
8. Do not include git merge/cherry-pick/release tasks; the orchestrator handles integration.
9. Do not assign agents. The orchestrator balances Codex and Claude.
10. Include test changes in the task that owns the behaviour where practical rather than creating a separate test-only task.
EOF

# Ask Codex (read-only sandbox: it must not modify the repo while planning)
# to inspect the repository and turn the user prompt into structured tasks.
log "Generating implementation tasks with Codex"
if ! codex_exec read-only "$REPO_ROOT" "$PLAN_PROMPT" "$PLAN_JSON" "$PLAN_SCHEMA" \
    >"$LOG_DIR/planner.log" 2>&1; then
    cat "$LOG_DIR/planner.log" >&2
    die "Codex planning pass failed"
fi

# Sanity-check the planner's output before trusting it to drive scheduling:
# well-formed JSON, at least one task, no duplicate/unknown/self-referential
# dependency IDs.
jq -e '.project_summary | type == "string"' "$PLAN_JSON" >/dev/null || die "Planner returned invalid JSON"
jq -e '.tasks | type == "array" and length > 0' "$PLAN_JSON" >/dev/null || die "Planner returned no tasks"

DUP_IDS="$(jq -r '[.tasks[].id] | group_by(.)[] | select(length > 1) | .[0]' "$PLAN_JSON")"
[[ -z "$DUP_IDS" ]] || die "Planner returned duplicate task IDs: $DUP_IDS"

UNKNOWN_DEPS="$(jq -r '
  [.tasks[].id] as $ids |
  [.tasks[] | .id as $id | .dependencies[]? | select((. as $d | $ids | index($d)) == null) | "\($id)->\(.)"] |
  .[]?
' "$PLAN_JSON")"
[[ -z "$UNKNOWN_DEPS" ]] || die "Planner returned unknown dependencies: $UNKNOWN_DEPS"

SELF_DEPS="$(jq -r '.tasks[] | .id as $id | .dependencies[]? | select(. == $id) | $id' "$PLAN_JSON")"
[[ -z "$SELF_DEPS" ]] || die "Planner returned self-dependent tasks: $SELF_DEPS"

printf '\n\033[1mImplementation plan\033[0m\n'
printf '%s\n\n' "$(jq -r '.project_summary' "$PLAN_JSON")"
jq -r '
  .tasks[] |
  "\(.id)  \(.title)" +
  "\n    Depends: " + (if (.dependencies | length) == 0 then "none" else (.dependencies | join(", ")) end) +
  "\n    \(.description)" +
  "\n" + (.acceptance_criteria | map("      - " + .) | join("\n")) + "\n"
' "$PLAN_JSON"

if [[ "$AUTO_YES" != "1" ]]; then
    read -r -p "Spawn Codex/Claude workers for this plan? [Y/n] " answer
    case "${answer:-y}" in
        y|Y|yes|YES) ;;
        *) die "Cancelled before worker execution. Plan retained at $PLAN_JSON" ;;
    esac
fi

git branch "$INTEGRATION_BRANCH" "$BASE_COMMIT"
git worktree add -q "$INTEGRATION_WT" "$INTEGRATION_BRANCH"
ok "Integration branch: $INTEGRATION_BRANCH"

declare -A STATUS
declare -A AGENT
declare -A WORKER_COMMIT
declare -A INTEGRATED_COMMIT
declare -A WORKTREE_PATH
declare -A TASK_BRANCH

mapfile -t TASK_IDS < <(jq -r '.tasks[].id' "$PLAN_JSON")
for id in "${TASK_IDS[@]}"; do
    STATUS["$id"]="pending"
done

AGENT_COUNTER=0

make_task_file() {
    local id="$1"
    jq --arg id "$id" '.tasks[] | select(.id == $id)' "$PLAN_JSON" > "$TASK_DIR/$id.json"
}

# Run the fresh-context Ralph loop for one task: write .ralph-task.md and an
# initial .ralph-progress.md into the worker's worktree, then repeatedly
# invoke the assigned agent (codex or claude) until it writes
# "STATUS: DONE" to .ralph-progress.md or MAX_PASSES is exhausted.
# On success, commits the worktree changes and records the commit hash for
# integrate_task() to cherry-pick later. Returns 1 on a worker execution
# failure, 2 if passes were exhausted without STATUS: DONE.
run_task_worker() {
    local id="$1"
    local agent="$2"
    local wt="$3"
    local branch="$4"
    local task_json="$TASK_DIR/$id.json"
    local title
    local progress="$wt/.ralph-progress.md"
    local task_md="$wt/.ralph-task.md"
    local worker_prompt="$TASK_DIR/$id.worker-prompt.md"
    local task_log="$LOG_DIR/$id-$agent.log"

    title="$(jq -r '.title' "$task_json")"

    cat > "$task_md" <<EOF
# Ralph task $id: $title

$(jq -r '"## Description\n\n" + .description + "\n\n## Acceptance criteria\n" + (.acceptance_criteria | map("- " + .) | join("\n"))' "$task_json")

## Original implementation request

$USER_PROMPT
EOF

    cat > "$progress" <<'PROGRESS'
STATUS: CONTINUE
SUMMARY: No work completed yet.
TESTS: Not run yet.
REMAINING: Inspect the task and repository, then implement it.
PROGRESS

    cat > "$worker_prompt" <<'WORKER'
You are an autonomous implementation worker in a Ralph-style fresh-context loop.

Start by reading .ralph-task.md and .ralph-progress.md in the current worktree, then inspect the repository and git diff/status.

Rules:
- Implement only the assigned task and its acceptance criteria.
- Continue existing work from prior passes rather than restarting it.
- Work only inside this git worktree.
- Do not commit, push, merge, rebase or modify git remotes. The orchestrator owns integration.
- Follow the repository's existing instructions and conventions.
- Run the most relevant tests, linters, type checks or builds available for the changed area.
- Do not weaken/remove tests merely to make a run pass.
- Avoid unrelated refactors.

At the END of every pass, overwrite .ralph-progress.md in this exact shape:

STATUS: DONE
SUMMARY: <brief summary of implementation>
TESTS: <commands run and results>
REMAINING: none

Use STATUS: DONE only if every acceptance criterion is implemented and the task is genuinely ready to integrate.
If work remains, instead use:

STATUS: CONTINUE
SUMMARY: <what this pass completed>
TESTS: <commands run and results>
REMAINING: <specific next actions>

Do not merely describe code changes: make the changes in the worktree.
WORKER

    : > "$task_log"

    # failed_over tracks whether this task has already been redirected to the
    # other provider, so a task can fail over at most once (never ping-pongs
    # back and forth) even if RALPH_AGENT_FAILOVER is enabled.
    local pass=1
    local pass_out
    local failed_over=0
    while ((pass <= MAX_PASSES)); do
        printf '\n===== PASS %d/%d (%s) =====\n' "$pass" "$MAX_PASSES" "$agent" >> "$task_log"

        if [[ "$agent" == "codex" ]]; then
            pass_out="$LOG_DIR/$id-codex-pass-$pass.txt"
            if ! codex_exec workspace-write "$wt" "$worker_prompt" "$pass_out" \
                >>"$task_log" 2>&1; then
                if [[ "$AGENT_FAILOVER" == "1" ]] && ((! failed_over)) && is_credit_limit_error "$task_log"; then
                    warn "$id Codex appears to have hit a usage/credit limit; failing over to Claude"
                    agent="claude"
                    failed_over=1
                    printf '%s\n' "$agent" > "$TASK_DIR/$id.final-agent"
                    continue
                fi
                warn "$id Codex pass $pass failed; see $task_log"
                return 1
            fi
            cat "$pass_out" >> "$task_log" 2>/dev/null || true
        else
            pass_out="$LOG_DIR/$id-claude-pass-$pass.json"
            if ! claude_worker_exec "$wt" "$worker_prompt" "$pass_out"; then
                cat "$pass_out" >> "$task_log" 2>/dev/null || true
                if [[ "$AGENT_FAILOVER" == "1" ]] && ((! failed_over)) && is_credit_limit_error "$task_log"; then
                    warn "$id Claude appears to have hit a usage/credit limit; failing over to Codex"
                    agent="codex"
                    failed_over=1
                    printf '%s\n' "$agent" > "$TASK_DIR/$id.final-agent"
                    continue
                fi
                warn "$id Claude pass $pass failed; see $task_log"
                return 1
            fi
            cat "$pass_out" >> "$task_log" 2>/dev/null || true
        fi

        if grep -qx 'STATUS: DONE' "$progress"; then
            break
        fi
        ((pass+=1))
    done

    if ! grep -qx 'STATUS: DONE' "$progress"; then
        warn "$id exhausted $MAX_PASSES passes without STATUS: DONE"
        return 2
    fi

    rm -f "$task_md" "$progress"

    git -C "$wt" add -A
    git -C "$wt" \
        -c user.name='Ralph Orchestrator' \
        -c user.email='ralph@localhost' \
        commit --allow-empty -m "ralph($id): $title" >/dev/null

    git -C "$wt" rev-parse HEAD > "$TASK_DIR/$id.worker-commit"
    return 0
}

# Called when integrate_task()'s cherry-pick hits a conflict. Asks Codex to
# resolve it directly in the (disposable) integration worktree, then
# continues the cherry-pick if the conflict markers are gone.
resolve_cherry_pick_conflict() {
    local id="$1"
    local source_commit="$2"
    local prompt="$TASK_DIR/$id.conflict-prompt.md"
    local out="$LOG_DIR/$id-conflict-resolution.txt"

    cat > "$prompt" <<EOF
A cherry-pick for task $id ($source_commit) has conflicts in this disposable integration worktree.

Resolve the current git conflict while preserving the intended behaviour of both the already-integrated work and task $id.
Inspect the conflict, the task plan at $PLAN_JSON and relevant surrounding code.
Do not abort the cherry-pick, commit, push, merge or rebase.
Resolve files only and run focused checks where practical.
EOF

    warn "$id cherry-pick conflicted; asking Codex to resolve the integration conflict"
    if ! codex_exec workspace-write "$INTEGRATION_WT" "$prompt" "$out" \
        >>"$LOG_DIR/$id-conflict-resolution.log" 2>&1; then
        return 1
    fi

    if git -C "$INTEGRATION_WT" diff --name-only --diff-filter=U | grep -q .; then
        return 1
    fi

    git -C "$INTEGRATION_WT" add -A
    GIT_EDITOR=true git -C "$INTEGRATION_WT" \
        -c user.name='Ralph Orchestrator' \
        -c user.email='ralph@localhost' \
        cherry-pick --continue >/dev/null
}

# Cherry-pick a completed task's commit onto the shared integration branch,
# falling back to Codex conflict resolution on failure.
integrate_task() {
    local id="$1"
    local commit="$2"

    # --allow-empty is required here: run_task_worker() commits with
    # --allow-empty too, since some tasks (e.g. ones that only touch files
    # outside the repo) legitimately produce no repo diff.
    if ! git -C "$INTEGRATION_WT" cherry-pick --allow-empty "$commit" >/dev/null 2>"$LOG_DIR/$id-cherry-pick.err"; then
        if ! resolve_cherry_pick_conflict "$id" "$commit"; then
            git -C "$INTEGRATION_WT" cherry-pick --abort >/dev/null 2>&1 || true
            return 1
        fi
    fi

    git -C "$INTEGRATION_WT" rev-parse HEAD > "$TASK_DIR/$id.integrated-commit"
}

# Task-scheduling helpers driving the dependency-wave loop below: is every
# task done, how many are still pending, and is a given task's dependency
# list fully satisfied (i.e. ready to run this wave).
all_done() {
    local id
    for id in "${TASK_IDS[@]}"; do
        [[ "${STATUS[$id]}" == "done" ]] || return 1
    done
    return 0
}

pending_count() {
    local n=0 id
    for id in "${TASK_IDS[@]}"; do
        [[ "${STATUS[$id]}" == "pending" ]] && ((n+=1))
    done
    printf '%d\n' "$n"
}

task_ready() {
    local id="$1"
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        [[ "${STATUS[$dep]:-missing}" == "done" ]] || return 1
    done < <(jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .dependencies[]?' "$PLAN_JSON")
    return 0
}

# Main scheduling loop: each iteration is one "wave" that runs every
# currently-ready task (up to MAX_WORKERS in parallel) in its own worktree,
# waits for all of them, then integrates and marks them done before the next
# wave picks up newly-unblocked tasks.
WAVE=0
while ! all_done; do
    ((WAVE+=1))
    READY=()

    for id in "${TASK_IDS[@]}"; do
        if [[ "${STATUS[$id]}" == "pending" ]] && task_ready "$id"; then
            READY+=("$id")
        fi
    done

    if ((${#READY[@]} == 0)); then
        die "No runnable task remains but $(pending_count) tasks are pending. Dependency cycle or failed prerequisite."
    fi

    BATCH=("${READY[@]:0:MAX_WORKERS}")
    printf '\n\033[1mWave %d\033[0m\n' "$WAVE"

    declare -A ID_TO_PID=()

    for id in "${BATCH[@]}"; do
        make_task_file "$id"

        # Alternate agents across the run so ready tasks are balanced
        # between Codex and Claude rather than one provider doing everything.
        if ((AGENT_COUNTER % 2 == 0)); then
            agent="codex"
        else
            agent="claude"
        fi
        ((AGENT_COUNTER+=1))

        safe_id="$(printf '%s' "$id" | tr -cs 'A-Za-z0-9._-' '-')"
        branch="${INTEGRATION_BRANCH}-${safe_id}"
        wt="$WORKTREE_DIR/$safe_id"

        AGENT["$id"]="$agent"
        TASK_BRANCH["$id"]="$branch"
        WORKTREE_PATH["$id"]="$wt"
        STATUS["$id"]="running"

        git worktree add -q -b "$branch" "$wt" "$INTEGRATION_BRANCH"

        printf '  %-4s %-6s %s\n' "$id" "$agent" "$(jq -r '.title' "$TASK_DIR/$id.json")"

        # Launch the worker in the background so this wave's tasks run
        # concurrently; PIDs are collected below so we can wait on each.
        run_task_worker "$id" "$agent" "$wt" "$branch" &
        ID_TO_PID["$id"]=$!
    done

    FAILED=0
    for id in "${BATCH[@]}"; do
        pid="${ID_TO_PID[$id]}"
        result=0
        wait "$pid" || result=$?

        # run_task_worker runs in a background subshell, so a mid-task
        # failover (agent switched due to a credit/usage limit) can't update
        # this parent shell's AGENT array directly; it's relayed via a file.
        if [[ -f "$TASK_DIR/$id.final-agent" ]]; then
            AGENT["$id"]="$(cat "$TASK_DIR/$id.final-agent")"
        fi

        if ((result == 0)); then
            STATUS["$id"]="implemented"
            ok "$id ${AGENT[$id]} worker completed"
        else
            STATUS["$id"]="failed"
            FAILED=1
            warn "$id ${AGENT[$id]} worker failed"
        fi
    done

    if ((FAILED)); then
        die "One or more workers failed. Logs and worktrees are under $RUN_DIR"
    fi

    # Serial integration is intentional: all tasks in this wave started from the
    # same integration HEAD, so independent results are cherry-picked one by one.
    for id in "${BATCH[@]}"; do
        commit="$(cat "$TASK_DIR/$id.worker-commit")"
        WORKER_COMMIT["$id"]="$commit"

        if ! integrate_task "$id" "$commit"; then
            STATUS["$id"]="failed"
            die "Could not integrate $id. See $LOG_DIR/$id-cherry-pick.err"
        fi

        integrated="$(cat "$TASK_DIR/$id.integrated-commit")"
        INTEGRATED_COMMIT["$id"]="$integrated"
        STATUS["$id"]="done"
        printf '%s\t%s\t%s\t%s\n' "$id" "${AGENT[$id]}" "$commit" "$integrated" >> "$ASSIGNMENTS"
        ok "$id integrated as ${integrated:0:12}"

        if [[ "$KEEP_WORKTREES" != "1" ]]; then
            git worktree remove --force "${WORKTREE_PATH[$id]}" >/dev/null 2>&1 || true
            git branch -D "${TASK_BRANCH[$id]}" >/dev/null 2>&1 || true
        fi
    done
done

# JSON schema forced onto Codex's final validation pass: a PASS/WARN/FAIL
# verdict, a summary, the checks it ran, and any issues found.
cat > "$VALIDATION_SCHEMA" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "verdict": { "type": "string", "enum": ["PASS", "WARN", "FAIL"] },
    "summary": { "type": "string", "minLength": 1 },
    "tests_run": {
      "type": "array",
      "items": { "type": "string" }
    },
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low"] },
          "task_id": { "type": ["string", "null"] },
          "description": { "type": "string" },
          "suggested_fix": { "type": "string" }
        },
        "required": ["severity", "task_id", "description", "suggested_fix"]
      }
    }
  },
  "required": ["verdict", "summary", "tests_run", "issues"]
}
JSON

cat > "$VALIDATION_PROMPT" <<EOF
You are the final independent validator for an autonomous implementation.

Base commit: $BASE_COMMIT
Integration branch: $INTEGRATION_BRANCH
Task plan: $PLAN_JSON

Original request:
---
$USER_PROMPT
---

Review the COMPLETE change from $BASE_COMMIT..HEAD against the original request and every task acceptance criterion.
Inspect the actual repository and diff. Run relevant tests, linters, builds and type checks where practical.
Do not intentionally change the implementation. This is a validation pass, not an implementation pass.

Verdict rules:
- PASS: implementation satisfies the request with no material issues found.
- WARN: broadly correct but there are non-blocking concerns worth human attention.
- FAIL: acceptance criteria are unmet, tests materially fail or there is a significant correctness/regression issue.

Return only data matching the supplied JSON schema.
EOF

# Independent whole-repo validation pass, run in workspace-write mode so
# Codex can execute tests/builds (but is not meant to change the implementation).
printf '\n\033[1mCodex validation\033[0m\n'
if ! codex_exec workspace-write "$INTEGRATION_WT" "$VALIDATION_PROMPT" "$VALIDATION_JSON" "$VALIDATION_SCHEMA" \
    >"$LOG_DIR/validator.log" 2>&1; then
    cat "$LOG_DIR/validator.log" >&2
    die "Codex validation pass failed"
fi

# Validation can use workspace-write so builds/tests can create artifacts. Throw
# away anything the validator itself changed in this disposable worktree.
git -C "$INTEGRATION_WT" reset --hard HEAD >/dev/null
git -C "$INTEGRATION_WT" clean -fd >/dev/null

jq -e '.verdict and .summary and .issues' "$VALIDATION_JSON" >/dev/null || die "Validator returned invalid JSON"

VERDICT="$(jq -r '.verdict' "$VALIDATION_JSON")"
printf 'Verdict: %s\n' "$VERDICT"
printf '%s\n' "$(jq -r '.summary' "$VALIDATION_JSON")"

if [[ "$(jq '.tests_run | length' "$VALIDATION_JSON")" -gt 0 ]]; then
    printf '\nTests/checks:\n'
    jq -r '.tests_run[] | "  - " + .' "$VALIDATION_JSON"
fi

if [[ "$(jq '.issues | length' "$VALIDATION_JSON")" -gt 0 ]]; then
    printf '\nIssues:\n'
    jq -r '.issues[] | "  [\(.severity)] " + (if .task_id then "\(.task_id): " else "" end) + .description + "\n      Fix: " + .suggested_fix' "$VALIDATION_JSON"
fi

# Optional second-opinion review: hand each integrated task's diff to the
# *other* provider (the one that didn't implement it) and save its review.
cross_reference_task() {
    local id="$1"
    local author="$2"
    local commit="$3"
    local review_file="$REVIEW_DIR/$id.md"
    local input_file="$REVIEW_DIR/$id.input.md"
    local task_json="$TASK_DIR/$id.json"

    {
        printf '# Task\n\n'
        cat "$task_json"
        printf '\n\n# Integrated commit\n\n%s\n\n# Patch\n\n' "$commit"
        git -C "$INTEGRATION_WT" show --format=fuller --find-renames "$commit"
    } > "$input_file"

    if [[ "$author" == "codex" ]]; then
        local json_out="$REVIEW_DIR/$id.claude.json"
        if cat "$input_file" | (
            cd "$INTEGRATION_WT"
            claude -p \
                "Act as an independent code reviewer. Review the supplied task and patch for correctness, regressions, missed acceptance criteria and test gaps. Be concise but specific. Do not modify files." \
                --output-format json \
                --permission-mode plan
        ) > "$json_out" 2>&1; then
            jq -r '.result // .' "$json_out" > "$review_file" 2>/dev/null || cp "$json_out" "$review_file"
        else
            cp "$json_out" "$review_file"
            return 1
        fi
    else
        local prompt="$REVIEW_DIR/$id.codex-prompt.md"
        cat > "$prompt" <<EOF
Act as an independent code reviewer for task $id, implemented by Claude.
Review integrated commit $commit against $task_json and the surrounding repository.
Look for correctness problems, regressions, missed acceptance criteria, architectural problems and test gaps.
Do not modify files. Give a concise, specific review and explicitly say when no material issue is found.
EOF
        codex_exec read-only "$INTEGRATION_WT" "$prompt" "$review_file" \
            >"$REVIEW_DIR/$id.codex.log" 2>&1
    fi
}

printf '\n'
read -r -p "Cross-reference each task with the opposite provider? [y/N] " CROSS
case "${CROSS:-n}" in
    y|Y|yes|YES)
        printf '\n\033[1mCross-reference reviews\033[0m\n'
        CROSS_REPORT="$RUN_DIR/cross-reference.md"
        : > "$CROSS_REPORT"

        while IFS=$'\t' read -r id author worker_commit integrated_commit; do
            if [[ "$author" == "codex" ]]; then reviewer="claude"; else reviewer="codex"; fi
            printf '  %-4s %-6s -> %-6s ... ' "$id" "$author" "$reviewer"
            if cross_reference_task "$id" "$author" "$integrated_commit"; then
                printf 'done\n'
            else
                printf 'failed\n'
            fi

            {
                printf '## %s (%s -> %s)\n\n' "$id" "$author" "$reviewer"
                cat "$REVIEW_DIR/$id.md" 2>/dev/null || printf 'Review failed.\n'
                printf '\n\n'
            } >> "$CROSS_REPORT"
        done < "$ASSIGNMENTS"

        printf '\nCross-reference report: %s\n' "$CROSS_REPORT"
        ;;
    *)
        log "Cross-reference skipped"
        ;;
esac

printf '\n\033[1mRun complete\033[0m\n'
printf '  Base:        %s\n' "$BASE_COMMIT"
printf '  Branch:      %s\n' "$INTEGRATION_BRANCH"
printf '  Validation:  %s\n' "$VALIDATION_JSON"
printf '  State/logs:  %s\n' "$RUN_DIR"

if [[ "$VERDICT" == "FAIL" ]]; then
    warn "Codex validation verdict is FAIL. The integration branch is retained for inspection/rework."
elif [[ "$VERDICT" == "WARN" ]]; then
    warn "Codex validation verdict is WARN. Review the reported concerns before merging."
else
    ok "Codex validation passed"
fi
