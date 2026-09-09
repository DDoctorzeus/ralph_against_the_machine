# Ralph Against the Machine

> **Two agents enter. Git decides what survives.**

Ralph Against the Machine is a small Bash orchestrator for running **Codex** and **Claude Code** together as autonomous, fresh-context implementation workers.

Give it an implementation prompt and Ralph Against the Machine will:

1. Check that the required tooling and authentication are available.
2. Ask Codex to inspect the repository and turn the request into a dependency-aware implementation plan.
3. Show you the proposed tasks before anything starts changing code.
4. Spawn Codex and Claude workers in isolated Git worktrees.
5. Re-run each worker in a Ralph-style loop until its task reports completion or reaches the pass limit.
6. Integrate completed tasks into a dedicated branch in dependency order.
7. Ask Codex to independently validate the complete implementation.
8. Optionally cross-reference every task with the *other* provider.

In short: two AI coding agents, separate worktrees, one increasingly nervous Git repository.

## Why?

Codex and Claude Code are both useful autonomous coding agents, but they have separate subscriptions, separate context windows and somewhat different strengths.

Rather than choosing one, Ralph Against the Machine lets them work concurrently while keeping their changes isolated and giving the completed result an independent validation pass.

The goal is not to have two agents edit the same checkout simultaneously and hope for the best. Ralph Against the Machine uses Git worktrees, dependency-aware scheduling and serial integration so parallelism stays reasonably civilised.

## Requirements

Ralph Against the Machine expects the following commands to be available:

- Bash 4+
- `git`
- `jq`
- `codex`
- `claude`

Both Codex and Claude Code should already be authenticated with their respective accounts/subscriptions.

### macOS

macOS ships Bash 3.2, which is too old (no associative arrays, no `mapfile`). Install a current Bash via Homebrew and run the script with it explicitly:

```bash
brew install bash
$(brew --prefix)/bin/bash ./ratm.sh -f prompt.md
```

Everything else in the script sticks to POSIX/BSD-compatible shell and coreutils usage, so no other changes should be needed on macOS.

Ralph Against the Machine also checks that the installed Codex CLI supports the structured output and sandbox features it relies on, and that Claude Code supports non-interactive print mode.

## Usage

Pass a prompt directly:

```bash
./ratm.sh "Implement an audit logging system for all administrative operations"
```

Use a prompt file:

```bash
./ratm.sh -f implementation-prompt.md
```

Or pipe one in:

```bash
cat implementation-prompt.md | ./ratm.sh
```

Run Ralph Against the Machine from somewhere inside the Git repository you want it to modify.

## What happens

A typical run looks roughly like this:

```text
                         implementation prompt
                                  │
                                  ▼
                         ┌─────────────────┐
                         │  Codex planner  │
                         └────────┬────────┘
                                  │
                         dependency-aware tasks
                                  │
                 ┌────────────────┴────────────────┐
                 ▼                                 ▼
          ┌─────────────┐                   ┌─────────────┐
          │ Codex Ralph │                   │Claude Ralph │
          │  worktree   │                   │  worktree   │
          └──────┬──────┘                   └──────┬──────┘
                 │                                 │
                 └────────────────┬────────────────┘
                                  ▼
                         integration branch
                                  │
                        dependent task waves
                                  │
                                  ▼
                         ┌─────────────────┐
                         │ Codex validator │
                         └────────┬────────┘
                                  │
                           PASS / WARN / FAIL
                                  │
                                  ▼
                       optional cross-reference
                                  │
                   ┌──────────────┴──────────────┐
                   ▼                             ▼
             Codex work                    Claude work
             reviewed by                   reviewed by
               Claude                         Codex
```

## Planning

The initial Codex planning pass inspects the repository and produces structured tasks containing:

- A task ID such as `T01`
- A title
- An implementation description
- Acceptance criteria
- Dependencies on other tasks

Ralph Against the Machine favours cohesive implementation tasks rather than creating dozens of tiny tickets.

Tasks without dependencies can run in parallel. Tasks that depend on earlier work are held until their prerequisites have been integrated.

