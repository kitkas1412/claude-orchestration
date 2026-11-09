---
name: gsap-threejs
description: Combine GSAP with a Three.js scene on one page - tweening scene properties and uniforms, scroll-driven 3D, a single render loop, and combined teardown. Use only when the page uses both tools, in addition to gsap-web and threejs-web. Keywords - gsap, three.js, scrolltrigger, uniforms, scroll-driven 3d, render loop, matchMedia, renderOnce.
---

# GSAP with Three.js

## When to use

Only when the page uses both GSAP and Three.js. Read `<HOME>/.claude/skills/gsap-web/SKILL.md` and `<HOME>/.claude/skills/threejs-web/SKILL.md` as well (run `echo "$HOME"` with Bash first; Read and Glob may not expand `~`). This skill adds only the seams between them. `ui-implementation` and the brief still win, and it adds no disposal or cleanup list of its own: use the ones in those two skills.

## Procedure

1. GSAP writes values; the render loop reads them. GSAP can tween plain objects and Three.js properties such as `mesh.position`, `mesh.rotation` and a uniform's `{ value }` (official docs: https://gsap.com/docs/v3/GSAP/gsap.to()/ says targets may be generic objects, https://gsap.com/resources/get-started/ shows plain objects and names Three.js). A plain `state.progress` object read in the loop is also fine.
2. Exactly one loop calls `render()`. Vanilla: `renderer.setAnimationLoop(fn)`. React Three Fiber: the Canvas loop; under `frameloop="demand"` call `invalidate()` from the tween's `onUpdate`. Do not add another `requestAnimationFrame` or ticker callback that calls `render()` (GSAP's own ticker is also a rAF loop).
3. Scroll-driven scenes: keep one `progress` value from 0 to 1, written by a ScrollTrigger `onUpdate` (`self.progress`) or by a scrubbed timeline, and read by the render loop. Never render inside a scroll callback. After fonts, DOM images and Three.js assets have loaded (`LoadingManager.onLoad` tracks only Three.js loaders) call `ScrollTrigger.refresh()`, and again when the canvas or pinned area changes size.
4. Reduced motion across both: in the `gsap.matchMedia()` branch for `(prefers-reduced-motion: no-preference)`, start the loop inside the callback (`setAnimationLoop(fn)`) and return a cleanup that calls `setAnimationLoop(null)`. In the reduce branch call the shared `renderOnce()` from `threejs-web` so the canvas is never blank, and set the scene to its final pose. No scroll-jacking or autoplaying camera moves. Per `gsap-core`, matchMedia reverts its animations when a query stops matching and runs the cleanup you return, so a live setting change is handled; test it. When GSAP drives the scene, `gsap.matchMedia()` is the only start/stop controller: omit `threejs-web`'s `sync` change listener, but keep its `renderOnce()` calls after resize, load and context restore. In React Three Fiber, set the Canvas `frameloop="demand"` under reduced motion (`'always'` renders every frame); it renders only after React changes or `invalidate()`, so skipping `invalidate()` in the reduce branch leaves a static frame (`threejs-react-three-fiber` documents `frameloop` and `invalidate()`).
5. Idle pausing: when the canvas leaves the viewport, stop the loop and pause or kill the GSAP animations on the same signal; on return restart both unless reduced motion is active.
6. Combined teardown, in this order: revert the GSAP context or `matchMedia()` (kills tweens and ScrollTriggers, so nothing writes to the scene any more), then stop the loop (`setAnimationLoop(null)`), then run the Three.js disposal from `threejs-web`, then `renderer.dispose()`. For vanilla Three.js in React, put both in the same effect cleanup in that order. In React Three Fiber, fiber owns the renderer: revert the GSAP context in the effect cleanup and let fiber dispose what it created.
7. Run the project's build, type-check and lint. Report that visual quality and frame rate were not verified unless `browser-verification` was run; how motion feels and real-phone performance remain a human check.

## Checklist

- One render loop; GSAP never calls `render()`.
- Scroll progress is a single value read by the loop; refresh runs after all late layout.
- The reduce branch renders a static frame via `renderOnce()`; the motion branch starts and stops the loop.
- Teardown order: GSAP first, then the loop, then Three.js disposal.
- Human checks: scroll the full page up and down, resize while pinned, reduced motion toggled live, leave and re-enter the route, device performance trace.

## Examples

```js
const state = { progress: 0 };
const mm = gsap.matchMedia();
mm.add('(prefers-reduced-motion: no-preference)', () => {
  ScrollTrigger.create({ trigger: '.scene', start: 'top top', end: '+=2000', pin: true,
    onUpdate: (self) => { state.progress = self.progress; } });
  renderer.setAnimationLoop(() => {
    material.uniforms.uProgress.value = state.progress;
    renderer.render(scene, camera);
  });
  return () => renderer.setAnimationLoop(null);
});
mm.add('(prefers-reduced-motion: reduce)', () => { material.uniforms.uProgress.value = 1; renderOnce(); });
```

## Anti-patterns

- A GSAP ticker and a `setAnimationLoop` both rendering, or `render()` inside a scroll handler.
- Starting the loop outside the matchMedia callback, so the reduce branch still animates.
- Disposing Three.js objects while tweens or ScrollTriggers can still write to them.
- Refreshing ScrollTrigger before assets and fonts settle.

Credit: ideas from the MIT-licensed greensock/gsap-skills and CloudAI-X/threejs-skills, written in original wording.

---
Version 1.0.0. Last reviewed 2026-11-09.
