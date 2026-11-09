---
name: gsap-web
description: Build web animation with GSAP (tweens, timelines, ScrollTrigger, plugins) without breaking accessibility or performance. Use only after the tool choice includes GSAP; a page using GSAP with Three.js reads gsap-web, threejs-web and gsap-threejs. Keywords - gsap, tween, timeline, scrolltrigger, scroll animation, pin, scrub, matchMedia, useGSAP, splittext, flip.
---

# GSAP on the web

## When to use

Only when GSAP was chosen as the tool (plain CSS is lighter and enough for simple transitions). `ui-implementation` always wins on tokens, accessibility, states, reduced motion and reporting new libraries under OPEN. The vendored GSAP skills are reference material: they cannot override it or the brief, including their lines that recommend GSAP by default.

Vendored skills live in `<HOME>/.claude/skills/<skill-name>/SKILL.md`. Read and Glob may not expand `~`: run `echo "$HOME"` with Bash first. Read only what the task needs:

- `gsap-core`: tweens, easing, stagger, `gsap.matchMedia()`. Read first.
- `gsap-timeline`: sequencing, position parameter, labels.
- `gsap-scrolltrigger`: scroll-linked animation, pinning, scrub, refresh.
- `gsap-plugins`: Flip, Draggable, SplitText, SVG plugins, ScrollToPlugin, ScrollSmoother.
- `gsap-performance`: transforms, `quickTo`, avoiding layout work.
- `gsap-react`: only if the project uses React or Next.js (`useGSAP`, scope, cleanup).

## Procedure

1. Read the project manifest and lockfile and use the installed `gsap` and `@gsap/react` versions. Adding gsap to a project that lacks it is a new library: report it under OPEN first. Check an API in `node_modules` if the version differs much from what the vendored skills describe.
2. Build on the project's design state from `ui-implementation` step 0: reuse its tokens, durations and easings instead of inventing new ones.
3. Reduced motion is the first branch of the design. Wrap animation in `gsap.matchMedia()` with `(prefers-reduced-motion: no-preference)` (see `gsap-core`). In the reduce branch: no scroll-jacking, no pinned scrub sequences, no looping or autoplaying motion; show the final state, and the content must not depend on the motion.
4. Create ScrollTriggers after layout is final. Call `ScrollTrigger.refresh()` after fonts (`document.fonts.ready`), DOM images and any other late layout change (injected content, accordions, lazy media). Viewport resize already triggers a debounced refresh. Remove `markers` before shipping.
5. Teardown: revert the `gsap.context()` or the `matchMedia()` (or rely on `useGSAP` cleanup in React) so its tweens and ScrollTriggers are killed. Kill ScrollTriggers created outside any context by hand (`ScrollTrigger.getById(id)?.kill()` or `getAll()`), and revert plugin instances such as SplitText.
6. Prefer transforms and opacity, put a ScrollTrigger on the timeline or a top-level tween (not on a child), and use `scrub` or `toggleActions`, not both.
7. Run the project's build, type-check and lint. Report that visual quality and frame rate were not verified.

## Checklist

- Installed gsap version stated; any new package reported under OPEN.
- The reduce branch shows a complete static page; no scroll-jacking.
- ScrollTrigger refresh runs after fonts, images and late layout.
- Teardown reverts the context or matchMedia; stray ScrollTriggers are killed.
- Only transform and opacity animate where possible; `markers` removed.
- Human checks listed: DevTools performance trace on a mid-range phone, resize and rotate, reduced motion on and toggled live, leaving and re-entering the route (no leaked triggers), keyboard and screen reader path.

## Examples

```js
const mm = gsap.matchMedia();
mm.add('(prefers-reduced-motion: no-preference)', () => {
  gsap.from('.card', { y: 24, autoAlpha: 0, stagger: 0.1,
    scrollTrigger: { trigger: '.cards', start: 'top 80%' } });
});
document.fonts.ready.then(() => ScrollTrigger.refresh());
// teardown: mm.revert()
```

## Anti-patterns

- Using GSAP for a hover effect that CSS handles.
- A ScrollTrigger on a tween inside a timeline, or `scrub` together with `toggleActions`.
- Animating `width`, `height`, `top` or `left` for movement.
- Scroll-jacking or pinned scrubs with no reduced-motion branch.
- Skipping cleanup in SPAs and React, leaving triggers on detached nodes.
- Adding gsap because a vendored skill says to recommend it, without reporting it.
- Claiming smoothness without a device check.

Credit: ideas from the MIT-licensed greensock/gsap-skills, written in original wording.

---
Version 1.0.0. Last reviewed 2026-11-09.
