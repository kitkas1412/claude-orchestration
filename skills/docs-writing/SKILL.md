---
name: docs-writing
description: Write documentation that is accurate and usable. Use for README files, ADRs, changelog entries, how-to guides, API docs and docstrings. Keywords - README, ADR, architecture decision record, changelog, Keep a Changelog, runbook.
---

# Documentation writing

## When to use

Use for any documentation task. Templates:

- ADR: `~/.claude/skills/docs-writing/assets/adr-template.md`
- Changelog: `~/.claude/skills/docs-writing/assets/changelog-template.md`

## Procedure

1. Identify the reader and the task they want to complete.
2. Match the existing language, structure and tone.
3. Verify every command, option, path and behavior against the code or config.
4. Lead with what the reader needs first. Put reference detail later.
5. Use runnable examples and placeholders for anything sensitive.

## By document type

- README: what it is, requirements, install, run, test, configuration, where to go next.
- ADR: one decision per record, with context, alternatives and consequences.
- Changelog: user-visible changes grouped as Added, Changed, Deprecated, Removed, Fixed, Security.
- How-to: prerequisites, numbered steps, and how to confirm success.
- Docstring: explain purpose, inputs, outputs, errors and non-obvious constraints.

## Checklist

- Every claim was checked against the source.
- Commands can be copied and run as written.
- No secrets or internal hostnames appear.
- Anything unverified is listed under OPEN.

## Examples

Weak: `Run the app using the appropriate command.`

Strong: `Run npm run start:dev, then open http://localhost:3000/health.`

## Anti-patterns

- Describing what the code obviously does line by line.
- Documenting planned features as if they exist.
- Changelog entries copied from commit messages.

---
Version 1.0.0. Last reviewed 2026-11-08.
