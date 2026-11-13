---
name: api-design
description: Design consistent, evolvable HTTP API contracts. Use when defining or changing endpoints, OpenAPI specs, pagination, filtering, error formats, versioning, or assessing breaking changes. Keywords - REST, OpenAPI, Swagger, DTO, cursor pagination, idempotency, status codes.
---

# API design

## When to use

Use when an API contract is created or changed. Existing project conventions take priority over this skill.

## Procedure

1. Record the current conventions: path style, casing, error body, authentication, pagination.
2. Model resources and operations from the consumer's point of view.
3. Define request, response and error shapes, with examples.
4. Decide pagination, filtering and sorting for every collection.
5. Classify the change as additive or breaking.
6. For breaking changes, provide versioning or a deprecation and migration path.

## Defaults when the project has none

- Pagination: cursor-based for large or changing data; offset is acceptable for small admin lists. Enforce a maximum page size.
- Errors: one body shape with a stable machine-readable code, a message, and field details. RFC 9457 is a good default.
- Status codes: 200, 201, 204; 400 or 422 for validation; 401 unauthenticated; 403 forbidden; 404; 409 conflict; 429 rate limited.
- Idempotency: accept an idempotency key on non-idempotent operations with real-world effects, such as payments.

## Breaking changes

These break consumers: removing or renaming a field, changing a type or format, adding a required input, tightening validation, or changing a default or an error code.

## Checklist

- Every endpoint has defined success and error responses.
- Authorization expectations are stated per operation.
- Collections have a bounded page size.
- Examples validate against the schema.
- The compatibility impact is explicit.

## Examples

`GET /users?limit=20&cursor=abc` returns `{ "items": [...], "nextCursor": "def" }`, with `nextCursor` null on the last page.

## Anti-patterns

- Exposing database column names or internal ids by accident.
- Returning 200 with an error in the body.
- Unbounded list endpoints.
- A different error shape per endpoint.

---
Version 1.0.0. Last reviewed 2026-11-08.
