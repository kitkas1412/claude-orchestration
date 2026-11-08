# Claude Code Orchestration

User-level multi-agent setup. Claude Code 2.1.319. Permission mode: `auto`.

## How to start

| Need | Command |
| --- | --- |
| A session dedicated to orchestration | `claude --agent orchestrator` |
| Orchestrate one task in a normal session | `/orchestrate <task>` |
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
| release-manager | sonnet | edit + Bash, no publish |

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
| git-workflow | custom 1.0.0 | release-manager | 2026-11-08 |
| ci-cd-pipelines | custom 1.0.0 | devops-engineer | 2026-11-08 |
| multi-stage-dockerfile | github/awesome-copilot@caab1f6 | devops-engineer | 2026-11-08 |
| java-junit | github/awesome-copilot@52a5840 | test-writer, through `testing-strategy` | 2026-11-08 |
| swift-testing-pro | twostraws/swift-testing-agent-skill@2d6bba1 | test-writer, through `testing-strategy` | 2026-11-08 |
| orchestrate | custom 1.0.0 | main session | 2026-11-08 |
| init-project-orchestration | custom 1.0.0 | main session | 2026-11-08 |
| apple-design | github.com/dickwu/apple-design-skill@904b0ee | ui-ux-engineer, by brief only | 2026-11-08 |
| find-skills | ~/.agents/skills | main session | 2026-11-08 |

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
- `permissions.deny`: blocks reads of env files, keys and credential directories.

To change this setup, edit the `claude-orchestration` repository and run `install.sh` yourself.

## Changelog

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
