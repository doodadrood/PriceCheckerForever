---
name: cut-release
description: >-
  Run tests, bump version in PriceCheckerForever.toc, commit, tag, and push
  to origin to trigger the GitHub Actions CurseForge release packager. Use
  when the user asks to "cut a release" or "publish an update".
---

# Release Protocol

Follow these steps whenever the user asks to cut a release or publish an update:

1. Run the local test suite and confirm every assertion passes:
   ```bash
   luajit Tests/Test_Suite.lua
   ```
2. If there are uncommitted feature/bugfix changes, commit them first with a descriptive Conventional Commit message (for example `fix: ...` or `feat: ...`) so `BigWigsMods/packager` includes them in the generated CurseForge changelog.
3. Bump the `## Version:` field in `PriceCheckerForever.toc` (preserving its CRLF line endings).
4. Stage and commit the version bump:
   ```bash
   git add -A && git commit -m "chore: bump version to <version>"
   ```
5. Create the release tag matching `v<version>`:
   ```bash
   git tag v<version>
   ```
6. Push `main` and the new tag to `origin` (this requires `BypassSandbox: true` and triggers `.github/workflows/release.yml` -> CurseForge upload):
   ```bash
   git push origin main --tags
   ```
