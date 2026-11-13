# Claude Code Orchestration

User-level multi-agent setup. Claude Code 2.1.319. Permission mode: `auto`.

## How to start

| Need | Command |
| --- | --- |
| A session dedicated to orchestration | `claude --agent orchestrator` |
| Orchestrate one task in a normal session | `/orchestrate <task>` |
| Learn a subject in a live dialogue | `claude --agent teacher` |
| Onboard a repository | `/init-project-orchestration [path]` |

The protocol lives only in `agents/orchestrator.md`. Do not copy it into `CLAUDE.md`, which loads into every subagent.

## How routing works

1. Detect the project's `CLAUDE.md`, agents, skills and stack.
2. Classify type, complexity (C1-C3) and risk (R1-R3).
3. Route using the table in `agents/orchestrator.md`.
4. Research with read-only agents.
5. Present a plan and wait for approval. C1 and R1 work uses the fast path and skips this, as do read-only reports.
6. Execute. Run in parallel only when file ownership does not overlap.
7. Verify with `test-runner`, `code-reviewer`, and `security-auditor` for R3.
8. Report in Vietnamese.

Escalation is haiku, then sonnet, then opus, up to 3 attempts per work unit. A hook or classifier block stops that line of work.

## Roster

| Agent | Model | Access |
| --- | --- | --- |
| orchestrator | opus | Agent, read-only tools; main thread only |
| explorer | haiku | read-only |
| researcher | sonnet | read-only + web |
| skill-scout | sonnet | read-only + web; recommends skills, never installs |
| teacher | sonnet | read + web; Write only under ~/learning/ |
| architect | opus | read-only |
| implementer | sonnet | edit + Bash |
| quick-fixer | haiku | edit, no Bash |
| api-designer | sonnet | edit, no Bash |
| ui-ux-engineer | sonnet | edit + Bash |
| test-writer | sonnet | edit + Bash, test files only |
| test-runner | haiku | read + Bash, no edit tools |
| debugger | opus | edit + Bash |
| performance-optimizer | sonnet | edit + Bash |
| code-reviewer | sonnet | read + read-only Bash hook |
| security-auditor | opus | read + read-only Bash hook |
| data-engineer | sonnet | edit + Bash, non-production only |
| devops-engineer | sonnet | edit + Bash, no deploy |
| doc-writer | haiku | edit, no Bash |
| release-manager | sonnet | edit + Bash, no tag, publish or deploy; may commit, push, open a PR and merge only through `git-publish.sh` at the registered level |

## Skills registry

Agents with an explicit `tools` list have no Skill tool, so `skills:` preloads the whole `SKILL.md` on each spawn. Keep preloaded skills near 120 lines or less, with detail in `references/`.

