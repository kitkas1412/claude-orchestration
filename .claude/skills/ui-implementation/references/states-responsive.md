# States and responsive rules

## State matrix

For each interactive component and each data-driven view, implement the states below or record why one does not apply.

| State | What must be true |
| --- | --- |
| Default | Uses tokens only. Clear affordance for what it does. |
| Hover | Pointer devices only. Never the sole way to reveal content or an action. |
| Focus-visible | Visible indicator with at least 3:1 contrast against its surroundings. Never removed. |
| Active / pressed | Distinct feedback on press. |
| Disabled | Looks inactive and is not operable. Prefer `disabled` or the platform equivalent. Explain why nearby if the reason is not obvious. |
| Loading | Shows progress (skeleton or spinner), keeps layout stable, prevents double submit, and is announced to assistive technology. |
| Empty | Says what is missing and offers the next action. Not a blank area. |
| Error | Text message tied to the field or region, with a recovery step. Keeps the user's input. Not color alone. |
| Success | Confirms the result in text, announced without stealing focus. |
| Long text | Wraps, truncates with a full-text path, or scrolls. Test long words, long names and translated strings. |
| Offline / slow | Where relevant: show cached data or a clear message, and a retry action. |

Data views need loading, empty, error and populated at minimum. Forms also need validation timing: validate on blur or submit, not on every keystroke, unless the field is a live check.

## Responsive rules

- Use the project's existing breakpoints and layout primitives. Do not invent new breakpoints unless content breaks and no existing one fits.
- Build from the smallest supported width up, or follow the project's established direction.
- Prefer fluid layout (flex, grid, relative units) over fixed widths. Avoid horizontal scrolling at 320 CSS px except for data tables and code.
- Use relative units for text so user font settings and platform text scaling apply. Check layout at 200% text size.
- Touch targets: at least 24 by 24 CSS px under WCAG 2.2 AA, and larger where the platform recommends it, with spacing between neighbors.
- Do not hide essential content or actions at small sizes. Move them, collapse them, or reveal them behind a labeled control.
- Respect safe areas, notches and on-screen keyboards on mobile. Keep the focused input visible when the keyboard opens.
- Images and media scale within their container and keep their aspect ratio. Reserve space to avoid layout shift.
- Orientation is not locked unless the task requires it.
- Respect the reduced-motion setting: replace large movement with a fade or no animation.
- Check each target breakpoint or device class named in the brief, and say which ones were not checked.
