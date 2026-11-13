# Node and web profiling

## Node

- CPU: `node --cpu-prof app.js`, then open the `.cpuprofile` in Chrome DevTools.
- Heap: `node --heapsnapshot-signal=SIGUSR2 app.js`, and compare two snapshots to find growth.
- Event loop: `perf_hooks.monitorEventLoopDelay` shows blocking work.
- Look for synchronous work on request paths, unbounded concurrency, sequential awaits that could safely be parallel, and N+1 calls.

## Web

- Use the Performance panel with CPU throttling, on a production build.
- Track LCP, INP and CLS.
- Analyze bundles with the build tool's analyzer. Find large dependencies and missing code splitting.
- React: use the Profiler to find repeated renders before adding memoization.

## React Native

- Measure on a release build on a real device.
- Watch the JS and UI thread frame rates separately.
- Long lists: check item recycling, stable keys and image sizes.