| Skill | Source | Used by | Last reviewed |
| --- | --- | --- | --- |
| testing-strategy | custom 1.0.0 | test-writer | 2026-11-08 |
| performance-profiling | custom 1.0.0 | performance-optimizer, debugger | 2026-11-08 |
| security-review-owasp | custom 1.0.0 | security-auditor | 2026-11-08 |
| db-migrations-safe | custom 1.0.0 | data-engineer | 2026-11-08 |
| api-design | custom 1.0.0 | api-designer | 2026-11-08 |
| docs-writing | custom 1.0.0 | doc-writer | 2026-11-08 |
| git-workflow | custom 1.0.0 | release-manager | 2026-11-09 |
| ui-implementation | custom 1.0.0 | ui-ux-engineer | 2026-11-09 |
| teaching-method | custom 1.0.0 | teacher | 2026-11-09 |
| ci-cd-pipelines | custom 1.0.0 | devops-engineer | 2026-11-08 |
| multi-stage-dockerfile | github/awesome-copilot@caab1f6 | devops-engineer | 2026-11-08 |
| java-junit | github/awesome-copilot@52a5840 | test-writer, through `testing-strategy` | 2026-11-08 |
| swift-testing-pro | twostraws/swift-testing-agent-skill@2d6bba1 | test-writer, through `testing-strategy` | 2026-11-08 |
| orchestrate | custom 1.0.0 | main session | 2026-11-08 |
| init-project-orchestration | custom 1.0.0 | main session | 2026-11-09 |
| apple-design | github.com/dickwu/apple-design-skill@904b0ee | ui-ux-engineer, by brief only | 2026-11-08 |
| find-skills | vercel-labs/skills@d3701c1 (MIT, vendored; does not auto-update) | skill-scout | 2026-11-09 |
| gsap-web | custom 1.0.0 | ui-ux-engineer, read on demand by path | 2026-11-09 |
| threejs-web | custom 1.0.0 | ui-ux-engineer, read on demand by path | 2026-11-09 |
| css-motion | custom 1.0.0 | ui-ux-engineer, read on demand by path | 2026-11-09 |
| gsap-threejs | custom 1.0.0 | ui-ux-engineer, read on demand by path, with the two above | 2026-11-09 |
| browser-verification | custom 1.0.0; needs the optional `playwright-cli` (`brew install playwright-cli`, then `brew pin playwright-cli`), installed by the user, not by `install.sh` | ui-ux-engineer, read on demand by path when `playwright-cli` exists | 2026-11-09 |
| gsap-core, gsap-timeline, gsap-scrolltrigger, gsap-plugins, gsap-performance, gsap-react | greensock/gsap-skills@aed9cfd (MIT, vendored; does not auto-update) | ui-ux-engineer, through `gsap-web` | 2026-11-09 |
| threejs-fundamentals, threejs-performance, threejs-loaders, threejs-react-three-fiber, threejs-shaders, threejs-postprocessing, threejs-materials, threejs-textures, threejs-lighting, threejs-animation, threejs-interaction, threejs-geometry | CloudAI-X/threejs-skills@0e18186 (MIT, vendored; does not auto-update) | ui-ux-engineer, through `threejs-web` | 2026-11-09 |

Skill vetting, 2026-11-08:

| Candidate | Result | Reason |
| --- | --- | --- |
| github/awesome-copilot@multi-stage-dockerfile | Passed, selected | One 46-line file, no scripts or network use, MIT |
| wshobson/agents@github-actions-templates | Rejected | 322 lines; static cloud keys and tag-pinned actions conflict with devops rules |
| josiahsiegel/claude-plugin-marketplace@docker-best-practices | Rejected | 659 lines, too large to preload |
| callstackincubator/agent-skills@github-actions | Rejected | Specific to mobile build artifacts |
| github/awesome-copilot@java-junit | Passed, selected | No scripts or network use; full text reviewed |
| twostraws/swift-testing-agent-skill@swift-testing-pro | Passed, selected | No scripts or network use; full text reviewed |
| anthropics/knowledge-work-plugins@testing-strategy | Not selected | Test plans only; name clashes with the custom skill |
| affaan-m/ecc@springboot-tdd | Rejected | Uses deprecated `@MockBean`; enforces coverage and JaCoCo |
| shipshitdev/skills@nestjs-testing-expert | Rejected | 39 stars, no license |
| github/awesome-copilot@pytest-coverage | Rejected | Pushes for 100% line coverage |
| manutej/luxor-claude-marketplace@jest-react-testing | Rejected | 1303 lines, 63 stars |
| obra/superpowers and addyosmani/agent-skills TDD | Not selected | Long, and require changing production code |
| antfu/skills@vitest and callstack/react-native-testing-library@react-native-testing | Deferred | Install when a project adopts these tools |
| ui-implementation (custom) | Selected | Stack-neutral, reuses an existing design system; credits addyosmani/web-quality-skills (MIT) for the WCAG 2.2 checklist structure |
| teaching-method (custom) | Selected | Domain-independent teaching loop with spaced review notes; original text, design draws on ideas from sanyuan0704/sanyuan-skills `sigma`, sebastianelvis/hammer `teach`, mattpocock/skills `teach` and GarethManning/education-agent-skills |
| anthropics/skills@frontend-design | Not selected | 1.1M installs; aesthetics first, the opposite of reusing an existing system; license unverified. Read optionally and read-only as a design-direction source when building from scratch |
| vercel-labs web-design-guidelines | Rejected | 840K installs; review-only; fetches its instructions from a `main` branch at runtime |
| addyosmani/web-quality-skills@accessibility | Not selected | 68.4K installs; MIT; accessibility only, about 380 lines; used as an idea source for `references/a11y.md` |
| ui-ux-pro-max | Not selected | 441.8K installs; depends on scripts, aesthetics-driven, no license |
| vercel-labs/skills@find-skills (d3701c11b1101251af14c9d148f026e1a47ebe17) | Passed, selected | MIT, Copyright (c) 2026 Vercel, Inc.; one 5.4 KB file, no scripts; only instructs `npx skills` commands, which `skill-scout` replaces with web search and never runs |
| css-motion, gsap-web, threejs-web, gsap-threejs (custom) | Selected | Tool-specific motion guidance loaded on demand: plain CSS, GSAP, Three.js, or both (one render loop, reduced motion, teardown, resize, context loss, fallback); original text, credits greensock/gsap-skills and CloudAI-X/threejs-skills (MIT). css-motion states its browser-support table as checked 2026-11-09. Replaces the earlier single `web-motion-3d` skill |
| greensock/gsap-skills@aed9cfd3277740755f6bfc1155c7aa645403b760: gsap-core, gsap-timeline, gsap-scrolltrigger, gsap-plugins, gsap-performance, gsap-react | Passed, selected | MIT, Copyright (c) 2026 GreenSock; one `SKILL.md` each (79 to 433 lines), no scripts, no hidden Unicode, full text reviewed. Copies recommend GSAP by default and `npm install gsap` / `@gsap/react`; `gsap-web` makes `ui-implementation` and the brief win. Known upstream typo: `Max.max` in the `gsap-core` horizontal scroll example |
| CloudAI-X/threejs-skills@0e181866f095b5f06d005133876e926515390d95: threejs-fundamentals, threejs-performance, threejs-loaders, threejs-react-three-fiber, threejs-shaders, threejs-postprocessing, threejs-materials, threejs-textures, threejs-lighting, threejs-animation, threejs-interaction, threejs-geometry | Passed, selected | MIT, Copyright (c) 2026 CloudAI-X; one `SKILL.md` each (387 to 496 body lines, read on demand, not preloaded), no scripts, no hidden Unicode, full text reviewed; targets three r186 and API-checked against r187. CDN import maps (jsdelivr) in examples; drei's `useGLTF` loads the Draco decoder from a gstatic URL. `threejs-asset-pipeline` is referenced but not installed |
| CloudAI-X/threejs-skills@threejs-asset-pipeline | Not selected | Out of scope; the installed skills tell the agent to use installed three types or official docs instead |

