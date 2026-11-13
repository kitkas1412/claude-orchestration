---
name: ui-implementation
description: Build or change UI that fits the project's design system and works for everyone. Use when building or changing UI components, layouts, states, responsive behavior, tokens, or establishing a design system. Keywords - component, layout, tokens, theme, states, responsive, accessibility, focus, design system.
---

# UI implementation

## When to use

Use for any frontend or mobile UI work. Read only the reference you need. The `references/` folder sits beside this SKILL.md, so use that location if the install path differs. Read and Glob may not expand `~`: run `echo "$HOME"` with Bash and read `<REPO_ROOT>/.claude/skills/ui-implementation/references/<file>`.

- Accessibility (WCAG 2.2 AA): `<REPO_ROOT>/.claude/skills/ui-implementation/references/a11y.md`
- States and responsive rules: `<REPO_ROOT>/.claude/skills/ui-implementation/references/states-responsive.md`
- No design system exists: `<REPO_ROOT>/.claude/skills/ui-implementation/references/design-system-bootstrap.md`

This skill is stack-neutral. For Apple or React Native UI, follow the platform skill supplied in the brief as well.

## Procedure

0. Detect the project's design state first (theme files, token files, CSS variables, Tailwind config, component library, shared styles):
   - EXISTING (tokens, theme or component library): reuse it. Add no new colors, spacing values or fonts. Map every value to an existing token.
   - PARTIAL (values scattered, no tokens): collect the values already in use into tokens, keep the current appearance, and normalize only what the task touches. Do not restyle the app. Create new token, theme or doc files only if the brief allows them; otherwise return the planned file list under OPEN.
   - NONE: read the bootstrap reference and do the bootstrap first, then build the feature on it. If the brief gives no design direction (brand, tone, light or dark), stop, do not invent one, and return BLOCKED or PARTIAL with a proposal under OPEN.
1. Start from semantic structure. Use native elements (button, a, input, label, dialog, list, heading) before any ARIA.
2. Implement every real state: default, hover, focus-visible, active, disabled, loading, empty, error, success. Include long text.
3. Make it responsive with the project's own breakpoints. Do not add new ones without a reason.
4. Check keyboard operation and focus order, reduced motion, and text scaling.
5. Run the project's lint, type-check and tests.
6. Report that visual rendering was not verified unless a preview tool was used, and list what a human should look at.

## Checklist

- Step 0 result is stated (EXISTING, PARTIAL or NONE).
- No raw color, spacing or font values outside the token layer.
- Each interactive element works by keyboard and shows a visible focus indicator.
- Every state in step 2 exists or is explicitly not applicable.
- Errors and status are not conveyed by color alone.
- Motion respects the reduced-motion setting.
- No new UI library or font was added without being reported under OPEN.

## Examples

Before: a clickable div with a hardcoded color and one state.

```html
<div class="btn" style="background:#1a73e8" onclick="save()">Save</div>
```

After: a native button using tokens, with its states.

```html
<button type="submit" class="btn">Save</button>
<!-- while saving, set aria-busy="true" and disabled -->
```

```css
.btn { background: var(--color-action); color: var(--color-on-action); }
.btn:hover { background: var(--color-action-hover); }
.btn:focus-visible { outline: 2px solid var(--color-focus); outline-offset: 2px; }
.btn:disabled { background: var(--color-disabled); cursor: not-allowed; }
.btn[aria-busy="true"] { cursor: progress; }
```

Mobile equivalents: Dynamic Type or `sp` for text, targets of 44pt (iOS) or 48dp (Android), and `accessibilityLabel` or `contentDescription` on icon-only controls.

## Anti-patterns

- A div or span with a click handler instead of a button or link.
- Hardcoded colors, spacing or font sizes next to an existing token layer.
- Removing the focus outline without a visible replacement.
- ARIA roles on elements that already have the native meaning.
- Signalling errors or status by color alone.
- Introducing a new visual direction into an existing system.
- Restyling unrelated screens while normalizing a PARTIAL system.

---
Version 1.0.0. Last reviewed 2026-11-09.
