# Repository Guidelines

## Project Structure & Module Organization

This Project Zomboid mod automatically opens and optionally closes doors and gates while running or sprinting.

- `Contents/mods/EreFBIOpenUpDoor/media/` contains the legacy Build 41 implementation, including client Lua and timed actions.
- `Contents/mods/EreFBIOpenUpDoor/42/media/` contains Build 42 client logic, server synchronization, animation definitions in `AnimSets/`, and FBX assets in `anims_X/`.
- Each version stores sandbox settings in `media/sandbox-options.txt` and translations in `media/lua/shared/Translate/<locale>/Sandbox_<locale>.txt`.
- Version-specific `mod.info` files define metadata. Root `workshop.txt` and `preview.png` support Workshop packaging; `.blend` files are animation source assets.

Choose the target game build before editing; do not assume changes apply identically to both trees.

## Build, Test, and Development Commands

There is no package manager, compilation step, development server, or automated test command configured.

- `git diff --check`: check changes for whitespace errors before submission.
- `.\sync_mod.bat`: run from the repository root in PowerShell to copy Workshop metadata and `Contents/` into a local Workshop staging folder. First review and adapt `DestBaseDir`: the script deletes and recreates its destination directory.

Load the mod in the matching Project Zomboid build to exercise changes. Synchronization stages files; it does not publish them.

## Coding Style & Naming Conventions

Follow surrounding Lua style: four-space indentation, local helpers, camelCase functions and variables, and uppercase snake_case constants. Preserve the `EreFBIOpenUpDoor` namespace and existing game API conventions. Keep client behavior and server command handling in their respective directories. No formatter or linter is configured.

Keep sandbox option identifiers aligned with Lua lookups and translation keys. Preserve locale filenames and existing animation naming patterns.

## Testing Guidelines

No automated testing framework or coverage threshold is present. Record manual results for the affected build: running versus sprinting, open/close behavior, locked or barricaded doors, gates, and relevant sandbox settings. For multiplayer changes, verify door state and animations from multiple clients. Include reproduction steps and observed results in the pull request.

## Commit & Pull Request Guidelines

Follow recent history using scoped Conventional Commits, such as `fix(client): validate move dir on shared door tile` or `chore(mod): bump version to 1.42.5`.

Keep pull requests focused. Describe affected builds, behavior changes, linked issues when applicable, and verification performed. Include screenshots or short recordings for animation or other visible changes.