## Per-project overrides

| Item | Rule |
| --- | --- |
| Agents | Same name in `.claude/agents/` overrides the user agent |
| Skills | The user skill wins on a name clash, so project skills need distinct names |
| `CLAUDE.md` | Project file sets stack commands and conventions, and cannot relax Safety |
| Permissions | Lists merge across scopes; a project cannot remove a user deny |
| `defaultMode: auto` | Only effective in user settings |
| Formatter hooks | Project opt-in only, after the formatter passes on a clean tree |

## Safety layers

- `hooks/guard-bash.sh`: blocks destructive, publishing and secret-reading shell commands.
- `hooks/guard-write.sh`: protects secrets and this configuration. Changes here are applied manually by the user.
- `hooks/readonly-bash.sh`: allowlist for `code-reviewer` and `security-auditor`.
- `hooks/stop-verify-reminder.sh`: non-blocking test reminder for the orchestrator.
- `hooks/filter-test-output.sh`: not a guard. It never blocks and fails open. It rewrites allowlisted test, build and lint commands so long output is trimmed and the full log is kept in `${TMPDIR:-/tmp}`. Disable with `CLAUDE_FILTER_OUTPUT=0`; see `README.md`.
- `permissions.deny`: blocks reads of env files, keys and credential directories.
- `hooks/git-publish.sh`: per-repository git level (off, `commit`, `push`, `pr`, `merge`) registered by the user with `enable` and kept in the user-level `~/.claude/git-publish.registry` (optionally with a GitHub account, `enable --account <login>`, shown by `status` as `account:`; see `README.md`). Only `release-manager` runs `status`, `plan`, `push`, `pr` and `merge` (no TTY), and only at a registered level and when the plan the user approved includes the step; merge also needs one user confirmation once the `ci` verdict is `passed` (marking a draft ready with `merge --mark-ready-only` needs only the approved plan), and CI with at least one SUCCESS check, none failing, none pending. "Only `release-manager`" is a rule, not enforced by the guard. CI results come from repo-authored workflows and scripts, so a commit editing a script CI runs can still fake green; only required status checks plus human review close that. `enable` and `disable` need a TTY and are for the user only. Direct `git push`, `gh pr create` and `gh pr merge` stay blocked. Conversation approval is not technically enforced, and this is not a security boundary: a deliberately evasive agent can still bypass the guards and grant itself a level, because regex cannot close this. Repositories at level `merge` therefore need branch protection with required status checks. Repo hooks (pre-push, husky, gitleaks) do not run on this route. `git commit` is not hook-gated, so the `commit` level is a rule agents follow by reading `status`.

