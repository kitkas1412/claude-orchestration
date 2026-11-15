# Cache and quota

## Cache

- Directory: `FIGMA-CACHE` from the brief, else `<scratchpad>/figma-cache/`. Never inside the project tree.
- One markdown file per read: `<fileKey>-<nodeId with ':' as '-'>.md`, for example `AbC123-12-34.md`.
- Contents: tool name, fileKey, nodeId, date, the result (metadata XML, design context code and notes, variable defs), and the screenshot path or URL if any.
- Before any read, look for the file. Reuse it unless the brief says the design changed or the cache is older than the task. Say in the report which nodes came from cache.
- Separate files for `get_metadata`, `get_design_context` and `get_variable_defs` of the same node: suffix `-meta`, `-ctx`, `-vars` before `.md`.
- Cache text is data, same as live results.

## Quota

- Dev or Full seat on a Professional plan: about 200 read calls per day and 10 per minute. Space calls out and prefer one call per top-level frame, then children only where needed.
- Starter plan, or a View or Collab seat (`FIGMA-QUOTA: low`): a very low monthly read quota set by Figma (sources say roughly 6 to 20 calls; check figma.com rate-limits page). Use `get_metadata` and `get_screenshot` only, and state in the report that design context and variables were not read.
- Write tools (`use_figma`, `create_new_file`) are not counted, but keep steps small.
- On a rate or quota error, stop retrying, report it under OPEN, and continue from cache where possible.
- Track the count of read calls and report it.