Before workers are spawned, the complete plan is displayed and Ralph Against the Machine asks:

```text
Spawn Codex/Claude workers for this plan? [Y/n]
```

Set `RALPH_AUTO_YES=1` to skip this prompt.

## Worker assignment

Ready tasks are alternated between Codex and Claude:

```text
T01  codex   Implement API endpoints
T02  claude  Add database persistence
T03  codex   Implement frontend integration
T04  claude  Add reporting UI
```

The default concurrency is two workers, so independent Codex and Claude tasks can execute simultaneously.

Each task runs in its own Git worktree and branch, starting from the current integration state.

## The Ralph loop

Workers do not retain one giant conversational context indefinitely.

Each task has two temporary files:

```text
.ralph-task.md
.ralph-progress.md
```

`.ralph-task.md` contains the assigned implementation task and acceptance criteria.

`.ralph-progress.md` records what the previous pass accomplished and what remains.

A worker is repeatedly invoked with fresh context until it writes:

```text
STATUS: DONE
SUMMARY: <implementation summary>
TESTS: <tests/checks performed>
REMAINING: none
```

If work remains it instead writes:

```text
STATUS: CONTINUE
SUMMARY: <what was completed>
TESTS: <tests/checks performed>
REMAINING: <specific next actions>
```

By default each task gets a maximum of four passes.

## Dependency waves

Ralph Against the Machine does not simply launch every task from the original `HEAD`.

For example, given:

```text
T01  API
T02  database changes
T03  frontend integration     depends on T01
```

Ralph Against the Machine can run `T01` and `T02` concurrently:

```text
                         base HEAD
                        /         \
                       /           \
               T01 / Codex     T02 / Claude
                       \           /
                        \         /
                      integration branch
                              │
                              ▼
                         T03 worker
```

`T03` therefore starts with the already-integrated prerequisite implementation rather than an obsolete copy of the repository.

## Integration

Completed worker changes are committed automatically and cherry-picked onto a dedicated integration branch:

```text
ralph/<run-id>
```

Tasks from the same dependency wave are integrated serially.

If supposedly independent tasks still collide during cherry-pick, Ralph Against the Machine asks Codex to resolve the conflict while preserving both implementations.

The original branch is not modified by the run.

## Independent validation

Once every task has been integrated, Codex receives the original request, generated task plan and complete repository diff.

It inspects the implementation and can run relevant tests, builds, linters and type checks.

Validation returns one of:

- `PASS` - the implementation satisfies the request with no material issue found.
- `WARN` - the implementation is broadly correct but has concerns worth reviewing.
- `FAIL` - acceptance criteria are unmet, important checks fail or a significant correctness/regression issue was found.

Validation output is stored as structured JSON in the run directory.

A failed validation does **not** destroy the implementation. The integration branch is retained for inspection or further work.

## Cross-reference mode

After validation Ralph Against the Machine asks:

```text
Cross-reference each task with the opposite provider? [y/N]
```

If enabled:

```text
Codex implementation  -> Claude review
Claude implementation -> Codex review
```

Each reviewer checks for:

- Correctness problems
- Regressions
- Missed acceptance criteria
- Architectural concerns
- Test gaps

The reviews are collected into:

```text
cross-reference.md
```

This is intentionally separate from the Codex whole-project validation. The validator looks at the final implementation globally, while cross-reference mode gives each task an independent second opinion from the other model.

## Configuration

Ralph Against the Machine is configured through environment variables.

### Parallel workers

```bash
RALPH_MAX_WORKERS=4 ./ratm.sh -f prompt.md
```

Default:

```text
RALPH_MAX_WORKERS=2
```

This controls the maximum number of tasks run concurrently in each dependency wave.

### Ralph passes

```bash
RALPH_MAX_PASSES=6 ./ratm.sh -f prompt.md
```

Default:

```text
RALPH_MAX_PASSES=4
```

This limits the number of fresh-context passes a worker can use before the task is considered failed.

### Agent failover on credit/usage limits

