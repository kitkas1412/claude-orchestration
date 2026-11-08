# Swift Testing and XCTest

Required first step: before writing any test, read `~/.claude/skills/swift-testing-pro/SKILL.md`, plus any of its references the task needs. If you cannot read it, say so in your report.

These project rules take priority over that skill:

- If the target uses XCTest, keep XCTest unless the brief asks for a migration. UI tests stay on XCTest.
- Check the installed Swift version. The skill assumes Swift 6.2 or later, so use newer APIs only when the toolchain supports them.
- The compiler and the project's toolchain are authoritative over any statement in the skill.
- Do not change production code to expose a hidden dependency. Report the needed change under OPEN.
- Run through the project's shared scheme, for example `xcodebuild test -project App.xcodeproj -scheme App`, using the destination recorded in the project's `CLAUDE.md`.
