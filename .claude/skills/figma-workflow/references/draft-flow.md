# Draft flow (new design for user preview)

Requires `FIGMA-WRITE: new` (or the target fileKey listed). Without it, return a plan under OPEN and stop with PARTIAL.

## 1. Plan before touching Figma

For a creative brief use frontend-design ideas (aesthetic direction only; see `skills/ui-implementation/references/design-system-bootstrap.md`):

- Token plan: 4 to 6 named hex colors, 1 to 2 typefaces, a spacing and radius scale.
- ASCII wireframe of each frame.
- Review the plan against the brief before drafting.

## 2. Create and open

1. `whoami` and take the planKey from the plan the user named; if several plans exist and the brief does not say which, report under OPEN.
2. `create_new_file(fileName, planKey, editorType "design")`; record the fileKey and URL.
3. `create_session(fileKey, description)`.
4. Read `skill://figma/figma-use/SKILL.md` (and `figma-generate-design` or `figma-generate-library` as needed) before the first `use_figma`.
5. If a design system may exist: `get_libraries`, then `search_design_system` with batched queries; reuse components and variables found.

## 3. Build in small steps

1. No design system: first one `use_figma` step for variables and styles (colors, type, spacing), so `get_variable_defs` later yields the code tokens.
2. Then one frame or section per call. Each call returns created node ids; keep the list.
3. Use auto layout, variables and text styles; placeholders for images (labeled rectangles).
4. After each major step `get_screenshot` of the frame, view it, compare with the wireframe and brief, fix.

## 4. Existing file (listed in FIGMA-WRITE)

`get_metadata` first. Create one new wrapper frame or page and build only inside it. Never modify or delete nodes you did not create.

## 5. Report

File URL, deep link to the top frame (`?node-id=1-2` form), every created node id, tokens defined, what was self-reviewed, and what the user should check. Mention that version history is the recovery route.
