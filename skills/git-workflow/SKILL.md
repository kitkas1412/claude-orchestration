---
name: git-workflow
description: Apply branch, commit, versioning and pull request conventions when preparing changes or releases. Use for commit messages, PR descriptions, semantic version decisions and release command lists. Keywords - conventional commits, semver, branch naming, PR, tag, release.
---

# Git workflow

## When to use

Use when preparing commits, pull requests or releases. The project's own conventions take priority. Infer them from `CLAUDE.md`, contributing docs and recent `git log`.

## Procedure

1. Check the current branch and working tree with read-only commands. Report unrelated changes.
2. Work on a feature branch from the agreed base.
3. Write commit messages in the project's format. If none exists, use Conventional Commits.
4. Determine the version from commits since the last tag:
   - Major: breaking change.
   - Minor: new backward-compatible feature.
   - Patch: backward-compatible fix.
5. Produce an ordered command list for the user. Do not run commit, tag, push, publish or deploy commands unless the brief explicitly allows that specific step and hooks permit it.

## Checklist

- Each commit has one purpose.
- Messages explain why when the reason is not obvious.
- The PR description covers what changed, why, how it was tested, and risks.
- Breaking changes and migrations are called out.
- No secrets, generated files or unrelated changes are included.

## Examples

`fix(users): reject cursor from another tenant`

`feat(api)!: replace offset pagination with cursors`

## Anti-patterns

- `git push` as part of an automated step.
- Rewriting shared history.
- Skipping hooks to make a commit succeed.
- Mixing refactoring and behavior changes in one commit.

---
Version 1.0.0. Last reviewed 2026-11-08.
