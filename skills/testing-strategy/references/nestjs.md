# NestJS

## First, detect

- Whether the project allows automated tests. If its instructions removed or prohibit them, stop and report BLOCKED.
- Runner and config: Jest in `package.json` or `jest.config.*`, or Vitest. A project without a runner needs a decision, so report it before adding one.
- HTTP adapter: `@nestjs/platform-fastify` or `@nestjs/platform-express`.
- ORM and path aliases. Aliases in `tsconfig` need a matching `moduleNameMapper` in Jest.
- Naming: usually `*.spec.ts` beside the source and `test/*.e2e-spec.ts` for HTTP tests.

## Choose the smallest test

| Target | Approach |
| --- | --- |
| Service logic | Unit test with mocked boundaries |
| Guard, pipe, interceptor, filter | Unit test with a fake `ExecutionContext` |
| Routing, validation, auth, status codes | HTTP test on a testing app |
| Queries, transactions, constraints | Integration test on a disposable database |
| Queue or cron handler | Call the handler method directly |

## Testing module

```ts
const moduleRef = await Test.createTestingModule({
  providers: [InvoiceService, { provide: PrismaService, useValue: prisma }],
}).compile();

const service = moduleRef.get(InvoiceService);
```

- Use `overrideProvider` for external clients, mail, payment gateways and queues.
- Use `moduleRef.resolve()` instead of `get()` for request-scoped or transient providers.
- Call `await app.close()` in `afterAll`. Use `--detectOpenHandles` to investigate a hanging run.

## HTTP tests

Fastify:

```ts
const app = moduleRef.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
await app.init();
await app.getHttpAdapter().getInstance().ready();

const res = await app.inject({ method: 'GET', url: '/invoices/1' });
expect(res.statusCode).toBe(404);
```

Express: use `supertest(app.getHttpServer())`.

The testing app does not run `main.ts`. Apply the same global prefix, pipes, filters and versioning through a shared setup function, or validation tests can pass or fail for the wrong reason.

## Auth

- Test 401, 403 and success for protected routes.
- `overrideGuard` removes the behavior being protected. Use it only in tests about something else.
- For tenant-scoped data, assert that a user cannot reach another tenant's record.

## Prisma

- Unit tests: give `PrismaService` a typed mock. Use `jest-mock-extended` only if the project already has it.
- For `$transaction` with a callback, have the mock call it with the mock client.
- Mocks cannot prove query behavior. Unique constraints, cascades, transactions and raw SQL need a real database.
- Use a disposable local database, apply migrations with the project's deploy command, and reset data between tests.
- Never point tests at a shared database. Stop and report BLOCKED if the target is not clearly disposable.
- Call `$disconnect` when the test app does not close it.

## Background work

- Override queue clients such as pg-boss or BullMQ so that tests do not start workers.
- Test the handler directly, including retries and duplicate delivery where the code handles them.
- Await event handlers and promises. Do not wait with timers.

## Determinism

- Inject a clock where the code depends on time.
- Fake timers can stall HTTP and database clients. Limit them to unit tests, or exclude what those clients need.

## Commands

- One file: `npx jest src/invoices/invoice.service.spec.ts`
- One test: `npx jest src/invoices/invoice.service.spec.ts -t 'returns 404'`
- E2E config, when present: `npx jest --config ./test/jest-e2e.json`
- Prefer the project's own scripts when they exist.
