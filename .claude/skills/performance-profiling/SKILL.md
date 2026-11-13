---
name: performance-profiling
description: Measure, locate and explain performance problems with evidence. Use for latency or p95 regressions, slow endpoints and queries, CPU or memory hotspots, bundle size, startup time, or rendering jank. Keywords - profiler, flamegraph, EXPLAIN, benchmark, load, N+1, memory leak.
---

# Performance profiling

## When to use

Use when something is slow or resource-hungry. Read only the reference you need:

- Node and web: `<REPO_ROOT>/.claude/skills/performance-profiling/references/node-and-web.md`
- Databases: `<REPO_ROOT>/.claude/skills/performance-profiling/references/database.md`

## Procedure

1. Define the metric, the target and the workload: for example, p95 of one endpoint under a stated request mix.
2. Establish a reproducible baseline. Record the command, environment and numbers.
3. For a regression, bound it in time first: compare deploys, commits, dependency versions, config, and data volume around the onset.
4. Break total time into parts: network, application, database, external calls, queueing.
5. Form ranked hypotheses and test each with a measurement.
6. Change one thing at a time, and re-measure with the same method.
7. State what remains unmeasured, especially when production data was unavailable.

## Checklist

- Percentiles are reported, not only averages.
- Before and after use the same workload and environment.
- The bottleneck is backed by a measurement.
- Throwaway benchmarks were removed.
- No load test ran against shared or production systems.

## Examples

Regression report: `p95 of GET /users rose from 120 ms to 260 ms at deploy X. Query time rose by 130 ms because commit Y removed the index on tenant_id. Evidence: EXPLAIN before and after.`

## Anti-patterns

- Optimizing on intuition.
- Benchmarking a debug build, or a single run.
- Averaging away tail latency.
- Keeping a micro-optimization with no measurable gain.
- Adding a cache before understanding why the work is slow.

---
Version 1.0.0. Last reviewed 2026-11-08.
