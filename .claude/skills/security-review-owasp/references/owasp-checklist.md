# OWASP-based checks

| Category | Check |
| --- | --- |
| Broken access control | Object-level and tenant checks, admin routes, mass assignment, IDOR |
| Cryptographic failures | Password hashing, TLS, weak algorithms, predictable tokens |
| Injection | Raw SQL, NoSQL operators, shell commands, templates, LDAP |
| Insecure design | Missing rate limits, abuse paths, workflow step skipping |
| Misconfiguration | Permissive CORS, debug mode, default credentials, missing security headers |
| Vulnerable components | Audit tool results, unmaintained packages, unpinned CI actions |
| Authentication failures | Session fixation, JWT algorithm and expiry checks, reset token handling |
| Integrity failures | Unsafe deserialization, unsigned updates, CI script injection |
| Logging failures | Missing audit trail, secrets or personal data in logs |
| SSRF | User-controlled URLs, redirects, access to metadata and internal hosts |

Web-specific: stored and reflected XSS, CSRF on cookie-authenticated routes, open redirects, file upload type and path handling, path traversal.

Payments and money: idempotency, webhook signature verification, amounts computed on the server, race conditions in balance updates.