The hooks fail closed when `jq` is missing or the input JSON is malformed. `guard-bash.sh` also blocks Bash writes to a project's `.claude/hooks/**`, `.claude/settings*.json`, `.claude/rules/**` and `.claude/agents/**` (top-level `agents/` and `skills/` are not affected), including `curl -o`, `wget -O/-P`, `tar -x -C`, `unzip -d`, `git checkout/restore` and `patch` aimed at them; reads stay allowed. `git-publish.sh` treats `.claude/**` (any depth), `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` (any depth) like `.github/**` and CODEOWNERS: `merge` always refuses a change to them, and `push`, `pr` and `plan` need the `ci` opt-in (`enable ... --allow-ci-changes`, or `ci` in a cloud grant). Known gaps (accepted): `git apply`, `git checkout-index`, `patch -p0 < file`, interpreter writes. Files imported by `CLAUDE.md` via `@path` are not treated as policy files. A PR touching a policy file can never be merged through `git-publish.sh`, including routine re-export PRs; merge it by hand. The `init-project-orchestration` skill drafts project agents into `<repo>/.claude-draft/` for the user to move. Known false positives: writes to `.claude/settings.local.json`, a writer word in the same command segment as a protected path, and `cp x .claude/`.

To change this setup, edit the `claude-orchestration` repository and run `install.sh` yourself.

## Claude Code cloud

Cloud sessions load only the committed `.claude/` of the repository, not `~/.claude`. See `README.md` for the steps.

| Path | Purpose |
| --- | --- |
| `.claude/` | Generated export by `install.sh --project <repo> [--set-agent]`; do not edit by hand. This repository has none committed: generate it with `bash install.sh --project .` and commit it yourself (manual merge, because `.claude/**` is a policy path). Check with `bash tests/check-project-export.sh` |
| `project/` | Inputs for the export: `rules-preamble.md` and `settings.project.json` |
| `cloud/setup.sh` | Experimental environment setup script: installs a pinned commit of this setup into `/root/.claude` and rebuilds the git-publish registry from its `GRANTS` text |

- The export holds agents, skills, the hooks `guard-bash`, `guard-write`, `readonly-bash`, `stop-verify-reminder` and `filter-test-output` (run through `"$CLAUDE_PROJECT_DIR"`), `rules/orchestration.md` and `settings.json`. It never holds `git-publish.sh` or `apple-design`. Only the user runs it; the guards block agents from writing the hooks and settings.
- Publishing in cloud needs `cloud/setup.sh` (experimental, use with the export). With `CLAUDE_CODE_REMOTE=true`, `git-publish.sh` uses a REST backend (`gh api`) because the cloud GitHub proxy blocks GraphQL, and only `github:<owner>/<repo>` registry rows count; local path rows count only locally, so setting the variable cannot raise a level. `status` ends with `backend: local|cloud-rest`. `enable` and `disable` stay TTY-only and never write `github:` rows. Pull requests open ready at level `merge` and as drafts at `pr`; `merge --mark-ready-only` refuses in cloud (use Ready for review on GitHub, then `ci --pr <n> --after-ready`). The merge sends the expected head SHA.
- In cloud the checks use the GitHub API, not the loopback remote: the base SHA from `git/ref/heads/<branch>` and, for `merge`, the PR changed files from `pulls/<n>/files` (refused on failure or at 3000 or more files). `pr` checks that the branch head on GitHub equals the pushed SHA, and the PR URL must be `https://github.com/<slug>/pull/<n>`. `push` goes to the verified URL, not the `origin` name, so `refs/remotes/origin/<branch>` is not updated. Slugs match case-insensitively and duplicate grants refuse. `cloud/setup.sh` empties the registry first on every run, so any failure leaves zero grants; if it cannot empty it, it removes it, and warns `REVOKE FAILED` only if that also fails. In cloud, `push` also needs an authenticated `gh` and `jq`; a repository whose default branch is not yet on GitHub (empty repository) is refused (fail closed). `push` also refuses if git URL rewriting (`insteadOf`, `pushInsteadOf`) would change the verified URL.
- Security model: publish levels and the guard hooks are a workflow guardrail, not a security boundary. A prompt-injected agent running as the same OS user (root in cloud) could bypass the regex guards (interpreter writes, `git apply`) and edit the registry or the hooks. The real boundary is GitHub: branch protection or rulesets with required status checks, and required reviews where possible. Grant `merge` in cloud only for protected or low-stakes repositories; prefer `pr`.
- Not verified: a REST merge through the cloud proxy; the repository config check under cloud-added git config entries; `HOME=/root`; whether `/root/.claude` hooks load in cloud. `~/learning` is ephemeral there.

