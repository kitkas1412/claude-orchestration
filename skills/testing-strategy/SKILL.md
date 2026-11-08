---
name: testing-strategy
description: Choose what to test and at which level, and write deterministic automated tests in the project's existing framework. Use when writing unit, integration, e2e or regression tests, reproducing a bug as a failing test, or judging test coverage. Keywords - jest, vitest, nestjs, pytest, swift testing, junit, mockito, spring boot test, mocks, fixtures, flaky tests.
---

# Testing strategy

## When to use

Use when adding or changing automated tests. Stack details live in references, so read only the one that matches the project:

- JavaScript or TypeScript: `~/.claude/skills/testing-strategy/references/jest.md`
- NestJS: `~/.claude/skills/testing-strategy/references/nestjs.md`
- Python: `~/.claude/skills/testing-strategy/references/pytest.md`
- Swift: `~/.claude/skills/testing-strategy/references/swift-testing.md`
- Java: `~/.claude/skills/testing-strategy/references/java.md`

Follow any required reading that the matching reference names. For other stacks, follow the patterns already in the repository.

## Procedure

1. Check the project's instructions. If they prohibit or removed automated tests, stop and report BLOCKED. Otherwise find the existing framework, layout, naming, fixtures and test command, and copy local patterns over general advice.
2. List the behaviors from the acceptance criteria. Add edge cases and error paths for each.
3. Pick the lowest level that can catch the failure:
   - Unit: pure logic, branching, validation.
   - Integration: database queries, HTTP handlers, framework wiring.
   - E2E: a few critical user journeys only.
4. For a bug, write the failing test first and confirm that it fails for the expected reason.
5. Control sources of nondeterminism: clock, randomness, network, ordering, shared state.
6. Run the new tests, then the surrounding suite, and report real counts.

## Checklist

- Each test name states a behavior and its condition.
- Each test would fail if the behavior broke.
- Tests are independent and can run in any order.
- Mocks exist only at boundaries the project does not own or cannot run cheaply.
- No test depends on real services, real time, or secrets.
- No existing test was weakened or deleted to get a pass.

## Examples

Good name: `returns 404 when the user belongs to another tenant`.

Weak name: `test getUser 2`.

Regression test: reproduce the reported input exactly, assert the corrected behavior, and reference the issue only if the project does.

## Anti-patterns

- Asserting that a mock was called instead of asserting the outcome.
- Snapshots of large structures that nobody reviews.
- Sleeping to wait for async work.
- Retrying flaky tests instead of fixing the cause.
- Duplicating implementation logic inside the assertion.

---
Version 1.0.0. Last reviewed 2026-11-08.
