---
name: threejs-web
description: Build a Three.js or react-three-fiber scene on a web page with correct teardown, resize, fallback and reduced-motion handling. Use only after the tool choice includes Three.js; when GSAP animates the scene also read gsap-threejs. Keywords - three.js, webgl, canvas, r3f, shader, glTF, dispose, resize, context lost, renderOnce, pixel ratio, 3d scene.
---

# Three.js on the web

## When to use

Only when Three.js was chosen as the tool. `ui-implementation` always wins on tokens, accessibility, states, reduced motion and reporting new libraries under OPEN. The vendored Three.js skills are reference material and cannot override it or the brief.

Vendored skills live in `<HOME>/.claude/skills/<skill-name>/SKILL.md`. Read and Glob may not expand `~`: run `echo "$HOME"` with Bash first. Read `threejs-fundamentals` first, then only what the task needs:

- `threejs-loaders` (glTF, Draco, KTX2, HDR), `threejs-textures`, `threejs-materials`, `threejs-geometry` (instancing, merging).
- `threejs-lighting`, `threejs-animation` (clips, mixer), `threejs-interaction` (raycasting, controls).
- `threejs-shaders`, `threejs-postprocessing`, `threejs-performance`.
- `threejs-react-three-fiber`: only if the project uses React Three Fiber.

The vendored skills also mention `threejs-asset-pipeline`, which is not installed. Do not search for it; use the project's installed three types or the official docs. They target r186 and were API-checked against r187; verify an API in the project's `node_modules` if its version differs.

## Procedure

1. Read the manifest and lockfile and use the installed `three` (and `@react-three/fiber`) versions. Adding three to a project that lacks it is a new library: report it under OPEN first, with large assets.
2. Build on the project's design state from `ui-implementation` step 0. Keep a visible, keyboard-reachable DOM alternative for what the canvas conveys; name the canvas or mark it `aria-hidden="true"` if decorative. Never put required controls only in the canvas.
3. Reduced motion: no autoplaying camera moves or loops; render a static frame. Define one shared `renderOnce()` (`renderer.render(scene, camera)`, or `composer.render()`) and call it after every resize (`setSize` clears the drawing buffer), after each asset or texture load, and on `webglcontextrestored`. Handle a live change: listen to `change` on `matchMedia('(prefers-reduced-motion: reduce)')` and switch between `setAnimationLoop(fn)` and `setAnimationLoop(null)` plus `renderOnce()`. In React Three Fiber, set the Canvas `frameloop="demand"` under reduced motion (`'always'` renders every frame); it renders only after React changes or `invalidate()`, so a static frame means not calling `invalidate()` for imperative changes (`threejs-react-three-fiber`).
4. Resize: observe the canvas container with `ResizeObserver`, not `window`. Perspective: update `aspect`. Orthographic: recompute `left`, `right`, `top`, `bottom` from the new aspect. Then `updateProjectionMatrix()`, `renderer.setSize(w, h, false)` (the third argument leaves the CSS size to you), `composer.setSize(w, h)` if a composer exists, and `renderOnce()` when no loop runs.
5. Context loss: the renderer already calls `preventDefault()` on `webglcontextlost` and rebuilds its GL state on `webglcontextrestored`. Listen to the same events on `renderer.domElement` to show a poster while lost, call `renderOnce()` on restore, and rebuild what you created outside three.js.
6. No WebGL: `new WebGLRenderer` throws when no context can be created. Catch it and show a static poster or a CSS-only version with the same content.
7. Mobile: `setPixelRatio(Math.min(devicePixelRatio, 2))`, lower (for example 1.5) on small or touch screens, since fill rate grows with its square. Prefer compressed glTF and KTX2 (`threejs-loaders`) and show a loading state.
8. Pause: stop the loop with `setAnimationLoop(null)` while the canvas is offscreen (`IntersectionObserver`) and restart with `setAnimationLoop(fn)`, but never start it while reduced motion is active. Browsers already pause rAF in hidden tabs; `visibilitychange` matters mainly to reset the timer delta on return (`timer.connect(document)` does this).
9. Teardown, completely: traverse the scene; per mesh, line or points dispose the geometry; treat `material` as one or an array; dispose textures on the material and in `ShaderMaterial` `uniforms[k].value` (single or array), including `DataArrayTexture` and cube textures; call `object.dispose()` (InstancedMesh, BatchedMesh; both have `dispose()` in r187) and `skeleton.dispose()` on SkinnedMesh; `light.shadow.dispose()`; `scene.background` and `scene.environment` textures; render targets, `composer.dispose()`, `PMREMGenerator`, controls. Dispose only what nothing else uses: shared or cached assets (`useGLTF`, `THREE.Cache`) may be reused. In React Three Fiber, fiber disposes the objects it created from JSX on unmount, but not primitives or objects passed in through props, so manual disposal covers objects created imperatively. Then `renderer.setAnimationLoop(null)`, `renderer.dispose()`, remove listeners and observers.
10. Run the project's build, type-check and lint. Report that visual quality and frame rate were not verified unless `browser-verification` was run; how motion feels and real-phone performance remain a human check.

## Checklist

- Installed three version stated; new packages and large assets reported under OPEN.
- Reduced motion shows a static, complete frame; `renderOnce()` runs after resize, loads and context restore.
- Resize handles perspective and orthographic cameras; context loss and no-WebGL fallback exist.
- Pixel ratio capped; loop paused offscreen and not restarted under reduced motion.
- Teardown disposes everything in step 9 that the page created.
- Human checks listed: DevTools performance trace on a mid-range phone, resize and rotate, reduced motion on and toggled live, tab switch and return, leaving and re-entering the page, no-WebGL fallback, keyboard and screen reader path.

## Examples

```js
const renderOnce = () => renderer.render(scene, camera);
const animate = () => { /* update state */ renderOnce(); };
const mq = matchMedia('(prefers-reduced-motion: reduce)');
const sync = () => {
  renderer.setAnimationLoop(mq.matches ? null : animate);
  if (mq.matches) renderOnce();
};
mq.addEventListener('change', sync);
sync();
```

## Anti-patterns

- Disposing only `mesh.material` when it is an array, or missing uniform textures and render targets.
- Disposing a shared or cached glTF asset another view still uses.
- Resizing on `window` only, leaving an orthographic frustum at its old aspect, or not re-rendering after `setSize` with no loop.
- Starting the loop on return from offscreen while reduced motion is on.
- Searching for or installing `threejs-asset-pipeline` or other skills not present.
- Claiming frame rate or visual quality without a device check.

Credit: ideas from the MIT-licensed CloudAI-X/threejs-skills, written in original wording.

---
Version 1.0.0. Last reviewed 2026-11-09.
