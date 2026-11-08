---
name: init-project-orchestration
description: Scan a repository and propose a project CLAUDE.md plus orchestration overrides for agents, skills and hooks. Use when the user types /init-project-orchestration to onboard a project.
disable-model-invocation: true
argument-hint: "[path to repository, default current directory]"
---

# Init project orchestration

Target: $ARGUMENTS (default: current directory)

## When to use

Use once when onboarding a repository, or again after its stack changes significantly.

## Procedure

1. Run `explorer` to detect the stack, package manager, and build, test and lint commands. Read any existing `CLAUDE.md`, `AGENTS.md` and `.claude/`.
2. Run the project's build, lint and test commands through `test-runner` only where they are safe, and note which ones already fail on a clean tree. A failing check is not a usable gate until its baseline is known.
3. Present a proposal and wait for approval:
   - `CLAUDE.md`: commands, conventions, and traps not already in the README. If one exists, propose additions only.
   - Agent overrides: only where project needs differ. Use the same name to replace a user agent.
   - Skills: use a project-specific name such as `<project>-testing`. A user skill wins over a project skill with the same name.
   - Optional formatter hook: only when the repository's formatter passes on a clean tree.
4. After approval, write `CLAUDE.md`, `.claude/agents/` and `.claude/skills/`. Files under `.claude/settings*.json` and `.claude/hooks/` are protected by a guard, so give the user their exact content to apply manually.

## Checklist

- No existing file was overwritten without approval.
- Every command in the proposal was found in the repository.
- Local-only and secret-bearing files were not read.

## Examples

- A NestJS service where the formatter fails on many untouched files: record that in `CLAUDE.md` and propose no formatter hook.
- A Swift app: record the `xcodebuild` scheme and test target, and suggest no JavaScript tooling.

## Anti-patterns

- Copying generic advice into `CLAUDE.md`.
- Creating an override that repeats the user agent without a project-specific difference.

---
Version 1.0.0. Last reviewed 2026-11-08.
