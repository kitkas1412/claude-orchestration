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
- `permissions.deny`: blocks reads of env files, keys and credential directories.
- `hooks/git-publish.sh`: per-repository git level (off, `commit`, `push`, `pr`, `merge`) registered by the user with `enable` and kept in the user-level `~/.claude/git-publish.registry`. Only `release-manager` runs `status`, `plan`, `push`, `pr` and `merge` (no TTY), and only at a registered level and when the plan the user approved includes the step; merge also needs one user confirmation once the `ci` verdict is `passed` (marking a draft ready with `merge --mark-ready-only` needs only the approved plan), and CI with at least one SUCCESS check, none failing, none pending. "Only `release-manager`" is a rule, not enforced by the guard. CI results come from repo-authored workflows and scripts, so a commit editing a script CI runs can still fake green; only required status checks plus human review close that. `enable` and `disable` need a TTY and are for the user only. Direct `git push`, `gh pr create` and `gh pr merge` stay blocked. Conversation approval is not technically enforced, and this is not a security boundary: a deliberately evasive agent can still bypass the guards and grant itself a level, because regex cannot close this. Repositories at level `merge` therefore need branch protection with required status checks. Repo hooks (pre-push, husky, gitleaks) do not run on this route. `git commit` is not hook-gated, so the `commit` level is a rule agents follow by reading `status`.

To change this setup, edit the `claude-orchestration` repository and run `install.sh` yourself.

## Changelog

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
