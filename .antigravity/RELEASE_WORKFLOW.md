# Release Protocol

When instructed to "cut a release" or "publish an update":
1. Run local tests: `luajit Tests/Test_Suite.lua` and ensure all tests pass.
2. Bump the `## Version:` field in `PriceCheckerForever.toc`.
3. Stage and commit the changes:
   `git add -A && git commit -m "chore: bump version to <version>"`
4. Create a lightweight or annotated tag matching the version:
   `git tag v<version>`
5. Push both the branch and the new tag to origin:
   `git push origin main --tags`
