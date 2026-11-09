---
name: css-motion
description: Add motion with plain CSS and no animation library - transitions, keyframes, entry animations, view transitions, scroll-driven animation - with fallbacks, reduced motion and cheap properties. Use when the tool choice is plain CSS, before reaching for GSAP or Three.js. Keywords - css animation, transition, keyframes, view transition, scroll-driven, animation-timeline, starting-style, prefers-reduced-motion, will-change.
---

# CSS motion

## When to use

Plain CSS is the lightest option and the default choice for transitions, hover and focus effects, entry and exit animation, page-level view transitions and scroll-linked effects that do not need sequencing or runtime control. If the brief needs timelines, complex sequencing or 3D, say so and move to `gsap-web` or `threejs-web`. `ui-implementation` always wins on tokens, states and accessibility: use the project's motion tokens (durations, easings) and its reduced-motion override.

## Procedure

1. Find the project's browser targets (browserslist, `package.json`, docs, or the brief). Compare each feature below against them before relying on it. If the targets are unknown, treat Newly available and not Baseline features as enhancements only.
2. Write base styles that already look right with no animation. Add the enhancement on top, inside `@supports` where a query exists. Do not invent a detection form for a feature that has none.
3. Reduced motion: wrap non-essential motion in `@media (prefers-reduced-motion: no-preference)`, or override it in a `reduce` block. MDN: `reduce` means minimize non-essential motion, and scaling or panning large objects can cause vestibular discomfort. Replace rather than only remove, for example a scale pulse becomes an opacity dissolve. Chrome's View Transitions article: reduced motion does not mean no motion; prefer a subtler animation that still shows how elements relate. Content must never depend on the motion.
4. Animate `transform` and `opacity` only (web.dev names only these two). `will-change` is a last resort for an existing problem: set it shortly before the change and remove it after, preferably toggled from JS; not on many elements, large sections or `body`; not inside `@keyframes`; opacity or transform values create a stacking context up front.
5. Fallbacks:
   - Same-document view transition: `if (!document.startViewTransition) { updateDOM(); return; }`.
   - Cross-document view transition (`@view-transition`): unsupporting browsers ignore the at-rule and navigate normally, so plain navigation is the fallback. No detection form is confirmed.
   - Scroll-driven animation: the static end state is the default (elements visible) and the animation sits inside `@supports`. MDN's module page uses `@supports not (scroll-timeline: --main-timeline)`; `(animation-timeline: scroll())` follows the generic syntax but I did not see it quoted.
   - `allow-discrete`: write the `transition` shorthand twice, first without and then with `allow-discrete` (MDN).
   - `@starting-style` missing: the element just appears, without the entry transition.
6. Run the project's build, type-check and lint. Report that visual quality and smoothness were not verified.

## Support, as checked 2026-11-09

Source: MDN browser-compat-data and web-features, via a summarizing fetch (confidence medium). Re-check before relying on it; it goes stale.

| Feature | Chrome/Edge | Safari | Firefox | Baseline |
| --- | --- | --- | --- | --- |
| `linear()` easing | 113 | 17.2 | 112 | Widely available |
| `prefers-reduced-motion` | | | | Widely available |
| `@starting-style` | 117 | 17.5 | 129 | Newly available 2024-08-06 |
| `transition-behavior: allow-discrete` | 117 | 17.4 | 129 | Newly available 2024-08-06 per web-features; MDN says "Limited availability", so check |
| Same-document View Transitions | 111 | 18 | 144 | Newly available 2025-10-14 |
| Scroll-driven animations (`animation-timeline`, `scroll()`, `view()`) | 115 | 26 | 159 (seen only in data files, not release notes) | Newly available 2026-10-27 |
| Cross-document View Transitions (`@view-transition`) | 126 | 18.2 | unsupported | Not Baseline |
| `interpolate-size`, `calc-size()` | 129 only | no | no | Experimental, not Baseline |

## Checklist

- Project browser targets compared with the table; unsupported features degrade to a complete static page.
- Base styles first, enhancement in `@supports` or behind the feature's own fallback.
- Reduced motion replaces large motion with a subtler effect.
- Only `transform` and `opacity` animate; no blanket `will-change`.
- No new library added for what CSS does.
- Human checks: reduced motion on, an older target browser, keyboard focus during transitions, a mid-range phone.

## Examples

```css
.card { opacity: 1; transition: opacity 150ms var(--ease-out); }
@starting-style { .card { opacity: 0; } }
@media (prefers-reduced-motion: no-preference) {
  .card { transition: opacity 200ms var(--ease-out), transform 200ms var(--ease-out); }
  @starting-style { .card { opacity: 0; transform: translateY(8px); } }
}
```

## Anti-patterns

- Relying on a Newly available or experimental feature without checking the project's targets.
- Making content visible only through a scroll-driven or entry animation.
- Putting `will-change` on many elements or inside `@keyframes`.
- Removing all motion for reduced motion where a subtle replacement would keep meaning.
- Adding GSAP for a transition CSS handles.
- Claiming smoothness without a device check.

Sources: https://web.dev/articles/animations-guide, https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/will-change, https://developer.chrome.com/docs/web-platform/view-transitions/same-document, github.com/mdn/browser-compat-data, github.com/web-platform-dx/web-features. Original wording.

---
Version 1.0.0. Last reviewed 2026-11-09.
