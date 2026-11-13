---
name: security-review-owasp
description: Audit code and configuration for exploitable security flaws using OWASP categories. Use for security reviews, auth or authorization changes, payments, personal data, secrets handling, dependency risk, or pre-release audits. Keywords - injection, XSS, CSRF, SSRF, IDOR, JWT, CORS, OWASP, hardcoded secrets.
---

# Security review (OWASP)

## When to use

Use for any security review. Read only what the scope needs:

- Category checks: `<REPO_ROOT>/.claude/skills/security-review-owasp/references/owasp-checklist.md`
- Secrets: `<REPO_ROOT>/.claude/skills/security-review-owasp/references/secrets-hygiene.md`

## Procedure

1. Map entry points, trust boundaries, identities, data stores and outbound calls within the scope.
2. Follow untrusted input from each entry point to each sensitive sink.
3. For every data access, confirm that the caller is authorized for that specific object and tenant.
4. Work through the relevant categories in the checklist.
5. Run the ecosystem's dependency audit if available, and separate reachable issues from theoretical ones.
6. Report only what file:line evidence supports, with a realistic exploit path.

## Severity

- Critical: remote compromise, authentication bypass, mass data exposure.
- High: cross-tenant or privilege escalation, exposed live secret.
- Medium: exploitable only with preconditions.
- Low: hardening with limited direct impact.

## Checklist

- Every endpoint in scope has both authentication and object-level authorization reviewed.
- Each finding has evidence, an exploit path and a fix.
- Secret values are never printed. Show file, line and at most the first 4 characters.
- Areas not reviewed are listed.

## Examples

Finding: `High, broken access control, src/invoices/invoices.service.ts:42. The query filters by invoice id only, so any signed-in user can read another tenant's invoice by changing the id. Fix: add tenantId from the session to the query.`

## Anti-patterns

- Reporting scanner output without checking reachability.
- Treating authentication as proof of authorization.
- Trusting client-supplied roles, tenant ids or prices.
- Attempting an exploit against a live system.

---
Version 1.0.0. Last reviewed 2026-11-08.
