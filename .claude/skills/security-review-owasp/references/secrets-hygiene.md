# Secrets hygiene

- Never print, copy or log a secret value. Report file, line and at most the first 4 characters.
- Do not open `.env` files or key files to confirm a finding. Use pattern scanners that mask output, such as gitleaks with redaction.
- Check tracked configuration, CI files, Dockerfiles, build arguments, image layers, test fixtures and logging statements.
- Secrets in git history stay exposed after deletion. The fix is rotation, followed by history cleanup if needed.
- Applications read secrets from environment variables or a secret manager. CI references them by name.
- Keep `.env.example` with placeholders only, and make sure real env files are ignored by git.
- Scope tokens to the minimum permissions and shortest practical lifetime.