## Changelog

### 1.8.0 - 2026-11-13

- Added an opt-in WORKTREE mode. When `<repo root>/.worktreeinclude` exists, the orchestrator (new tools `EnterWorktree` and `ExitWorktree`) calls `EnterWorktree` with the name `<type>-<kebab-summary>` before the first write-capable agent. Claude Code creates `.claude/worktrees/<name>/` on branch `worktree-<name>` from the default branch and copies the gitignored files that match `.worktreeinclude` (`.gitignore` syntax; root and nested paths such as `apps/web/.env.local`). Without the file, BRANCH mode is unchanged. A worktree already open for the same task is kept; if `EnterWorktree` fails or is denied, the orchestrator stops and asks instead of falling back.
- Added the `release-manager` WORKTREE-CHECK mode (haiku, not level-gated, no commit): it verifies a linked worktree under `/.claude/worktrees/` and a clean tree (a dirty resumed tree is a warning), renames the `worktree-*` branch to the conventional `<type>/<kebab-summary>` the brief gives (only if it has no upstream or tracks `origin/<base>`, with neither name among the fetched remote-tracking refs, then unsets that upstream; BLOCKED if the guard fails, the target exists or is invalid) so the publish route accepts it, warns if HEAD does not descend from `origin/<base>`, and lists the `.worktreeinclude` matches by file name only (present names, not proof of copy), never contents. After an `ExitWorktree` remove, the renamed branch remains and the user deletes it with `git branch -d`. `tests/lint.py` now restricts `EnterWorktree` and `ExitWorktree` to the orchestrator and requires `WORKTREE-CHECK` in `release-manager`. BRANCH mode now stops with BLOCKED inside a Claude-created worktree. Every later brief carries the absolute worktree path as WORKDIR, and the final report adds the path, a note to install dependencies there and the port-clash warning. `ExitWorktree` runs only when the user asks; it keeps the worktree unless the user asks to remove it and the work is pushed or merged.
- Unchanged: agents never create worktrees or pass `isolation: "worktree"` to the Agent tool, and `guard-bash.sh` still denies `git worktree add` and `move`. This supersedes the "never a worktree" rule of 1.5.0 for repositories that opt in.

### 1.7.0 - 2026-11-13

