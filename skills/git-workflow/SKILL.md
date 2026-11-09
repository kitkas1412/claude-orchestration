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
5. Run `git commit` only when `~/.claude/hooks/git-publish.sh status` shows level `commit` or higher and the brief allows it. Never read project files to decide the level. Never run tag, publish or deploy; list those commands for the user.
6. For push or PR: run `git-publish.sh plan [--title-file F --body-file F]`, then `push --expect-sha <sha>` and `pr --expect-sha <sha> --expect-content <sha256> --title-file F --body-file F` with the values `plan` printed, only if the level allows it and the approved plan includes the step. `plan` prints the PR title, a body preview and a content SHA-256; if either file changes afterwards, `pr` refuses.
7. For merge, only at level `merge`, as separate steps:
   - Read `git-publish.sh ci --pr <n>`. For an existing PR, take the SHA from the `head:` line and include it in the report.
   - Only if `draft: true`, run `git-publish.sh merge --mark-ready-only --pr <n> --expect-sha <sha>`. The approved plan is enough.
   - Read `ci --pr <n> --after-ready` and report. Use the flag only in the run that marked the PR ready (it maps any skipped check, and no checks, to pending); later re-checks omit it.
   - Run the merging run only when the user confirmed that PR and SHA, after a `passed` verdict: `git fetch origin <default branch>`, then `git-publish.sh merge --pr <n> --expect-sha <sha>`. Never run plain `merge` to change draft state.
8. To search for guarded text, use the Grep tool or a plain leading `grep`.

## Publish levels

- Per repository, set only by the user in `~/.claude/git-publish.registry` with `enable`: off (default), `commit`, `push`, `pr`, `merge`. Each includes the previous. A project file never grants a level.
- Agent-usable, no TTY: `status`, `plan`, `push --expect-sha <sha>`, `pr --expect-sha <sha> --expect-content <sha256> --title-file F --body-file F`, `ci --pr <n>`, `merge --mark-ready-only --pr <n> --expect-sha <sha>`, `merge --pr <n> --expect-sha <sha>`. A repository at a lower level or unregistered refuses them. `enable` and `disable` need a TTY and are for the user only; agents must not run them.
- PRs are always drafts, GitHub only, remote `origin`. The script refuses force, tags, refspecs and the branches main, master, develop, trunk, production and `release/*`. `commit` works without `origin`; `push` works with any registered `origin` that has no embedded credentials; `pr` and `merge` need a GitHub `origin`.
- `merge` needs: PR open, head is the current non-protected branch at that SHA, base is the registered default branch, not cross-repo, title and body pass checks, and CI with at least one SUCCESS check, none failing, none pending (only SKIPPED or NEUTRAL, or no CI, is refused; use level `pr` there). A draft is refused (exit 2) and never marked ready by it. Otherwise it squash merges with the PR title as subject. It never uses `--admin` or `--auto` and does not delete the branch.
- `ci --pr <n>` is read-only, level `merge`. It prints `verdict: passed|failed|pending|none|skipped-only`, `skipped: <names or ->`, `draft: true|false`, `url: <PR url>`, `head: <40-hex SHA>`. With `--after-ready`, skipped and no checks print `pending`. `merge --mark-ready-only` refuses (exit 2) if the PR is not a draft or a check is failing; otherwise it marks ready, exits 0 and never merges.
- Shallow repositories are refused. SSH runs in batch mode and overrides any global `core.sshCommand`, so a custom key or agent setup there can fail.
- CI files (`.github/workflows/**`, `.github/actions/**`, `CODEOWNERS`, `.github/CODEOWNERS`, `docs/CODEOWNERS`): `merge` always refuses them; `push`, `pr` and `plan` refuse them unless the user ran `enable ... --allow-ci-changes`; re-running `enable` without it resets it to refused. A merge commit that brings a CI-file change from the default branch is refused by `merge`; with `--allow-ci-changes`, `push`, `pr` and `plan` allow it. Rebasing a pushed branch needs a force push, which is refused: use a new branch or have the user handle it.
- `push`, `pr` and `merge` refuse with "fetch it first" if the remote default branch has unfetched commits.
- Approval and "only `release-manager`" are rules, not enforced by the guard. CI results come from repo-authored workflows and scripts, so a commit editing a script CI runs can still fake green; only required status checks plus human review close that.
- Repo hooks (pre-push, husky, gitleaks) do not run on this route, by design, and Git LFS repositories are refused. Each commit is scanned on its own, so a secret added then removed is refused.
- Style `project` skips commit subject, branch and PR heading checks. Under `conventional`, merge commits skip the subject check and `Revert "..."` is accepted for commit subjects.
- `git commit` is not hook-gated. The `commit` level is a rule you obey by reading `status`.

## Standards

- Commits: Conventional Commits 1.0.0, `type(scope)!: description`. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert. Use it unless the project registered style `project`. One purpose per commit.
- Branch: `<type>/<kebab-summary>`, for example `fix/cursor-tenant-check`.
- Write messages and PR text to files when needed, because `guard-bash` scans command text.
- PR body:

```
## What
## Why
## How tested
## Risks
```

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

- Direct `git push`, `gh pr create` or `gh pr merge` by an agent. Use the `git-publish.sh` route, and only `release-manager`.
- Running the merging `merge` without the user's confirmation of the PR link and a `passed` verdict, or running `enable`/`disable`.
- Committing without checking `git-publish.sh status`.
- Rewriting shared history.
- Skipping hooks to make a commit succeed. This still applies to agents' commits; the publish route skips repo hooks by design.
- Mixing refactoring and behavior changes in one commit.

---
Version 1.0.0. Last reviewed 2026-11-09.
