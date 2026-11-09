# Claude Code Orchestration

Portable user-level setup for Claude Code: an orchestrator, 19 specialist subagents, skills, safety hooks and settings. This repository is the source of truth, and `install.sh` copies it into `~/.claude`.

See [ORCHESTRATION.md](ORCHESTRATION.md) for routing, the roster and the skills registry.

## Install on a new machine

Requirements: Claude Code, Node.js 18 or later, `git`, `jq`, `rsync` and `bash`.

```bash
npx --yes github:kitkas1412/claude-orchestration --dry-run
npx --yes github:kitkas1412/claude-orchestration
```

The first command shows what would change. The second backs up `~/.claude` and installs. Run it again to update.

Then sign in to Claude Code and check `/status` and `/agents`.

Add `--no-apple-design` to skip the optional `apple-design` clone.

## Change the setup

The safety hooks block direct edits to `~/.claude`, so changes flow one way. Linting also needs `ruby` and `python3`.

1. Clone this repository and edit its files.
2. Run `python3 tests/lint.py`, `bash tests/test-hooks.sh` and `bash tests/test-git-publish.sh`.
3. Run `bash install.sh --dry-run`, then `bash install.sh`.
4. Commit, and add an entry to the changelog in `ORCHESTRATION.md`.

## Optional browser verification

The `browser-verification` skill lets `ui-ux-engineer` look at a locally served page. It needs `playwright-cli`, which you install yourself and `install.sh` does not: `brew install playwright-cli`, then `brew pin playwright-cli`. Without it the agent reports that the UI was not rendered.

## Optional git automation

Off by default. The level is per repository and is stored in `~/.claude/git-publish.registry`: `commit`, `push`, `pr` or `merge`, each including the previous. Project files can never grant a level. Only you register a level, with `enable` in your own terminal (the script asks for a TTY and for the repo name; the guards are best-effort and only block common ways for an agent to run it):

```bash
~/.claude/hooks/git-publish.sh enable <commit|push|pr|merge> [--style conventional|project] [--allow-ci-changes]
~/.claude/hooks/git-publish.sh disable
```

- At `commit` or higher, `release-manager` may commit on a feature branch when the brief allows it.
- `commit` works without an `origin` remote. `push` works with any registered `origin` that has no embedded credentials. `pr` and `merge` need a GitHub `origin`.
- Only `release-manager` pushes, opens PRs and merges, and only through this route in a repository you registered at that level. `status`, `plan`, `push --expect-sha <sha>`, `pr --expect-sha <sha> --expect-content <sha256> --title-file F --body-file F` and `ci --pr <n>`, `merge --mark-ready-only --pr <n> --expect-sha <sha>` and `merge --pr <n> --expect-sha <sha>` need no TTY. A repository at a lower level or unregistered refuses them. `enable` and `disable` need a TTY and are yours alone. Direct `git push`, `gh pr create` and `gh pr merge` stay forbidden and blocked.
- With the title and body files, `plan` prints the PR title, a body preview and a content SHA-256. If the title or body changed after `plan`, `pr` refuses. `plan` is offline, but `push` and `pr` may ask for a fetch first.
- `pr` opens a draft. `merge` needs: the PR open, its head is the current non-protected branch at that SHA, its base is the registered default branch, not cross-repo, title and body pass the checks, and CI has at least one SUCCESS check, none failing, none pending (only SKIPPED or NEUTRAL checks, or no CI, are refused; use level `pr` there). `merge` also checks PR body headings under style `conventional`. It squash merges with the validated PR title as subject. It never uses `--admin` or `--auto` and does not delete the branch.
- Merge is separate steps. `ci --pr <n>` is read-only (level `merge`) and prints `verdict: passed|failed|pending|none|skipped-only`, `skipped: <names or ->`, `draft: true|false`, `url: <PR url>` and `head: <40-hex SHA>` (take the SHA of an existing PR from this line). If the PR is a draft, `merge --mark-ready-only --pr <n> --expect-sha <sha>` marks it ready and exits 0 without merging; it refuses (exit 2) if the PR is not a draft or a check is failing, and the approved plan is enough for it. In the run that marked the PR ready, read `ci --pr <n> --after-ready`, which prints any skipped check, or no checks, as `pending` because draft-gated jobs may not have restarted; later re-checks omit the flag (`merge` has no such flag). The merging run, `merge --pr <n> --expect-sha <sha>`, refuses a draft (exit 2) and never marks it ready. It runs only after you confirm the PR link and a `passed` verdict. Your GitHub workflows should include the `ready_for_review` trigger so CI runs once the draft is marked ready.
- CI files (`.github/workflows/**`, `.github/actions/**`, `CODEOWNERS`, `.github/CODEOWNERS`, `docs/CODEOWNERS`, including deletions): `merge` always refuses commits touching them. `push`, `pr` and `plan` refuse them unless you ran `enable ... --allow-ci-changes`; only `enable` can set it, re-running `enable` without the flag resets it to refused, and `status` prints `ci changes: allowed|refused`. A merge commit that brings a CI-file change from the default branch is refused by `merge`; with `--allow-ci-changes`, `push`, `pr` and `plan` allow it. Rebasing an already-pushed branch needs a force push, which this route refuses: use a new branch or handle it yourself.
- Shallow repositories are refused.
- `push`, `pr` and `merge` refuse with "fetch it first" if the remote default branch has commits not fetched locally. After a merge, `git fetch` before the next publish.
- Approval: Claude pushes and opens a PR after verification only if the plan you approved in the conversation explicitly includes those steps, and reports the SHA afterwards. For merge, the orchestrator asks you once, when the `ci` verdict is `passed`, showing the PR link, the verdict and any skipped check names, before `release-manager` runs the merging step. If CI is pending it tells you and ends the turn; on `skipped-only`, `none` or `failed` it reports that merge will be refused. There is no technical enforcement of conversation approval; it is a rule the agents follow.
- Limits: "only `release-manager`" is a rule the agents follow; the guard does not enforce it. CI results come from workflows and scripts in the repository, so a commit that edits a script CI runs can still fake green. Only required status checks plus human review close that. Green CI is not proof of safety.
- Rollout: Claude's push needs non-interactive credentials (ssh-agent, or an HTTPS credential helper). SSH is forced to batch mode, so a key that needs an interactive passphrase fails instead of prompting. This overrides any global `core.sshCommand`, so a custom key or agent setup there can fail.
- Force push, tags, publish and deploy have no exception: you run them yourself.
- Recommended: GitHub branch protection with required status checks. Required reviews will make Claude's merge fail, which is correct.
- Upgrading an existing install: `install.sh` only adds settings. Remove these two old deny rules by hand from `~/.claude/settings.json`, or Claude's `push` and `pr` stay blocked: `Bash(*git-publish.sh push*)` and `Bash(*git-publish.sh pr *)`.
- PRs are always drafts, GitHub only, on remote `origin`. Force, tags, refspecs and protected branches (main, master, develop, trunk, production, `release/*`) are refused. With style `conventional`, branches must be `<type>/<kebab-summary>` and commit subjects and PR titles must follow Conventional Commits (merge commits are exempt; `Revert "..."` is accepted for commit subjects). PR bodies need `## What`, `## Why`, `## How tested` and `## Risks`. Style `project` skips these format checks.
- Every commit since the merge-base is scanned on its own, so a secret added and later removed is still refused. Forbidden files include `.env*` (except `.env.example`, `.sample`, `.template`, `.dist`), keys, `*.tfvars` and `*.tfstate`.
- Repo hooks (pre-push, husky, gitleaks) do not run on this route, because a repo hook would run with your credentials. `plan` warns when a pre-push hook exists. Git LFS repositories are refused. Repo-local `core.sshCommand`-style overrides, `credential.*`, `url.*`, `protocol.*` and most `http.*` settings are refused (allowed: `http.postBuffer`, `lowSpeedLimit`, `lowSpeedTime`, `version`, `maxRequests`).
- The guards are a best-effort regex layer. They stop accidents and common command forms from careless or injected agents, and known forms can still get through. They are not a boundary against code run deliberately under your OS user. A deliberately evasive agent can still bypass the guards and grant itself a level, because regex cannot close this. Repositories at level `merge` therefore need branch protection with required status checks. To search for guarded text, use the Grep tool or a plain leading `grep`.
- Blocked for all projects: direct `gh pr create|new|ready|edit|merge`, `gh api` writes, `gh repo create|sync`, `gh release upload|edit`, `gh workflow run`, `gh secret set`, `gh extension install`, `gh auth token`, `git credential fill`, and agent writes to `~/.gitconfig` and `~/.claude/hooks`. `gh pr comment|close` and `gh issue` stay allowed.
- Check it with `bash tests/test-git-publish.sh`.

