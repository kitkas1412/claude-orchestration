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

Add `--no-apple-design` to skip the optional `apple-design` clone, and `--no-backup` to skip the backup of `~/.claude`.

`--project <repo>` exports into a repository instead; see "Run in Claude Code cloud".

## Run in Claude Code cloud

Claude Code on the web (claude.ai/code) does not have your `~/.claude`. It loads only the `.claude/` files committed in the repository. There are two routes, and you can use both.

### Route A: export into the repository

Run it yourself in your terminal (the guards block agents from writing `.claude/hooks` and settings). Needs `jq`, `git` and `bash`.

```bash
bash install.sh --project <repo> --dry-run
bash install.sh --project <repo> [--set-agent]
```

`<repo>` must be the root of a git work tree. Then review and commit `.claude/` (and any `CLAUDE.md` change) yourself. This repository has no committed export; generate it with `bash install.sh --project .` and commit it yourself. Because `.claude/**` is a policy path (see "Optional git automation"), `git-publish.sh merge` refuses that commit, so merge it manually, and `pr` needs the `ci` opt-in.

- Exported into `<repo>/.claude/`: `agents/`, `skills/` (including the vendored third-party skills), the hooks `guard-bash.sh`, `guard-write.sh`, `readonly-bash.sh`, `stop-verify-reminder.sh`, `filter-test-output.sh`, `guard-mcp-serena.sh`, `guard-mcp-playwright.sh` and `guard-mcp-context7.sh`, `rules/orchestration.md` (the preamble, `project/rules-preamble.md`), `rules/orchestration-global.md` (the global rules from this repository's `CLAUDE.md`), `ORCHESTRATION.md`, `settings.json` and `.orchestration-manifest`.
- The global install adds `"claudeMdExcludes": ["**/.claude/rules/orchestration-global.md"]` to `~/.claude/settings.json`, so a local session loads the global rules once, from `~/.claude/CLAUDE.md`. The export strips that setting, because cloud sessions do not read `~/.claude` and still need `orchestration-global.md`.
- Limits: the glob excludes any file named `orchestration-global.md` in any project. It assumes `~/.claude/CLAUDE.md` holds the global rules; after a partial install without it, local sessions get no global rules. The settings merge takes `claudeMdExcludes` from `settings.managed.json`, so it replaces any existing user value for that key.
- The hooks in `settings.json` run from `"$CLAUDE_PROJECT_DIR"/.claude/hooks/`. The export leaves out the model and `defaultMode`.
- Never exported: `git-publish.sh` and `apple-design`. No backup is made.
- The target `CLAUDE.md`, `.claude/worktrees` and `.claude/settings.local.json` are left alone. Settings merge as for `~/.claude`: entries are only added. Running it again is safe and updates the files.
- `--set-agent` adds `"agent": "orchestrator"`, so the orchestrator is the main agent. The global install already sets this for local sessions, so the flag matters for cloud sessions (they do not read `~/.claude`) and for teammates without the global install. Without it the export strips `agent`.
- Locally, both `~/.claude` and the project guards run. The duplication is harmless. A project agent overrides a user agent of the same name.
- Do not edit the exported files by hand. Change the source here and export again.
- Refused: a symlink under `<repo>/.claude` (the target itself, `settings.json`, `ORCHESTRATION.md`, `.orchestration-manifest`, or anything inside `agents/`, `skills/`, `hooks/`, `rules/`), and a target `settings.json` with `disableAllHooks: true`. Existing `permissions.allow` entries, `permissions.defaultMode: bypassPermissions` and hooks not managed by the export are kept and listed as a WARNING.
- The `init-project-orchestration` skill drafts project agents (and rules) into `<repo>/.claude-draft/` because the guards block agents from writing `.claude/agents/**`; it prints the commands for you to move them after review.
- Extra `permissions.deny` entries (from `project/settings.project.json`) cover Edit and Write on `.claude/hooks/**`, `settings.json`, `settings.local.json`, `rules/**`, `agents/**` and `skills/**`.
- Lines about `apple-design` are not rewritten, and `apple-design` is not exported.
- The export never deletes files that were removed upstream. `bash tests/check-project-export.sh` compares the git-tracked `.claude` files with a fresh export and reports files missing on either side.

### Route B: user-level install in the cloud environment (experimental)

`cloud/setup.sh` installs this setup into `/root/.claude` in the cloud environment, including `git-publish.sh`, and registers the repositories you grant. Whether Claude Code in the cloud loads hooks from `/root/.claude` is unverified, so use it together with Route A.

1. Push your reviewed commit of this repository and get its SHA: `git rev-parse HEAD`.
2. Copy `cloud/setup.sh`. Set `REF` to that full 40-hex SHA. While `REF` is the placeholder, or not a 40-hex SHA, the script installs nothing and prints a WARNING. Change `REPO_URL` if you use a fork.
3. Fill `GRANTS`, one line per repository: `owner/repo level [default_branch] [style] [ci]`.
   - `level` is `commit`, `push`, `pr` or `merge`. `style` is `conventional` (default) or `project`. `ci` is `ci` to allow CI file changes, or `-` (default) to refuse them.
   - An omitted `default_branch` is read anonymously with `git ls-remote`, which works for public repositories only. If it fails, the grant is skipped with a WARNING. At level `commit` it is stored as `-`.
   - Blank lines and lines starting with `#` are ignored. Invalid lines are skipped with a WARNING. A second grant for the same repository is skipped with a WARNING; slugs compare case-insensitively.
4. Paste the whole file into the environment's setup script at claude.ai/code and save.

On every run the script first replaces an existing registry with an empty one, before any check, clone or install, so any later failure leaves zero grants (fail closed). If the registry path is a symlink or not a regular file, it is left untouched and no grants are registered. Then it runs `install.sh --no-backup --no-apple-design` with `HOME=/root` (`TARGET_HOME`) and rewrites `/root/.claude/git-publish.registry` completely from `GRANTS`, with mode 600. It always exits 0 and reports problems as WARNING lines. Grants come only from this text, never from a repository, an environment variable or the network.

To revoke, remove the line from `GRANTS` and save. The environment snapshot is rebuilt without it; running sessions keep the old file until they end.

### Publishing in cloud

- With `CLAUDE_CODE_REMOTE=true`, `git-publish.sh` uses a REST backend (`gh api`), because the cloud GitHub proxy blocks GraphQL. `status` ends with `backend: local` or `backend: cloud-rest`.
- Only `github:<owner>/<repo>` registry rows (written by Route B) count in cloud, and only local path rows count locally. Setting the variable elsewhere finds no row, so it cannot raise a level.
- `enable` and `disable` still need a TTY and never write `github:` rows.
- At level `merge`, `pr` opens the PR ready for review. At level `pr` it opens a draft. In cloud, `merge --mark-ready-only` refuses: click Ready for review on GitHub, then run `ci --pr <n> --after-ready`.
- `merge` sends the expected head SHA, and GitHub refuses it with a 409 if the head moved.
- Without Route B there is no `git-publish.sh` in the cloud, so publishing is not available.
- The loopback proxy is reachable by the agent, so the checks use the GitHub API instead of the remote: the base SHA comes from `git/ref/heads/<branch>`, and `merge` takes the PR changed-files list from `pulls/<n>/files`. Either one refuses on failure, and the file list also refuses at 3000 or more files (GitHub truncates it). After the push, `pr` checks that the branch head on GitHub equals the pushed SHA, and the PR URL it gets back must be `https://github.com/<slug>/pull/<n>`.
- `push` goes to the verified URL, not to the `origin` name, so it does not update `refs/remotes/origin/<branch>`. The repository slug matches case-insensitively, and two registry rows for the same slug refuse.
- In cloud, `push` also needs an authenticated `gh` and `jq`, because the base comes from the GitHub API. A repository whose default branch does not exist on GitHub yet (an empty repository) is refused (fail closed).
- `git-publish.sh` refuses a push if git's URL rewriting (`url.<base>.insteadOf` or `pushInsteadOf`) would change the verified URL.
- If `cloud/setup.sh` cannot empty the registry, it removes it, and it warns `REVOKE FAILED` only if that also fails.

### Security model

Publish levels and the guard hooks are a workflow guardrail, not a security boundary. A prompt-injected agent runs as the same OS user (root in cloud) that owns the registry and the hooks. It can bypass regex guards, for example with interpreter writes or `git apply`, and edit the registry or the hooks. Known guard gaps (accepted): `git apply`, `git checkout-index`, `patch -p0 < file` and interpreter writes. The real boundary is GitHub: branch protection or rulesets with required status checks, and required reviews where possible. In cloud, grant `merge` only for protected or low-stakes repositories; prefer `pr`.

### Cloud limits

- Not yet tested: a REST merge through the cloud proxy.
- Unverified: whether the check on repository git config refuses when the cloud adds `http.*`, `credential.*` or `url.*` entries; the format of the proxy origin URL; that `HOME` is `/root`.
- `~/learning` (teacher notes) does not persist between cloud sessions.
- `apple-design` is not available in cloud.

### Smoke test

Run once in a cloud session, through Claude's Bash tool, on a throwaway repository with one CI workflow, granted `merge`, and a second granted `pr`:

1. `id -un; echo "$HOME"; tty || true`
2. Show the `origin` URL with any userinfo masked, then `git config --local --name-only --list`.
3. `~/.claude/hooks/git-publish.sh status` shows the level and `backend: cloud-rest`.
4. A plain `git push` is blocked. A repository you did not grant says it is not registered.
5. Commit on a conventional branch, run `plan`, then `push`.
6. `pr` opens a ready PR at level `merge` and a draft at level `pr`. `merge --mark-ready-only` refuses.
7. `ci`, then `merge` with the expected SHA. This is the first live test of the REST merge.

## Change the setup

The safety hooks block direct edits to `~/.claude`, so changes flow one way. Linting also needs `ruby` and `python3`.

1. Clone this repository and edit its files.
2. Run `python3 tests/lint.py`, `bash tests/test-hooks.sh` and `bash tests/test-git-publish.sh`.
3. Run `bash install.sh --dry-run`, then `bash install.sh`.
4. Commit, and add an entry to the changelog in `ORCHESTRATION.md`.

## Token savings

- `hooks/filter-test-output.sh` is a `PreToolUse` hook on Bash. It rewrites only allowlisted test, build and lint commands that contain no shell metacharacters (quotes, `;`, `&`, `|`, `<`, `>`, backtick, `$`, `#`, backslash or newlines): `npm test`, `npm run test|build|lint` (optionally with a `:suffix`, for example `npm run test:unit`), `pnpm test|run test|run build|run lint`, `yarn test|build|lint`, `npx jest|vitest`, `pytest`, `python -m pytest`, `python3 -m pytest`, `go test|build|vet`, `cargo test|build|clippy`, `make test|build|lint|check`, `bash tests/<name>.sh` and `python3 tests/<name>.py`, each with optional simple arguments.
- The rewritten command has the form `( set -o pipefail; <cmd> 2>&1 | '<hooks dir>/filter-test-output.sh' --filter )`. The command runs in the Bash tool's own shell, so aliases and functions such as `nvm` keep working, and `pipefail` preserves its exit code. The hook script never executes commands; any argument other than `--filter` exits 2.
- `--filter` shows output of 200 lines or fewer unchanged. Longer output keeps the first 20 lines, lines with failure markers (`FAIL`, `ERROR`, `Traceback`, `panic:`, `panicked at`, TypeScript `error TSnnnn`, ESLint error columns, Mocha `N failing` and similar) with 2 lines of context (capped at 150 lines), and the last 60 lines, then ends with `[filter-test-output] N lines total; full log: PATH`. Printed lines longer than 2000 characters are truncated.
- The full log is in `${TMPDIR:-/tmp}` with mode 600; the agent can Read it. The stored log is capped at 50 MB (later output is discarded), and this user's logs older than 1 day are deleted on the next run. If no log file can be created, the output passes through unchanged.
- On interrupt or timeout (`TERM`, `INT`, `HUP`), the filter prints the same view and ends with `interrupted after N lines; full log: PATH`. If the process is killed with `SIGKILL`, no trap runs: the log stays on disk but its path is not printed.
- The filter waits for end of output, so a command that leaves a background child holding stdout open (for example a test server started by `make test`) now runs until the Bash tool timeout. For such commands set `CLAUDE_FILTER_OUTPUT=0` or run them in the background. Calls with `run_in_background` are never rewritten.
- It fails open: with `jq` missing or any other problem it changes nothing. It never blocks and never sets `permissionDecision`. `guard-bash.sh` runs in parallel on the original command.
- Opt out for a session with `CLAUDE_FILTER_OUTPUT=0` in the environment. `install.sh` never removes hook entries, so to disable the hook for good, delete its entry from `~/.claude/settings.json` by hand.
- Your own allow rules such as `Bash(npm test:*)` may no longer match the rewritten command, so those commands may prompt. Do not add a wildcard allow rule for the wrapper: it would auto-approve any command that pipes into the filter. If prompts are a problem, set `CLAUDE_FILTER_OUTPUT=0` to disable the rewrite.
- In auto mode, the Claude Code documentation says a rewritten call without a `permissionDecision` can be denied by auto mode. This is not verified in practice; use the opt-out if you see denials.
- Round 2: `explorer`, `test-runner`, `researcher` and `skill-scout` set `omitClaudeMd: true`, so Claude Code does not load the project `CLAUDE.md`, `.claude/rules/*.md` or `~/.claude/CLAUDE.md` into them (checked on Claude Code 2.1.325). Each agent restates a compact safety line, and the orchestrator puts project conventions and commands into their briefs. This needs Claude Code 2.1.271 or newer.
- Round 2: the global rules are split out of the project preamble (`orchestration-global.md`) and excluded locally by `claudeMdExcludes`, so a local session does not load them twice. See the export notes above.
- Separately, agent frontmatter sets `effort` to `low` for `explorer`, `test-runner`, `quick-fixer` and `skill-scout`, and to `medium` for `doc-writer` and `orchestrator`. `tests/lint.py` accepts `low`, `medium`, `high`, `xhigh` and `max`.
- `release-manager` no longer preloads the `git-workflow` skill. It reads the skill when it does commit, push, PR or merge work; BRANCH mode does not need it. The publish and merge steps are in `agents/release-manager.md`.
- Agent final reports are capped at about 25 lines. Long material goes to a scratchpad file; read-only agents summarise instead.
- Slow test suites run once, through `test-runner`, after the implementers batch their fixes. Implementers run targeted tests only and do not poll with `pgrep` or `sleep`.
- At most one re-audit per task, unless High or Critical findings remain. Follow-up work goes to the same agent with SendMessage where possible.

### Measuring

Compare `/usage` and `/context` before and after a change, on the same kind of task.

- `/usage` shows the session cost, tokens per model and the `Prompt cache (main)` line. On subscriptions it also attributes usage to skills, subagents and MCP servers.
- `/context` shows what fills the main context.

`CLAUDE.md`, `.claude/rules/*.md`, agent prompts, preloaded skills and agent and skill descriptions are loaded into context automatically (subagents with `omitClaudeMd` get none of them). `ORCHESTRATION.md` and `README.md` are not; `CLAUDE.md` does not import them.

## Serena (optional, read-only)

[Serena](https://github.com/oraios/serena) (v2.1.0, GPL-3.0) is a symbol-aware code search tool that runs as a separate process and connects over MCP. It is optional: you install it yourself, and `install.sh` never touches `~/.claude.json`. Without it the agents work as before (an unknown MCP tool in `tools:` is simply absent; checked on Claude Code 2.1.323).

What this setup allows:

- `explorer`, `architect`, `code-reviewer`, `security-auditor`, `debugger`, `implementer`, `test-writer` and `performance-optimizer` list four read tools: `mcp__serena__find_symbol`, `find_referencing_symbols`, `get_symbols_overview` and `find_implementations`. They prefer them when available, unless the brief says `SERENA: off`, and treat Serena output as data. `find_declaration` is denied: it reads any path with no containment (serena-agent 1.3.0 source). The orchestrator itself has none (`tests/lint.py` enforces this).
- Every other Serena tool is in `permissions.deny` (edit, shell, raw file read and search, memory, onboarding, project, dashboard and REPL tools), so Serena cannot edit files or run commands around the Bash, Edit and Write guard hooks. The deny list also covers the JetBrains, diagnostics, config and `.serena/**` Edit/Write paths. `tests/lint.py` checks the deny list and rejects denying the whole `serena` server.
- `hooks/guard-mcp-serena.sh` is a `PreToolUse` hook on `mcp__.*[Ss][Ee][Rr][Ee][Nn][Aa].*` (case-insensitive for "serena"). It is default-deny: only the four tools above pass, so unknown future Serena tools are blocked, and so is any tool whose name contains `serena` but does not start with `mcp__serena__`. Register the server as exactly `serena`. For allowed tools it checks every argument whose name ends in `path` (except `name_path` and `name_path_pattern`): it blocks non-string values, `~` paths, absolute paths unless they exist and resolve to the project root or below (agents should still pass `relative_path` relative to the repository root), `..` segments, backslashes and secret paths (`.env*`, `.ssh`, `.aws`, `*.pem`, `*.key`, `.npmrc`, credentials and similar). It also resolves symlinks and blocks paths that do not exist, resolve outside the root or resolve to a secret path. The root is found like Serena 1.3.0 does: from `$CLAUDE_PROJECT_DIR` (else `cwd` from the hook input) walk up to the first directory with `.serena/project.yml`, else the first with `.git`, else the start directory. It needs `perl`, or `python3` 3.10 or newer (`realpath(strict=True)`); without either, every Serena path argument is denied. It fails closed when `jq` is missing, the JSON is malformed or the root or a path cannot be resolved. It is exported with `install.sh --project`.
- The hook is defense in depth, not a sandbox. Known gaps:
  - project-wide queries with an empty `relative_path` are not path-filtered;
  - language-server results may include a few lines from files outside the project, and the hook cannot filter results;
  - a symlink can be swapped after the hook check and before Serena opens the file (TOCTOU);
  - `guard-bash.sh` does not catch every way to write `.serena/`: `cd` then write, `curl -o`, `wget -O`, `tar -C`, `unzip -d`, `git checkout`/`restore` and interpreters;
  - a name such as `CredentialsService.java` is a false positive;
  - absolute paths can be falsely denied (fails safe) when a directory above the project root has a secret-like name (`secrets/`, `.aws`, `.ssh`, a name containing `credentials`), or on macOS when the path is written with different letter case than the real path; pass relative paths to avoid both;
  - the audit was done on serena-agent 1.3.0; 2.x is unverified;
  - the server must be registered as `serena`;
  - the hook computes the root from `$CLAUDE_PROJECT_DIR` (else `cwd`), assuming Serena was launched from the same directory; if they differ, the roots can differ.
- Serena walks up from the working directory to the main checkout's `.serena/project.yml`, so whenever the primary working directory contains `/.claude/worktrees/` (`EnterWorktree` or `claude -w`) the orchestrator puts `SERENA: off` in every brief.
- Because onboarding and memory tools are denied, agents ignore Serena's onboarding prompts. That is expected.

Install (you run these):

```bash
uv tool install -p 3.13 serena-agent
serena init
claude mcp add --scope user serena --env SERENA_USAGE_REPORTING=false -- serena start-mcp-server --context claude-code --project-from-cwd --open-web-dashboard False
```

- Do not install Serena through an MCP or plugin marketplace; the Serena README warns against it.
- Required: in `~/.serena/serena_config.yml` set `web_dashboard: False` (otherwise the dashboard listens on `127.0.0.1:24282`) and `fixed_tools: [find_symbol, find_referencing_symbols, get_symbols_overview, find_implementations]`. `fixed_tools` was verified on serena-agent 1.3.0 and is unverified on 2.x.
- `--project-from-cwd` trusts a repository's `.serena/project.yml` (`initial_prompt`, `ls_specific_settings`, included tools). Inspect or remove it in untrusted repositories. Edit and Write on `.serena/**` are denied for agents, and `guard-bash.sh` blocks Bash writes (redirects, `tee`, `cp`, `mv` and similar) to `.serena/`; interpreter writes are not covered.
- Existing installs: run `uv tool upgrade serena-agent`.
- Serena writes `~/.serena/` (config, logs) and `<project>/.serena/` (`project.yml`, memories). Add `.serena/` to the project's `.gitignore`.
- Repositories with several languages: Serena auto-detects only the main language, so files in other languages are reported as "path is ignored" or have no active language server. Edit `.serena/project.yml` and list them all under `language_servers:` (Serena 2.1.0; for example `- bash` and `- python`). Each file uses the first listed server that supports it, and the first entry is the default and the fallback. Valid names are in the file's header comment. Restart the Claude session after editing it.
- Upgrading from 1.9.0 or earlier: Claude Code warns about `Write(...)` deny rules (`Edit(path)` already covers Write). `bash install.sh` never removes entries, so delete any `Write(...)` entries from `~/.claude/settings.json` by hand to silence the warning. Project settings re-exported with `install.sh --project` keep them too until you remove them by hand.
- If startup is slow, raise `MCP_TIMEOUT` (for example `60000`).
- Token impact is not measured here. Compare `/context` and the task usage before and after installing.
- Uninstall: `claude mcp remove serena --scope user`. The deny entries stay in `~/.claude/settings.json` until you delete them by hand, because `install.sh` never removes entries.

## Playwright MCP (optional, localhost only)

[Playwright MCP](https://github.com/microsoft/playwright-mcp) (`@playwright/mcp`, tested with 0.0.85) lets agents open, observe and interact with pages served on your own machine. It is optional: you register it yourself, and `install.sh` never touches `~/.claude.json`. Without it the agents work as before (the tools are simply absent and they fall back). In Claude Code cloud the server is not registered, so the tools are absent there too.

Register it once (you run this). It needs Node/npx and Google Chrome; to use Chromium instead, drop `--browser chrome` and run `npx playwright install chromium`.

```bash
claude mcp add --scope user playwright -- npx -y @playwright/mcp@0.0.85 --browser chrome --headless --isolated --no-webmcp --block-service-workers --output-dir "$HOME/.cache/playwright-mcp" --proxy-server http://127.0.0.1:9 --proxy-bypass "localhost,127.0.0.1,[::1]" --allowed-origins "http://localhost:*;http://127.0.0.1:*;http://[::1]:*;https://localhost:*;https://127.0.0.1:*;https://[::1]:*"
```

- The server must be registered as exactly `playwright`.
- Keep TCP port 9 unused: it is the dead proxy. Check with `lsof -nP -iTCP:9 -sTCP:LISTEN`; it should print nothing. The hook runs the same check on every call and denies everything if something listens or `lsof` is missing.
- Without `--output-dir`, files land in `<cwd>/.playwright-mcp/` inside the project.
- `--scope local` in a project directory also works for a per-project registration; whether it is visible under `.claude/worktrees/` paths is unverified.
- Never add these flags: `--caps`, `--allow-unrestricted-file-access`, `--cdp-endpoint`, `--extension`, `--user-data-dir`, `--storage-state`, `--save-session`, `--ignore-https-errors`, `--no-sandbox`, `--grant-permissions`, `--init-script`, `--init-page`.

Layers:

1. `hooks/guard-mcp-playwright.sh` is a `PreToolUse` hook on `mcp__.*([Pp][Ll][Aa][Yy][Ww][Rr][Ii][Gg][Hh][Tt]|__browser_).*`. The matcher also routes other MCP servers' `browser_*` tools to the hook, which blocks them. It is default-deny: only 19 allowlisted tools pass (anything else, including new tools in a later server version, is blocked), and the tool name must start with `mcp__playwright__`. Checks:
   - Every call is denied when something listens on TCP port 9. This runs first, with two signals: a bash-builtin connect to `127.0.0.1:9` (`/dev/tcp`, which sees listeners of any user) and `lsof`. When bash has `/dev/tcp`, a missing `lsof` is tolerated; when it does not, `lsof` is required (fail closed; on Linux without `lsof`, install it).
   - `tool_input` must be an object.
   - Only each tool's known top-level arguments pass (from the `@playwright/mcp` 0.0.85 schema; `filename` is removed, and `isolatedContext` of `browser_tabs` is not allowed). Any other argument is denied. When you update `@playwright/mcp` beyond 0.0.85, update the per-tool argument list in the hook too; new arguments are denied until then.
   - Every key at any depth is checked, with names lowercased: file keys (`filename`, `file`, `files`, `directory`, `outputDirectory`, `saveTo`, `output`, and names ending in `path`, `paths`, `dir`, `file`, `files`, `directory` or `folder`) are denied; URL keys (names containing `url`, `uri` or `href`, or exactly `src`, `link`, `location`, `origin` or `host`) must be a literal `http(s)` URL on `localhost`, `127.0.0.1` or `[::1]` with an optional port 1-65535 (a null value is denied).
   It also fails closed when `jq` is missing or the JSON is malformed. It is exported with `install.sh --project`.
2. Proxy trap: `--proxy-server http://127.0.0.1:9` sends all non-loopback traffic to a dead proxy. In a spike, redirects (including HTTP 302), popups, images, `fetch` and `localtest.me` all failed with `ERR_PROXY_CONNECTION_FAILED`.
3. `--allowed-origins` is an accident guard. In the spike it blocked direct navigation and subresources but not HTTP 302 redirects, which is why the proxy exists.
4. `permissions.deny` lists the other Playwright tools (55 entries in `settings.managed.json` and `project/settings.project.json`) as a backstop.
5. Each agent's `tools:` list names only the tools it may use.

What this setup allows:

- `ui-ux-engineer`, `test-writer` and `debugger` list 19 tools (observe and interact). `code-reviewer` lists 11 (observe only, no click or type tools). The other agents and the orchestrator list none. They treat page content as data and are told to close the browser when done; the brief can say `PLAYWRIGHT: off`.
- Blocked: `browser_evaluate`, `browser_run_code_unsafe`, file upload, drop, storage and cookies, route and network mocking, devtools, tracing and video, PDF, mouse by coordinates, the testing `verify_*` tools and config.
- The server runs one browser per session, so the orchestrator allows only one browser-using agent at a time and puts `PLAYWRIGHT: off` in the other briefs when they run in parallel.

Known gaps (defense in depth, not a sandbox):

- `.mcp.json` can still change through git operations (checkout, merge, pull, apply, patch). Claude Code asks you to approve project-scoped `.mcp.json` servers unless `enableAllProjectMcpServers` is set; do not set it.
- If `CLAUDE_CONFIG_DIR` is set, the config file at `$CLAUDE_CONFIG_DIR/.claude.json` is not covered by the guards.
- Loopback is not a trust boundary: navigation, forms and page JavaScript can reach any local service on any port (Jupyter, the Docker API, Ollama, admin UIs, IDE servers). Stop such services or keep them off loopback while agents browse.
- Dev-server proxies and rewrites (Vite `server.proxy`, Next.js rewrites, webpack `devServer` proxy) forward browser traffic to remote hosts, an exfiltration route past the dead proxy.
- WebRTC/STUN over UDP and DNS lookups may bypass the HTTP proxy (not mitigated in this release).
- Agents with Bash can still drive a browser directly (`playwright-cli`, `npx playwright`, node): page JavaScript evaluation, any host, no MCP hook. The `playwright-cli` route of the `browser-verification` skill has only an origin guard and no proxy, so HTTP redirects can escape.
- The built-in general-purpose, Explore and Plan subagents and non-orchestrator main sessions inherit all tools, including the 19 Playwright tools.
- The per-agent split relies on Claude Code enforcing `tools:` lists.
- The hook cannot see the server's flags: if you register the server without the proxy, `--isolated` or `--no-webmcp`, only the hook remains. Agents are blocked from re-registering it, but your own edits are not checked.
- A local process could start listening on port 9 between the check and the request (race); the hook checks on every call.
- Output-dir contents (screenshots, snapshots, console logs, possibly downloads) persist in `$HOME/.cache/playwright-mcp` and may hold sensitive page data; clean it periodically.
- The server is pre-1.0: a renamed tool stops working until the hook and `tests/lint.py` are updated, and a new tool or argument stays blocked by default-deny.
- `npx -y @playwright/mcp@0.0.85` pins only the top-level package; transitive npm dependencies are not locked.
- A GET on localhost can still change app state, even for the observe-only `code-reviewer`.
- Page text can carry prompt injection; agents treat it as data, which is advisory only.
- Key matching is ASCII-lowercase name matching, so any key ending in `file` and similar is a file key and may cause false denials.

Uninstall: `claude mcp remove playwright --scope user`. The hook and deny entries stay in `~/.claude/settings.json` until you delete them by hand, because `install.sh` never removes entries.

## Context7 MCP (optional, library docs)

[Context7](https://context7.com) is a remote MCP server that returns library documentation. It is optional: you register it yourself, and `install.sh` never touches `~/.claude.json`. Only `researcher` has its tools. Without the server, `researcher` uses WebFetch and WebSearch as before.

Register it once (you run this):

```bash
claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp
```

- The server must be registered as exactly `context7`.
- For an API key, add `--header "Authorization: Bearer <YOUR_CONTEXT7_KEY>"` to the same command. Use your own key; never commit it or paste it into a brief.
- Uninstall: `claude mcp remove --scope user context7`. The hook entry stays in `~/.claude/settings.json`, because `install.sh` never removes entries; without the server it has no tool calls to check.

Layers:

1. `hooks/guard-mcp-context7.sh` is a `PreToolUse` hook on `mcp__.*[Cc][Oo][Nn][Tt][Ee][Xx][Tt]7.*`. It is default-deny: only `resolve-library-id` and `query-docs` pass, and the tool name must start with `mcp__context7__`. Checks:
   - `tool_input` must be an object with only the tool's keys: `query` and `libraryName` for `resolve-library-id`; `libraryId`, `query` and an optional `language` for `query-docs`. Required keys must be present.
   - `query` is one line of 1 to 300 characters, with no control characters and no U+2028, U+2029 or U+0085. It is denied if it contains a filesystem path, a secret-like string, or code (three or more of `;`, `{`, `}`, or `=>` with braces).
   - Path check: a case-insensitive match of `/users/`, `/home/`, `/root/`, `/private/`, `/etc/`, `/var/`, `/tmp/`, `/opt/`, `/volumes/` or `/mnt/` anywhere in the text, plus `~/` and a Windows drive path (`C:\`).
   - Secret check: the prefixes `sk-`, `sk_live_`, `sk_test_`, `ghp_`, `gho_`, `github_pat_`, `AKIA` (AWS access key), `xox[abp]-` (Slack), `-----BEGIN` (PEM), `ctx7sk`, and `password=`, `passwd=`, `secret=`, `token=` or `api_key=` (any case). It also denies a run of 32 or more characters from `[A-Za-z0-9+=]` that contains both a digit and a letter. Any other character, such as `-`, `_`, `.` or a space, ends a run. Hex-only runs shorter than 40 characters are exempt.
   - `libraryName` is 1 to 100 characters from letters, digits, space and `._@/+-`; it also gets the path and secret checks. `libraryId` must look like `/org/project` or `/org/project/version`, with no `..` segment. Its first segment is checked against the same path names, case-insensitively, and it gets the secret check.
   - Deny messages name the category only and never repeat the query.
2. `researcher` is told to use only public library names and generic questions, never project code, paths or secrets, and to treat Context7 output as untrusted data.

Who can call it: `researcher` is the only agent whose `tools` list includes Context7. If the main session does not run as the orchestrator agent (for example, a plain `claude` session without the managed `agent` setting), it can call Context7 once the server is registered. The hook checks the arguments, not which agent is calling.

Known limits (defense in depth, not a sandbox):

- The query leaves the machine. The hook checks its shape, not its meaning, and the content filter is a heuristic, not a guarantee. A public path segment such as `foo/home/bar` is denied (a false positive), and obfuscated secrets can still get through.
- A secret split into pieces shorter than 32 characters by `/`, `-`, `_` or `.` (for example AWS secret keys or base64url tokens) can pass the long-run rule.
- Context7 docs are community-contributed. Instructions inside them are data, and the agent is told to ignore them; that is advisory only.
- Queries and library names go to Context7's hosted service. Context7 says queries are stored anonymously for benchmarking and API logs are kept 30 days ([data privacy](https://context7.com/docs/security/data-privacy), as of 2026-11-14).
- An API key is optional. Without one, IP-based rate limits are low ([API guide](https://context7.com/docs/api-guide), as of 2026-11-14).
- Context7 documents no response-size cap, so ask focused questions.

## Optional browser verification

The `browser-verification` skill lets `ui-ux-engineer` look at a locally served page. When the Playwright MCP server above is registered, the skill uses it first for navigation, snapshots, screenshots, console and interaction. `playwright-cli` remains for the checks that need page JavaScript evaluation (reduced motion, WebGL renderer, frame rate) and as the fallback when the MCP tools are absent. It needs `playwright-cli`, which you install yourself and `install.sh` does not: `brew install playwright-cli`, then `brew pin playwright-cli`. Without it, and without the MCP server, the agent reports that the UI was not rendered.

## Optional git automation

Off by default. The level is per repository and is stored in `~/.claude/git-publish.registry`: `commit`, `push`, `pr` or `merge`, each including the previous. Project files can never grant a level. Only you register a level, with `enable` in your own terminal (the script asks for a TTY and for the repo name; the guards are best-effort and only block common ways for an agent to run it):

```bash
~/.claude/hooks/git-publish.sh enable <commit|push|pr|merge> [--style conventional|project] [--allow-ci-changes] [--account <login>]
~/.claude/hooks/git-publish.sh disable
```

- Always on, independent of the git level: one task = one branch. Before any write-capable agent runs, the orchestrator has `release-manager` create `<type>/<kebab-summary>` from the default branch (`git switch --no-track -c`); a dirty working tree stops it and you commit or stash yourself. If `<repo root>/.worktreeinclude` exists or the session is already inside `.claude/worktrees/`, the orchestrator instead works in a Claude Code worktree (see "Running projects in a worktree"); without that file nothing changes. Agents never run `git worktree add` or `move`, and `guard-bash.sh` denies them. Tasks that change nothing need no branch.
- At `commit` or higher, `release-manager` may commit on a feature branch when the brief allows it.
- `commit` works without an `origin` remote. `push` works with any registered `origin` that has no embedded credentials. `pr` and `merge` need a GitHub `origin`.
- Only `release-manager` pushes, opens PRs and merges, and only through this route in a repository you registered at that level. `status`, `plan`, `push --expect-sha <sha>`, `pr --expect-sha <sha> --expect-content <sha256> --title-file F --body-file F` and `ci --pr <n>`, `merge --mark-ready-only --pr <n> --expect-sha <sha>` and `merge --pr <n> --expect-sha <sha>` need no TTY. A repository at a lower level or unregistered refuses them. `enable` and `disable` need a TTY and are yours alone. Direct `git push`, `gh pr create` and `gh pr merge` stay forbidden and blocked.
- With the title and body files, `plan` prints the PR title, a body preview and a content SHA-256. If the title or body changed after `plan`, `pr` refuses. `plan` is offline, but `push` and `pr` may ask for a fetch first.
- `pr` opens a draft. `merge` needs: the PR open, its head is the current non-protected branch at that SHA, its base is the registered default branch, not cross-repo, title and body pass the checks, and CI has at least one SUCCESS check, none failing, none pending (only SKIPPED or NEUTRAL checks, or no CI, are refused; use level `pr` there). `merge` also checks PR body headings under style `conventional`. It squash merges with the validated PR title as subject. It never uses `--admin` or `--auto` and does not delete the branch.
- Merge is separate steps. `ci --pr <n>` is read-only (level `merge`) and prints `verdict: passed|failed|pending|none|skipped-only`, `skipped: <names or ->`, `draft: true|false`, `url: <PR url>` and `head: <40-hex SHA>` (take the SHA of an existing PR from this line). If the PR is a draft, `merge --mark-ready-only --pr <n> --expect-sha <sha>` marks it ready and exits 0 without merging; it refuses (exit 2) if the PR is not a draft or a check is failing, and the approved plan is enough for it. In the run that marked the PR ready, read `ci --pr <n> --after-ready`, which prints any skipped check, or no checks, as `pending` because draft-gated jobs may not have restarted; later re-checks omit the flag (`merge` has no such flag). The merging run, `merge --pr <n> --expect-sha <sha>`, refuses a draft (exit 2) and never marks it ready. It runs only after the wait described under "Auto-merge on green CI" ends in `passed` with no skipped checks (passed with skipped checks asks you), or after you confirm. Your GitHub workflows should include the `ready_for_review` trigger so CI runs once the draft is marked ready.
- CI and policy files (`.github/workflows/**`, `.github/actions/**`, `CODEOWNERS`, `.github/CODEOWNERS`, `docs/CODEOWNERS`, `.claude/**` at any depth, `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` at any depth, including deletions; names compare case-insensitively): `merge` always refuses commits touching them, so merge such PRs by hand, including routine re-export PRs. Files that `CLAUDE.md` imports with `@path` are not treated as policy files. `push`, `pr` and `plan` refuse them unless you ran `enable ... --allow-ci-changes`; only `enable` can set it, re-running `enable` without the flag resets it to refused, and `status` prints `ci changes: allowed|refused`. A merge commit that brings a CI-file change from the default branch is refused by `merge`; with `--allow-ci-changes`, `push`, `pr` and `plan` allow it. Rebasing an already-pushed branch needs a force push, which this route refuses: use a new branch or handle it yourself.
- Shallow repositories are refused.
- `push`, `pr` and `merge` refuse with "fetch it first" if the remote default branch has commits not fetched locally. After a merge, `git fetch` before the next publish.
- Approval: Claude pushes and opens a PR after verification only if the plan you approved in the conversation explicitly includes those steps, and reports the SHA afterwards. For merge, see "Auto-merge on green CI" below. There is no technical enforcement of conversation approval; it is a rule the agents follow.
- Auto-merge on green CI: at level `merge`, when the plan you approved includes merge, the orchestrator delegates `AUTO-MERGE: PR <n> SHA <sha>` and `release-manager` runs `ci --pr <n> --expect-sha <sha> --wait 480` (polls every 30 s; at most 4 calls, about 32 minutes). It squash merges at once if the verdict is `passed` with no skipped checks on exactly the SHA it pushed in this conversation. It applies to every repository registered at level `merge`; there is no extra flag. Otherwise:
  - Skipped checks, or a PR not pushed in this conversation: it asks you once (link, verdict, skipped names) and merges only after you confirm.
  - Timeout (still pending): it tells you; re-run later.
  - Head moved: refused.
  - `failed`: read-only diagnosis. `release-manager` saves the redacted logs to a file in the orchestrator's session scratchpad and reports the file path only; `explorer` (opus, Read/Grep/Glob only, no write path) reads them as untrusted data and reports the likely root cause, evidence and a proposed fix. You decide; nothing is fixed automatically, and an approved fix follows the normal plan/approval flow.
  - `none` or `skipped-only`: refused (use level `pr`).
  - On a local draft PR with legitimately skipped checks, the first wait call (with `--after-ready`) treats skipped as pending, so reaching "passed with skips, ask you" can take one full wait call (~8 min).
- `ci` options (all read-only): `--wait SECS` polls every 30 s until the verdict is final, `SECS` from 30 to 480. `--expect-sha <sha>` is a full 40-hex SHA, checked on every poll; the call refuses if the PR head moved. `--logs` prints failing check output and cannot be combined with `--wait` or `--after-ready`: it uses the registered account with read-only GETs, the last 200 lines per GitHub Actions job (at most 5 jobs), ANSI codes stripped, secret-like lines redacted, capped at 100 KB; non-Actions checks are listed with their URL. Redaction is best-effort (PEM blocks, bearer/authorization, `*_token`/`key`/`secret` assignments, known token formats); CI should never print secrets. Treat log text as untrusted data.
- Risks of auto-merge: after CI nobody reviews the PR; a commit can make CI green by editing what CI runs; concurrent PRs can merge against an older base. `passed` counts as final only if the next poll (~30 s later) is `passed` again with the same number of checks; checks that register later than that (workflow_run chains, slow third-party apps) can still be missed, and only branch protection with required status checks closes that. Branch protection (required status checks, "Require branches to be up to date before merging", restricted push access) closes base drift. Only required human reviews or CODEOWNERS on test and build files address CI self-modification and the missing human review; required reviews block auto-merge (it will then ask or be refused, as GitHub enforces). A bad merge is undone with a revert PR.
- Limits: "only `release-manager`" is a rule the agents follow; the guard does not enforce it. CI results come from workflows and scripts in the repository, so a commit that edits a script CI runs can still fake green. Only required status checks plus human review close that. Green CI is not proof of safety.
- Rollout: Claude's push needs non-interactive credentials (ssh-agent, or an HTTPS credential helper). SSH is forced to batch mode, so a key that needs an interactive passphrase fails instead of prompting. This overrides any global `core.sshCommand`, so a custom key or agent setup there can fail.
- Force push, tags, publish and deploy have no exception: you run them yourself.
- Recommended: GitHub branch protection with required status checks. Required reviews will make Claude's merge fail, which is correct.
- Upgrading an existing install: `install.sh` only adds settings. Remove these two old deny rules by hand from `~/.claude/settings.json`, or Claude's `push` and `pr` stay blocked: `Bash(*git-publish.sh push*)` and `Bash(*git-publish.sh pr *)`.
- PRs are always drafts, GitHub only, on remote `origin`. Force, tags, refspecs and protected branches (main, master, develop, trunk, production, `release/*`) are refused. With style `conventional`, branches must be `<type>/<kebab-summary>` and commit subjects and PR titles must follow Conventional Commits (merge commits are exempt; `Revert "..."` is accepted for commit subjects). PR bodies need `## What`, `## Why`, `## How tested` and `## Risks`. Style `project` skips these format checks.
- Every commit since the merge-base is scanned on its own, so a secret added and later removed is still refused. Forbidden files include `.env*` (except `.env.example`, `.sample`, `.template`, `.dist`), keys, `*.tfvars` and `*.tfstate`.
- Repo hooks (pre-push, husky, gitleaks) do not run on this route, because a repo hook would run with your credentials. `plan` warns when a pre-push hook exists. Git LFS repositories are refused. Repo-local `core.sshCommand`-style overrides, `credential.*`, `url.*`, `protocol.*` and most `http.*` settings are refused (allowed: `http.postBuffer`, `lowSpeedLimit`, `lowSpeedTime`, `version`, `maxRequests`).
- Clean environment, for every row: the script re-runs itself through `env -i` under `bash -p`, keeping only an allowlist: `USER`, `LOGNAME`, locale (`LANG`, `LC_*`), `TERM`, `TMPDIR`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, proxy variables, `GH_TOKEN`/`GITHUB_TOKEN`, `CLAUDE_CODE_REMOTE`, `GIT_CEILING_DIRECTORIES` and the cloud CA variables. Exported shell functions, `BASH_ENV`, trace and debug variables and any other variable from the caller do not reach `gh` or `git`. `TMPDIR` must be an absolute path. `XDG_RUNTIME_DIR` is kept only if it is exactly `/run/user/<uid>`, a directory owned by you that group and others cannot write, and `DBUS_SESSION_BUS_ADDRESS` only if it is exactly `unix:path=<that directory>/bus` (optionally `,guid=<hex>`); any other value is dropped (on macOS both are always dropped, which `osxkeychain` does not need). Running the script as `bash -s`, `bash < script` or `bash -c "$(cat script)"` is refused with "run the script by its path".
- The check that refuses a global `insteadOf`/`pushInsteadOf` rule that would rewrite the registered URL again now runs in every preflight (`plan`, `push`, `pr`, `merge`) and in `enable`, before any network call, not only at push time. On the local backend, `SSL_CERT_FILE`, `SSL_CERT_DIR` and `CURL_CA_BUNDLE` are always dropped, so a TLS-inspecting corporate proxy that needs them does not work here. `core.askPass` is forced empty, so `SSH_ASKPASS` and any configured askpass program are never run; credentials must come from ssh-agent or a credential helper.
- The guards are a best-effort regex layer. They stop accidents and common command forms from careless or injected agents, and known forms can still get through. They are not a boundary against code run deliberately under your OS user. A deliberately evasive agent can still bypass the guards and grant itself a level, because regex cannot close this. Repositories at level `merge` therefore need branch protection with required status checks. To search for guarded text, use the Grep tool or a plain leading `grep`.
- The hooks fail closed: `guard-bash.sh`, `guard-write.sh`, `readonly-bash.sh`, `guard-mcp-serena.sh` and `guard-mcp-playwright.sh` block when `jq` is missing or their input JSON is malformed (`guard-mcp-playwright.sh` also needs `lsof` unless bash has `/dev/tcp`; see the Playwright section). `guard-bash.sh` also blocks `claude mcp add|add-json|add-from-claude-desktop|remove|reset-project-choices` and shell writes to `~/.claude.json` and any `.mcp.json`; `guard-write.sh` blocks Edit and Write on the same two files, so MCP servers are registered by you, not by agents. The literal text `claude mcp add` in a Bash command is blocked too (same trade-off as the git push rule). The rule also covers `claude-code`, `npx`/`bunx`/`pnpm dlx` launchers, a command variable or substitution before `mcp add`, `xargs claude`, and `>|` redirects to these files; evasive forms are best-effort only. `guard-bash.sh` also blocks `curl -o`, `wget -O` or `-P`, `tar -x -C`, `unzip -d`, `git checkout`, `git restore` and `patch` that target a project's `.claude/hooks`, `.claude/settings*.json`, `.claude/rules` or `.claude/agents`; top-level `agents/` and `skills/` directories are not affected. Known gaps: `git apply`, `patch -p0 < file` and interpreter writes.
- Blocked for all projects: direct `gh pr create|new|ready|edit|merge`, `gh api` writes, `gh repo create|sync`, `gh release upload|edit`, `gh workflow run`, `gh secret set`, `gh extension install`, `gh auth token`, `git credential fill`, and agent writes to `~/.gitconfig` and `~/.claude/hooks`. `gh pr comment|close` and `gh issue` stay allowed.
- Check it with `bash tests/test-git-publish.sh`.

### Multiple GitHub accounts

By default, `git-publish.sh` uses the account that `gh` has active, so you had to run `gh auth switch` between repositories owned by different accounts. `enable ... --account <login>` stores a GitHub login for one repository (optional 7th column of the registry). Only you set it, with `enable` in your own terminal; agents cannot run `enable`.

```bash
~/.claude/hooks/git-publish.sh enable pr --account <login>
gh auth status   # the active account is unchanged
~/.claude/hooks/git-publish.sh status   # prints account: <login>
```

- `enable` refuses when: the level is `commit`; the push URL is not `https://github.com/...` (SSH remotes are refused: switch `origin` to HTTPS); `gh` is older than 2.40 (no `gh auth token --user`); the account is not logged in; the token belongs to another account; or the account has no push access to the repository.
- Re-running `enable` without `--account` clears it (nothing is inferred). `status` prints `account: <login>`, `active` (registered, no account) or `-` (not registered).
- At run time, `push`, `pr`, `merge` and `ci` fetch the account token once with `gh auth token --user` and check it with `gh api user`. The token goes to each `gh` call through `GH_TOKEN`, and to `git push` and `ls-remote` through a credential helper scoped to `https://github.com` that reads an environment variable. It is not exported to your session, not put on a command line and not printed. A `GH_TOKEN`/`GITHUB_TOKEN` from the caller is ignored in account mode.
- A failure stops with a message naming the account. There is no fallback to the active `gh` account.
- Rows without an account behave as before, and a caller `GH_TOKEN` still passes through.
- Cloud backend: the account does not apply, and a cloud `github:` row with an account is treated as unregistered.
- Downgrade: an older `git-publish.sh` treats a 7-column row as unregistered (fails closed), and an older `enable` rewrites the row without the account.
- In account mode, git uses no credential helper other than the account's (the helper list is reset for every URL), the session bus variables reach only the `gh auth token` keyring call, proxy variables that contain a user name are dropped, and `gh` runs from `/` so that git filters configured in the repository never run with the token in their environment. Repo-local `filter.*` and `submodule.*.update` settings are refused for a repository with an account (for example git-crypt or nbstripout filters); other `submodule.*` settings stay allowed, and repositories without an account are not affected.
- Residual exposure: these guards are best-effort, not a security boundary. An agent running as your user that can run commands in the background can read the token while `gh` or `git` run (for example with `ps eww`, which shows their environment). It can also read it from `gh`'s own keychain item or config file. The forced `PATH` includes `/opt/homebrew/bin` and `/usr/local/bin`, which your user can write, so such an agent could also replace `gh` or `git` there; this is the same class of exposure. Running the script as `bash <script>` with a `BASH_ENV` file, or with exported `exec`, `builtin` or `command` functions, runs that code before the script can re-run itself (closing this needs a `guard-bash.sh` rule, a planned follow-up).

## Running projects in a worktree

Opt-in, per repository. If `.worktreeinclude` exists at the repository root, the orchestrator calls `EnterWorktree` with the name `<type>-<kebab-summary>` (for example `feat-login`) instead of creating a branch. Claude Code creates `.claude/worktrees/<name>/` on branch `worktree-<name>` from the default branch and copies the gitignored files that match `.worktreeinclude`. `release-manager` then runs in WORKTREE-CHECK mode: it verifies the worktree, clean tree and base, renames the branch to `<type>/<kebab-summary>` (for example `feat/login`) because `git-publish.sh` with style `conventional` refuses `worktree-*` branches (it renames only if the branch has no upstream or tracks `origin/<base>`, and neither name exists on origin; otherwise it reports BLOCKED), and lists the matching env file names only (present names, not proof of copy), never their contents. If the session may start in a subdirectory, the orchestrator finds the repository root first. All later agents work in the worktree. Without `.worktreeinclude`, nothing changes and the branch workflow applies.

`.worktreeinclude` uses `.gitignore` syntax. Only files that match a pattern and are gitignored are copied. Prefer explicit paths: a pattern that begins with `**/` has special rules.

```text
.env
apps/web/.env.local
```

- The file holds patterns only, no secrets, so commit it.
- Copies are snapshots. Editing the main `.env` later does not update existing worktrees.
- Install dependencies inside the worktree.
- A dev server in the worktree can clash on ports with one running in the main checkout.
- The worktree and its branch stay after the task. To resume, ask the orchestrator for it or start Claude Code inside it. The orchestrator calls `ExitWorktree` only when you ask, and keeps the worktree unless you ask to remove it and the work is pushed or merged. After a remove the renamed branch remains: delete it with `git branch -d <branch>` yourself (the ExitWorktree message may show the old name).
- To clean up yourself after the branch is merged, run `git worktree remove <path>` in your own terminal. Agents never run `git worktree add` or `move`.
- You can create the worktree yourself instead: `claude -w <name>` (after the global install the main session is already the orchestrator; `--agent orchestrator` also works). A session already inside `.claude/worktrees/` always uses WORKTREE mode; for an unrelated new task, start a new session.
- `.worktreeinclude` and the files it names must exist in the main checkout when the worktree is created.
- Only worktrees created by Claude Code copy these files. A plain `git worktree add` does not.
- The base is the remote default branch unless the Claude Code setting `worktree.baseRef` says otherwise (`fresh` is the default, `head` is the alternative).

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
| `settings.managed.json` | Merged into `~/.claude/settings.json` | Permissions, hooks, model and default agent |
| `project/` | Not installed | Inputs for `install.sh --project`: rules preamble and project settings |
| `cloud/setup.sh` | Not installed | Experimental setup script for the cloud environment |
| `.claude/` | Not in the repository by default | Optional export, generated with `bash install.sh --project .` and committed by you; do not edit; check with `bash tests/check-project-export.sh` |
| `tests/` | Not installed | Lint, hook and install checks |
| `bin/cli.js`, `package.json` | Not installed | `npx` entry point |

## How settings merge

Values in `settings.managed.json` win. Other settings on the machine stay. `permissions.deny` and `hooks` only gain entries, and the installer removes nothing.

### Default agent

The global install sets `"agent": "orchestrator"` in `~/.claude/settings.json`, so every local `claude` session starts as the orchestrator: opus, no Edit, Write or Bash in the main thread, and the Stop hook reminder. The header shows `@orchestrator`. This also applies to non-interactive runs (`claude -p`, scripts, wrappers), which then also have no Edit, Write or Bash in the main thread; use `claude --agent <name>` for such runs.

- One session: `claude --agent <other-agent>` overrides the setting.
- One project: set a different `agent` in that project's `.claude/settings.local.json`.
- Everywhere: delete the `"agent"` line from `~/.claude/settings.json`. The next `bash install.sh` writes it back.

## Third-party skills

| Skill | Source | Commit | License |
| --- | --- | --- | --- |
| `multi-stage-dockerfile` | `github/awesome-copilot` | `caab1f6` | MIT |
| `java-junit` | `github/awesome-copilot` | `52a5840` | MIT |
| `swift-testing-pro` | `twostraws/swift-testing-agent-skill` | `2d6bba1` | MIT |
| `find-skills` (preloaded by `skill-scout`) | `vercel-labs/skills` | `d3701c1` | MIT |
| `gsap-core`, `gsap-timeline`, `gsap-scrolltrigger`, `gsap-plugins`, `gsap-performance`, `gsap-react` | `greensock/gsap-skills` | `aed9cfd` | MIT |
| `threejs-fundamentals`, `threejs-performance`, `threejs-loaders`, `threejs-react-three-fiber`, `threejs-shaders`, `threejs-postprocessing`, `threejs-materials`, `threejs-textures`, `threejs-lighting`, `threejs-animation`, `threejs-interaction`, `threejs-geometry` | `CloudAI-X/threejs-skills` | `0e18186` | MIT |

These are exact copies of the reviewed text. Review an upstream change before replacing a file here. `apple-design` is cloned at a pinned commit and is not stored in this repository.

## Not included

- Claude Code sign-in and credentials
- MCP connections and plugins
- Skills synced from claude.ai, which arrive with your account
- Session history and project memory

## Privacy

Keep project-specific notes in each project's `CLAUDE.md`, or in a `*.local.md` file here, which git ignores.

Never commit secrets. `.gitignore` covers common secret files, but check `git status` before committing.

## Roll back

`install.sh` prints a restore command with its backup path. A restore does not remove files that the install added.
