---
name: orchestrate
description: Run the multi-agent orchestration protocol in the current session. Use when the user types /orchestrate followed by a task that should be classified, routed to specialist subagents, verified and reported.
disable-model-invocation: true
argument-hint: "<task description>"
---

# Orchestrate

Task: $ARGUMENTS

## When to use

Use for work that benefits from routing, independent verification, or several specialists. For a whole session dedicated to orchestration, the user can run `claude --agent orchestrator` instead.

## Procedure

1. Read `<REPO_ROOT>/.claude/agents/orchestrator.md` and follow everything from `# ROLE` onward.
2. Apply these differences, because this is a normal session rather than `--agent orchestrator`:
   - You keep your session tools. Use Edit or Bash yourself only for C1 and R1 work. Delegate everything else.
   - Your Agent tool is not restricted. Use the roster and project agents only, as the protocol states.
   - Ignore the protocol's statement that you have no Write, Edit or Bash.
3. If no task was given, ask for one.

## Checklist

- The task was classified for type, complexity and risk before any delegation.
- Approval was obtained for everything outside the fast path.
- Verification results come from real commands or independent agents.

## Examples

- `/orchestrate Add pagination to the users API endpoint and write tests`
- `/orchestrate Our p95 latency doubled after last deploy, find out why`

## Anti-patterns

- Using `context: fork` for this skill. A forked subagent cannot serve as the orchestrator.
- Copying the protocol into `CLAUDE.md`, which loads into every subagent.

---
Version 1.0.0. Last reviewed 2026-11-08.
