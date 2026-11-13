---
name: db-migrations-safe
description: Plan and write database migrations that avoid downtime and data loss. Use for schema changes, column renames or type changes, new indexes or constraints, backfills, or reviewing a migration. Keywords - migration, expand contract, zero downtime, backfill, lock, Prisma, Flyway, Alembic, PostgreSQL.
---

# Safe database migrations

## When to use

Use whenever a schema or a large data set changes. Run against local, dev or test databases named in the brief only.

## Procedure

1. Identify the migration tool and naming convention. Check the current drift between migrations and schema before reading a diff as yours.
2. Classify each statement as additive, backward-compatible, or destructive.
3. Use expand and contract for anything not additive:
   - Expand: add the new structure.
   - Write to both old and new.
   - Backfill in batches.
   - Switch reads.
   - Contract in a later release.
4. For each statement, state the lock taken, the table size assumption, and the expected duration.
5. Provide a rollback path, and say explicitly where data cannot be restored.
6. Apply locally, check the result, and exercise the rollback when the tool supports it.

## PostgreSQL notes

- Use `CREATE INDEX CONCURRENTLY` on large tables. It cannot run inside a transaction, so check how the tool wraps migrations.
- Add foreign keys and check constraints as `NOT VALID`, then validate separately.
- Set a `lock_timeout` for statements that take strong locks.
- Backfill in small batches, committing between them.

## Checklist

- Old application code still works during and after the migration.
- Destructive statements are listed under OPEN before being applied, even locally.
- Backfills are idempotent and resumable.
- No production or staging connection was used.
- Connection strings were not printed.

## Examples

Renaming a column safely: add the new column, write to both, backfill, read from the new column, then remove the old column in a later release.

## Anti-patterns

- Renaming or narrowing a column in one step on a live table.
- Combining schema change and large backfill in one transaction.
- Editing a migration that was already applied elsewhere.
- Resetting a shared database to resolve drift.

---
Version 1.0.0. Last reviewed 2026-11-08.