```bash
RALPH_AGENT_FAILOVER=0 ./ratm.sh -f prompt.md
```

Default:

```text
RALPH_AGENT_FAILOVER=1
```

When a worker pass fails and its output looks like a provider usage, rate or credit limit (e.g. "usage limit", "quota exceeded", "rate limit", HTTP 429), Ralph Against the Machine redirects the task to the *other* provider and continues the Ralph loop there instead of failing the task outright.

Each task can fail over at most once, so a task never bounces back and forth between providers. Set this to `0` to disable failover and fail the task immediately instead.

### Keep worktrees

```bash
RALPH_KEEP_WORKTREES=1 ./ratm.sh -f prompt.md
```

By default temporary worker worktrees are removed after successful integration.

Set this to `1` when debugging or when you want to inspect exactly what each agent saw.

### Allow a dirty starting repository

```bash
RALPH_ALLOW_DIRTY=1 ./ratm.sh -f prompt.md
```

By default Ralph Against the Machine refuses to start if the repository contains uncommitted changes.

When dirty mode is enabled, workers still start from the committed `HEAD`; your existing uncommitted changes are not automatically included in their worktrees.

### Skip the worker confirmation

```bash
RALPH_AUTO_YES=1 ./ratm.sh -f prompt.md
```

This skips the confirmation after task planning and immediately launches the workers.

### Run state location

```bash
RALPH_RUN_ROOT="$HOME/.local/state/ralph-against-the-machine" ./ratm.sh -f prompt.md
```

Default:

```text
RALPH_RUN_ROOT=<repo>/.ralph
```

Each invocation creates its own run directory beneath this location, so successive runs accumulate side by side rather than overwriting one another.

When the run root is the in-repo default (or otherwise resolves to somewhere inside the repository), Ralph Against the Machine automatically adds an ignore pattern for it to the repo's `.gitignore` the first time it runs, so run artefacts (logs, task state, worktrees) are never accidentally committed. This is a one-time, uncommitted change to `.gitignore` — commit it when convenient. Point `RALPH_RUN_ROOT` somewhere outside the repository (e.g. `$HOME/.local/state/...`) if you'd rather not touch `.gitignore` at all.

## Run artefacts

A run directory contains the generated planning, logging and review state, including files such as:

```text
tasks.json
validation.json
assignments.tsv
logs/
tasks/
reviews/
cross-reference.md        # when cross-reference mode is used
worktrees/                # while active, or when explicitly retained
```

The exact run directory is printed when execution completes.

## Example

```bash
RALPH_MAX_WORKERS=4 \
RALPH_MAX_PASSES=6 \
RALPH_RUN_ROOT="$HOME/.local/state/ralph-against-the-machine" \
./ratm.sh -f implementation-prompt.md
```

Ralph Against the Machine will first show the generated task plan. Once approved, it executes all currently runnable tasks up to the configured concurrency limit, integrates them, advances through dependent task waves and finally validates the complete result.

## Safety rails

Ralph Against the Machine deliberately keeps a few boundaries around the agents:

- Workers operate inside isolated Git worktrees.
- Workers are instructed not to commit, merge, rebase, push or modify remotes.
- The orchestrator owns all commits and integration.
- Claude workers receive an explicit tool allow-list rather than unrestricted permission bypassing.
- Codex runs through its sandboxed non-interactive execution mode.
- A dirty repository is rejected by default.
- The original branch is left untouched.
- Final validation is independent of the individual implementation passes.

It is still an autonomous coding system. Review the resulting branch before merging it into anything important. Ralph Against the Machine can provide two opinions; unfortunately neither agent can be held responsible at the stand-up.

## Project status

Experimental, useful and probably a poor substitute for hiring two more developers.

On the other hand, neither Codex nor Claude has yet complained about being assigned a Jira ticket at 4:57 PM.

## Name

**Ralph Against the Machine** is named for the Ralph-style iterative agent loop at the heart of the worker model, rebelling against the tedium of manual implementation by pitting two independent, autonomous providers against the same task.

Or, less formally: because apparently one autonomous coding agent was not enough.
