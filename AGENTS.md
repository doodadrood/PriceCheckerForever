# PriceCheckerForever Agent Guide

- **Local Git Repo**: `/home/T/Projects/PriceCheckerForever` (`origin`: `https://github.com/doodadrood/PriceCheckerForever.git`, default branch `main`, CurseForge ID `1795463`).
- **CurseForge Symlink Recovery**: WoW's `_forever_/Interface/AddOns/PriceCheckerForever` symlink may be overwritten intentionally by CurseForge updates between sessions. Before editing code or asking the user to `/reload` in WoW, verify/restore the symlink via the `wow-addon-dev` global plugin helper (`ensure-addon-link.sh status|restore PriceCheckerForever`, using `BypassSandbox: true` if outside paths aren't visible in sandbox). Never edit an untracked CurseForge copy in `AddOns/` — always restore the link first and work in `/home/T/Projects/PriceCheckerForever`.
- **Line Endings**: Preserve existing line endings (`CRLF` in `PriceCheckerForever.toc`, `Core.lua`, `Modules/*.lua`, `Utils/ItemParser.lua`; `LF` in `Utils/Formatter.lua`, `Tests/Test_Suite.lua`, `.pkgmeta`, `.agents/`).
- **Testing**: Run `luajit Tests/Test_Suite.lua` (`lua` is not installed on `PATH`).
- **Releases**: When asked to cut a release or publish an update, follow `.agents/skills/cut-release/SKILL.md` (`luajit Tests/Test_Suite.lua`, Conventional Commits, bump `PriceCheckerForever.toc`, commit, tag `v<version>`, `git push origin main --tags` with `BypassSandbox: true`).
