---
name: ci-cd-pipelines
description: Design and review fast, secure CI/CD pipelines. Use when creating or changing GitHub Actions, GitLab CI or similar workflows, build and test jobs, caching, release pipelines, or CI permissions. Keywords - GitHub Actions, workflow, pipeline, OIDC, cache, matrix, deployment approval.
---

# CI/CD pipelines

## When to use

Use for pipeline work. Follow the repository's existing CI system. You prepare and validate; you never deploy or push.

## Procedure

1. Read the existing workflows and the project's real install, lint, test and build commands.
2. Order jobs for fast failure: install, lint and type-check, unit tests, integration tests, build, and then packaging.
3. Use lockfile installs such as `npm ci`, and cache by lockfile hash.
4. Set minimum permissions at the workflow level, and grant more only to the job that needs it.
5. Pin third-party actions to a full commit SHA, with the version in a comment.
6. Use OIDC for cloud access where available. Otherwise reference secrets by name only.
7. Put deployments behind a protected environment with required approval.
8. Validate locally with available tools such as `actionlint` or `act`. Report what could not be validated.

## GitHub Actions security

- Default to `permissions: contents: read`.
- Never interpolate untrusted input such as a PR title directly into `run`. Pass it through `env`.
- Avoid `pull_request_target` with a checkout of untrusted code.
- Set `timeout-minutes` and use `concurrency` to cancel superseded runs.

## Checklist

- Commands match what the project actually uses.
- No long-lived cloud keys when OIDC is possible.
- Third-party actions are pinned.
- Production deployment requires approval.
- Changes in pipeline behavior are stated in the report.

## Examples

```yaml
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@<full-sha> # vX.Y.Z
      - run: npm ci
      - run: npm test
```

## Anti-patterns

- `@latest` or unpinned third-party actions.
- Deploying automatically from every push to main without an approval gate.
- Workflow-wide write permissions.
- Printing environment variables for debugging.

---
Version 1.0.0. Last reviewed 2026-11-08.
