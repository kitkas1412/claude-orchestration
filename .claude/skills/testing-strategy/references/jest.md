# Jest and Vitest

- Confirm the runner from `package.json` scripts and config. Do not mix Jest and Vitest APIs.
- Prefer `describe` for the unit under test and `it` for one behavior.
- Reset state between tests: `jest.clearAllMocks()` or `vi.clearAllMocks()`, and restore spies.
- Control time with fake timers, and restore real timers after each test.
- For NestJS, also read `nestjs.md` in this folder.
- For HTTP integration tests, use the project's existing client such as supertest or Fastify `inject`.
- For React Native and React, query by role or visible text through Testing Library. Avoid asserting on internal state.
- Await every promise. Use `expect(...).rejects` for failures, so a missing rejection fails the test.
- Run one file first, such as `npx jest path/to/file.spec.ts`, and then use the project's full test script.
