---
name: git-workflow
description: Apply branch, commit, versioning and pull request conventions when preparing changes or releases. Use for commit messages, PR descriptions, semantic version decisions and release command lists. Keywords - conventional commits, semver, branch naming, PR, tag, release.
---

# Git workflow

## When to use

Use when preparing commits, pull requests or releases. The project's own conventions take priority. Infer them from `CLAUDE.md`, contributing docs and recent `git log`.

## Procedure

1. Check the current branch and working tree with read-only commands. Report unrelated changes.
2. One task = one new feature branch from the repository's default branch (the `default branch:` line of `git-publish.sh status`, else `git symbolic-ref --short refs/remotes/origin/HEAD`, else `main`): `git fetch origin <base>`, check `git rev-parse --verify origin/<base>` (stop if it fails), then `git switch --no-track -c <type>/<kebab-summary> origin/<base>`. `--no-track` keeps git from setting `origin/<base>` as the upstream. Stop if the working tree is dirty; the user commits or stashes. Never use git worktrees (`git worktree add` and `move` are denied by the guard).
3. Write commit messages in the project's format. If none exists, use Conventional Commits.
4. Determine the version from commits since the last tag:
   - Major: breaking change.
   - Minor: new backward-compatible feature.
   - Patch: backward-compatible fix.
5. Commit, push, PR and merge run only through `git-publish.sh`, only by `release-manager`, and only as its agent definition says (levels from `status`, plan/push/pr/merge sequence, cloud sessions, never tag, publish or deploy). Do not restate those rules here.
6. To search for guarded text, use the Grep tool or a plain leading `grep`.

## Publish levels

- Levels are set only by the user in `~/.claude/git-publish.registry` with `enable`; a project file never grants one. Level gating, the command sequence, CI and policy file refusals, "fetch it first", shallow/SSH limits and cloud notes live in `release-manager`.
- `status` also prints `account: <login>|active|-`. The account is set only by the user with `enable --account`; agents never set or change it.
- PRs are drafts (in cloud, a repository at level `merge` gets a ready PR), GitHub only, remote `origin`. The script refuses force, tags, refspecs and the branches main, master, develop, trunk, production and `release/*`. `commit` works without `origin`; `push` works with any registered `origin` that has no embedded credentials; `pr` and `merge` need a GitHub `origin`.
- `merge` needs: PR open, head is the current non-protected branch at that SHA, base is the registered default branch, not cross-repo, title and body pass checks, and CI with at least one SUCCESS check, none failing, none pending (only SKIPPED or NEUTRAL, or no CI, is refused; use level `pr` there). A draft is refused (exit 2) and never marked ready by it. Otherwise it squash merges with the PR title as subject. It never uses `--admin` or `--auto` and does not delete the branch.
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
- Creating a git worktree, or branching from anything other than the default branch.
- Rewriting shared history.
- Skipping hooks to make a commit succeed. This still applies to agents' commits; the publish route skips repo hooks by design.
- Mixing refactoring and behavior changes in one commit.

---
Version 1.0.0. Last reviewed 2026-11-13.