- Added an optional per-repository GitHub account to `git-publish.sh`: `enable <push|pr|merge> --account <login>` (user terminal only) stores the login as an optional 7th registry column, so repositories owned by different accounts need no `gh auth switch`. `push`, `pr`, `merge` and `ci` fetch that account's token once (`gh auth token --user`, gh 2.40 or newer), check it with `gh api user`, and pass it to `gh` through `GH_TOKEN` and to `git push`/`ls-remote` through a credential helper for `https://github.com`. The token is never exported to the session, put on a command line or printed; caller `GH_TOKEN`/`GITHUB_TOKEN` are ignored in account mode, and a failure names the account with no fallback to the active gh account. `status` prints `account: <login>|active|-`.
- `enable --account` refuses level `commit`, a push URL that is not `https://github.com/...`, an account that is not logged in, a token of another account, and an account without push access. Re-running `enable` without `--account` clears it. Rows without an account behave as before. The account does not apply to the cloud backend (a cloud `github:` row with an account is unregistered).
- Downgrade note: an older `git-publish.sh` treats a 7-column row as unregistered (fails closed), and an older `enable` rewrites the row without the account. Residual exposure: the guards are best-effort, not a security boundary. A same-user agent that can run commands in the background can read the token while `gh` or `git` run (`ps eww`), from `gh`'s own keychain item or config file, or by replacing `gh` or `git` in the user-writable `/opt/homebrew/bin` or `/usr/local/bin` of the forced `PATH`. `bash <script>` with `BASH_ENV` or exported `exec`/`builtin`/`command` functions runs that code before the script re-runs itself (a `guard-bash.sh` follow-up).
- Behaviour changes for all `git-publish.sh` users, with or without an account: the script re-runs itself through `env -i` under `bash -p` and keeps only an allowlist of variables (`USER`, `LOGNAME`, locale, `TERM`, `TMPDIR` (must be absolute), `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, proxies, `GH_TOKEN`/`GITHUB_TOKEN`, `CLAUDE_CODE_REMOTE`, `GIT_CEILING_DIRECTORIES`, cloud CA variables); every other variable is dropped. `XDG_RUNTIME_DIR` is kept only as exactly `/run/user/<uid>` (owned by the user, not group- or world-writable) and `DBUS_SESSION_BUS_ADDRESS` only as exactly `unix:path=<that directory>/bus` with an optional hex guid; anything else is dropped (always on macOS). `bash -s`, `bash < script` and `bash -c "$(cat script)"` are refused ("run the script by its path"). The global URL-rewrite check now runs in every preflight (`plan`, `push`, `pr`, `merge`) and in `enable`, before any network call. `SSL_CERT_FILE`, `SSL_CERT_DIR` and `CURL_CA_BUNDLE` are always dropped on the local backend, which breaks TLS-inspecting corporate proxies that rely on them. `core.askPass` is forced empty, so `SSH_ASKPASS` and configured askpass programs are ignored.
- Account mode only: git's credential helper list is reset for every URL, so only the account helper runs; the session bus variables reach only the `gh auth token` keyring call; proxy URLs with a user name are dropped; `gh` runs from `/`, so repository filters never run next to the token; repo-local `filter.*` and `submodule.*.update` settings are refused (for example git-crypt or nbstripout filters), while other `submodule.*` settings stay allowed. Rows without an account are unchanged here, and `filter.lfs` keeps its LFS refusal in all modes.

### 1.6.0 - 2026-11-13

- Added the `filter-test-output.sh` PreToolUse hook for Bash, registered in `settings.managed.json` and exported by `install.sh --project`. It rewrites only allowlisted test, build and lint commands without shell metacharacters (`npm`/`pnpm`/`yarn` test, build, lint; `npx jest|vitest`; `pytest`; `go test|build|vet`; `cargo test|build|clippy`; `make test|build|lint|check`; `bash tests/<name>.sh`; `python3 tests/<name>.py`) to `( set -o pipefail; <cmd> 2>&1 | '<hooks dir>/filter-test-output.sh' --filter )`. The command still runs in the Bash tool's own shell (aliases and functions such as `nvm` keep working) and `pipefail` keeps the exit code; the script never executes commands and exits 2 on any argument other than `--filter`. `npm run` is allowed only as `test`, `build` or `lint` with an optional `:suffix`. Output of 200 lines or fewer is unchanged; longer output keeps the first 20 lines, failure-marker lines (including `error TSnnnn`, ESLint error columns, `panicked at` and Mocha `N failing`) with 2 lines of context (capped at 150) and the last 60 lines, plus a footer with the path of the full log (`${TMPDIR:-/tmp}`, mode 600). Printed lines over 2000 characters are truncated, the stored log is capped at 50 MB, and this user's logs older than 1 day are deleted. On `TERM`, `INT` or `HUP` it prints the tail with `interrupted after N lines; full log: PATH` (after `SIGKILL` the log remains but no path is printed); if no log can be created, output passes through unchanged. It fails open and sets no `permissionDecision`. Opt out with `CLAUDE_FILTER_OUTPUT=0`. User allow rules such as `Bash(npm test:*)` may stop matching the rewritten command and then prompt. Do not add a wildcard allow rule for the wrapper (it would auto-approve any command piped into the filter); set `CLAUDE_FILTER_OUTPUT=0` instead. Auto mode denying such a call is unverified. `install.sh` never removes hook entries: delete the entry from `~/.claude/settings.json` by hand to disable it.
- Added `effort` frontmatter: `low` for `explorer`, `test-runner` and `quick-fixer`, `medium` for `doc-writer`. `tests/lint.py` validates `low`, `medium`, `high`, `xhigh` and `max`.
- `release-manager` no longer preloads the `git-workflow` skill and reads it on demand for commit, push, PR and merge work (BRANCH mode does not need it). The publish and merge steps now live in `agents/release-manager.md` and the skill points there. Orchestrator Phase 5b is shorter.
- Fixed `README.md`: removed the stale claim that `find-skills` is not included, and listed it in the third-party table.

### 1.5.0 - 2026-11-13

- Changed the workflow to one task = one branch, never a worktree. Before the first write-capable agent of any change (fast path included), the orchestrator delegates to `release-manager` (haiku) in the new BRANCH mode: it requires a clean working tree (otherwise BLOCKED and the user commits or stashes), fetches the default branch (registered `default branch:` from `git-publish.sh status`, else `origin/HEAD`, else `main`) and runs `git switch --no-track -c <type>/<kebab-summary> origin/<base>`. An existing branch name is BLOCKED; a retry keeps the task branch; tasks that change nothing need no branch.
- The orchestrator never passes `isolation: "worktree"` to the Agent tool, and briefs now forbid creating worktrees and switching branches (except BRANCH mode). Parallel writers share the task branch under the existing file-ownership rule. `guard-bash.sh` denies `git worktree add` and `move`. The `git-workflow` skill replaces "from the agreed base" with the default-branch rule.

### 1.4.0 - 2026-11-13

- Added Claude Code cloud support. `install.sh --project <repo> [--set-agent]` exports agents, skills, guard hooks, rules and settings into `<repo>/.claude/` for commit (never `git-publish.sh` or `apple-design`; merge only adds); `--no-backup` skips the `~/.claude` backup. Added experimental `cloud/setup.sh` for the environment setup script, which installs a pinned commit and registers `GRANTS` as `github:` rows.
- `git-publish.sh` uses a REST backend when `CLAUDE_CODE_REMOTE=true` and honors only `github:` rows there. `status` prints `backend:`.
- `guard-bash.sh` blocks Bash writes to a project's `.claude/hooks/**` and `.claude/settings*.json`, and also `.claude/rules/**` and `.claude/agents/**`, `curl -o`, `wget -O/-P`, `tar -x -C`, `unzip -d`, `git checkout/restore` and `patch` aimed at them. The guard hooks fail closed when `jq` is missing or the input is malformed. Known gaps: `git apply`, `patch -p0 < file`, interpreter writes.
- `git-publish.sh` treats `.claude/**`, `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` like CI files: `merge` always refuses, `push`, `pr` and `plan` need the `ci` opt-in. In cloud, the base SHA, the PR file list (3000-file limit) and the pushed branch head come from the GitHub API; `push` goes to the verified URL; slugs match case-insensitively and duplicate grants refuse. Publish levels and guards are a workflow guardrail, not a security boundary; the real boundary is GitHub branch protection with required status checks.
- `cloud/setup.sh` empties the registry first on every run (any failure leaves zero grants) and detects duplicate grants case-insensitively. `install.sh --project` needs a work-tree root, refuses symlinks and `disableAllHooks: true`, warns about risky existing settings (`permissions.allow`, `bypassPermissions`, unmanaged hooks), adds denies for `settings.local.json`, `rules`, `agents` and `skills`, does not rewrite `apple-design` lines, and never deletes files removed upstream (`tests/check-project-export.sh` reports them as drift).
- Policy-file PRs (`.claude/**`, `CLAUDE.md`, `CLAUDE.local.md`, `.mcp.json`, `.github/**`, CODEOWNERS) are merged by hand, never through `git-publish.sh`; `@path` imports of `CLAUDE.md` are not policy files. Cloud `push` needs authenticated `gh` and `jq` and refuses an empty repository, and refuses when git URL rewriting would change the verified URL. `cloud/setup.sh` removes a registry it cannot empty (`REVOKE FAILED` only if that fails). `init-project-orchestration` now drafts agents into `.claude-draft/` for the user to move. Accepted guard gaps: `git apply`, `git checkout-index`, `patch -p0 < file`, interpreter writes.
- Added `tests/test-project-install.sh`, `tests/check-project-export.sh` and `tests/test-cloud-setup.sh`; extended `tests/test-git-publish.sh` and `tests/test-hooks.sh`.

### 1.3.0 - 2026-11-09

- Added the custom `browser-verification` skill: when the optional `playwright-cli` is installed (by the user: `brew install playwright-cli`, then `brew pin playwright-cli`; `install.sh` does not install it), `ui-ux-engineer` reads it by path to check a locally served page through Bash: desktop and phone screenshots viewed with Read, console errors, reduced-motion emulation, WebGL renderer and a rough rAF sample. Local origins only, output outside the project tree, no persistent profile. Without the CLI the agent reports that the UI was not rendered. The motion skills now say visual quality and frame rate stay unverified unless it was run.

### 1.2.0 - 2026-11-09

- Added the `teacher` agent and the custom `teaching-method` skill: teaches any subject one concept per turn in Vietnamese, runs live with `claude --agent teacher` or as a relayed subagent, and writes notes only under `~/learning/<topic>/`.
- Added the custom `css-motion`, `gsap-web`, `threejs-web` and `gsap-threejs` skills for `ui-ux-engineer`, with vendored, vetted GSAP (greensock/gsap-skills@aed9cfd) and Three.js (CloudAI-X/threejs-skills@0e18186) skills, both MIT, read on demand from `~/.claude/skills/` rather than preloaded; the agent first chooses CSS, GSAP, Three.js or both. They require one render loop and reduced-motion handling and cover teardown, resize, context loss, WebGL fallback and idle pausing. The vendored copies do not auto-update.

### 1.1.0 - 2026-11-09

- Added the `skill-scout` agent (read-only + web), which preloads the vendored `find-skills` skill (vercel-labs/skills@d3701c1, MIT) to find and vet skills and recommend adopting or creating one; it never installs. The vendored copy does not auto-update; re-vendor and re-review to upgrade.
- Added optional per-project git automation: `/init-project-orchestration` asks for a level, `release-manager` may commit, push, open a draft PR and squash merge through `git-publish.sh`, at the level the user registered (`commit`, `push`, `pr`, `merge`) and when the approved plan includes the step. Merge needs one user confirmation and passing CI (at least one SUCCESS check, none failing or pending). Force push, tags, publish and deploy stay with the user.
- Upgrade note: `install.sh` only adds settings, so remove the old denies `Bash(*git-publish.sh push*)` and `Bash(*git-publish.sh pr *)` by hand from `~/.claude/settings.json`.
- `git-workflow`: added Conventional Commits, branch naming and PR body standards.
- `gh pr create` and `gh api` writes are blocked for all projects.
- Added the `ui-implementation` skill, preloaded by `ui-ux-engineer`: detects an existing, partial or missing design system, with references for accessibility, states and responsive rules, and design system bootstrap.

### 1.0.3 - 2026-11-08

- Added `npx` installation from GitHub and removed project-specific notes for a public repository.

### 1.0.2 - 2026-11-08

- Moved the setup into the `claude-orchestration` repository, with vendored vetted skills and `install.sh`.

### 1.0.1 - 2026-11-08

- Routing: added an architecture row; read-only reports need no approval; R3 always uses opus review and a security audit.
- Routing: docs fast path checks changed claims; performance baselines are measure-only; `api-designer` runs first when a contract needs design.
- `testing-strategy`: reading `java-junit` and `swift-testing-pro` is now a required first step.

### 1.0.0 - 2026-11-08

- Orchestrator moved to opus, gained a fast path and a corrected routing table, and dropped `TodoWrite`.
- Added `quick-fixer`, `api-designer`, `/orchestrate` and `/init-project-orchestration`.
- Rewrote agent descriptions, attached skills, and moved `debugger` to opus.
- Added custom skills.
- Set `auto` mode and extended read denies.
- Closed write paths in `readonly-bash.sh`; fixed false positives in `guard-bash.sh`.