## Layout

| Path | Installed to | Purpose |
| --- | --- | --- |
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Global rules |
| `ORCHESTRATION.md` | `~/.claude/ORCHESTRATION.md` | Operating manual |
| `agents/` | `~/.claude/agents/` | Orchestrator and subagents |
| `hooks/` | `~/.claude/hooks/` | Safety hooks |
| `skills/` | `~/.claude/skills/` | Custom skills |
| `third_party/skills/` | `~/.claude/skills/` | Reviewed copies of external skills |
| `third_party/licenses/` | Not installed | Licenses for those skills |
| `settings.managed.json` | Merged into `~/.claude/settings.json` | Permissions, hooks and model |
| `tests/` | Not installed | Lint, hook and install checks |
| `bin/cli.js`, `package.json` | Not installed | `npx` entry point |

## How settings merge

Values in `settings.managed.json` win. Other settings on the machine stay. `permissions.deny` and `hooks` only gain entries, and the installer removes nothing.

## Third-party skills

| Skill | Source | Commit | License |
| --- | --- | --- | --- |
| `multi-stage-dockerfile` | `github/awesome-copilot` | `caab1f6` | MIT |
| `java-junit` | `github/awesome-copilot` | `52a5840` | MIT |
| `swift-testing-pro` | `twostraws/swift-testing-agent-skill` | `2d6bba1` | MIT |
| `gsap-core`, `gsap-timeline`, `gsap-scrolltrigger`, `gsap-plugins`, `gsap-performance`, `gsap-react` | `greensock/gsap-skills` | `aed9cfd` | MIT |
| `threejs-fundamentals`, `threejs-performance`, `threejs-loaders`, `threejs-react-three-fiber`, `threejs-shaders`, `threejs-postprocessing`, `threejs-materials`, `threejs-textures`, `threejs-lighting`, `threejs-animation`, `threejs-interaction`, `threejs-geometry` | `CloudAI-X/threejs-skills` | `0e18186` | MIT |

These are exact copies of the reviewed text. Review an upstream change before replacing a file here. `apple-design` is cloned at a pinned commit and is not stored in this repository.

## Not included

- Claude Code sign-in and credentials
- MCP connections and plugins
- Skills synced from claude.ai, which arrive with your account
- `find-skills`, which is only needed to search for new skills
- Session history and project memory

## Privacy

Keep project-specific notes in each project's `CLAUDE.md`, or in a `*.local.md` file here, which git ignores.

Never commit secrets. `.gitignore` covers common secret files, but check `git status` before committing.

## Roll back

`install.sh` prints a restore command with its backup path. A restore does not remove files that the install added.
