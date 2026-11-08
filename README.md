# Claude Code Orchestration

Portable user-level setup for Claude Code: an orchestrator, 17 specialist subagents, skills, safety hooks and settings. This repository is the source of truth, and `install.sh` copies it into `~/.claude`.

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
2. Run `python3 tests/lint.py` and `bash tests/test-hooks.sh`.
3. Run `bash install.sh --dry-run`, then `bash install.sh`.
4. Commit, and add an entry to the changelog in `ORCHESTRATION.md`.

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
