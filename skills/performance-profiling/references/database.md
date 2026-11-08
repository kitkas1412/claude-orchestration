# Database profiling

- Run `EXPLAIN` first. Use `EXPLAIN ANALYZE` only on local, dev or test databases, because it executes the statement.
- In PostgreSQL, look for sequential scans on large tables, row estimates far from actual, nested loops over many rows, and sorts spilling to disk.
- Use `pg_stat_statements` where available to rank queries by total time.
- N+1: count queries per request through ORM logging.
- For Prisma, enable query logging locally, and check whether `include` is producing many or heavy queries.
- Check lock waits and connection pool saturation when latency rises without a slower plan.
- Test with realistic data volume. A plan on a small table says little about production.
- Every new index has a write cost, so state the expected read benefit.
