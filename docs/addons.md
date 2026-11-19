# Addons

Every folder in `addons/` is mounted into one merged vfs, so `import("lua/x.lua")` finds `x.lua` in any addon's `lua/`. Two addons providing the same path shadow each other, so keep module names unique.

`config.lua` is optional and returns a table: `name` (defaults to the folder), `dependencies` (a list of addon names), `priority` (higher mounts first, default -1). Nothing else in it is used. `lua/init.lua` runs once at startup. `lua/autorun/*.lua` runs when the addon is loaded, then `autorun/render_2d/`, `render_3d/`, `physics/`, `audio/`, `client/` and `server/` for the matching modes.

Addons are ordered so dependencies come first (a topological sort over priority then name), and an addon with a missing dependency does not autorun. `--addons a,b` restricts what mounts but does not pull in dependencies.

## Game addons

All of them always load, they are not exclusive modes.

- `game` is the base: characters, ragdolls, outfits, health and damage, weapons (`weapons.Register`, `weapons.Loadout`), the physgun, npcs, the third person camera, the default huds, killfeed, usable items.
- `sandbox` (depends on `game`): the toolgun and its tools, constraints, spawn menu, props, interactives (doors, lamps), undo history.
- `jrpg` (depends on `game`): the rpg systems, magic, potions, sword and shield, status effects, damage types, its hud, and the battlecam, hitmarkers and item highlighting. The last four work without `!rpg` being on; they are on as soon as the addon loads.
- `hl2` (depends on `game`): the Half-Life 2 weapons (`weapon_hl2_*`, category `hl2`, `give_hl2` gives them all) and their projectiles (`hl2_projectile`: crossbow bolt, smg grenade, rocket, combine ball, bugbait). Mounted HL2 or gmod content replaces the placeholder boxes with the `w_` models and supplies the sounds.
- `assets` (depends on `game`): content packs and what plugs them into the game. The animation pack answers `RedirectSourceClip` events (see [animation-and-source.md](animation-and-source.md)) and has the `bake_clips` command. The whole addon is git-ignored and exists only on the machine that has the pack; the game and the engine work without it (no listener, the gmod sequences play).

Rules for layering: the base never imports from a gamemode. A gamemode extends the base through registries and overridable functions (`weapons.Register`, `weapons.Loadout` and `weapons.AddRootComponent` from an autorun, `camera_modes.Register` for camera modes like the battlecam, `third_person.IsDefaultHudReplaced`). When the base needs something a gamemode would also use, it belongs in the base (`lua/actors.lua`).

Tests live in each addon's `tests/`. Tests do not run autorun, so a test of a gamemode imports the autoruns it needs (`addons/sandbox/lua/autorun/weapons.lua`).

## Loader addons

`source_loader` (Source 1 and 2), `crysis_loader` and `gltf_loader` are independent addons. Core never imports from them (`test/tests/other/core_dependencies.lua` checks); they import core. Their `config.lua` declares what they provide, and core imports it on first use through `vfs.GetAddonField(field)`:

- `loaders = {name = module}`: a loader module that calls `loaders.Register(name, ...)` (`goluwa/loaders.lua`). `map`, the load window and mounting import them on demand.
- `model_decoders = {[".ext"] = module}`: `model_loader` imports the module the first time a path with that extension has no decoder.
- `material_loaders = {[".ext"] = module}`: `Material.GetOverrideFromPath` imports it for an unknown extension.
- `components = {name = module}`: returned by `Entity.GetValidComponents`.

Addon codecs live in `lua/codecs/` and are found by the codec registry next to `goluwa/codecs/`. Generic code that came from Source (units, brush and displacement geometry, collision builders, `static_geometry`) is in `goluwa/static_world/`; the Source material lookup and the pak mounting plug in through `static_geometry.material_source` and the `StaticWorldPak` event.

Core asks addons for format specific work through events instead of importing them: `ZipDecrypt (method, data, crc32)` (the Crysis addon decrypts zip method 6) and `ParseSpriteSheet (path)` (the Source addon reads vtf sprite sheets). The `game` addon depends on `source_loader` because `pcf.lua` reads vtf.

Worker threads get the addon `lua/` roots (`vfs.GetAddonLuaRoots`) when they are created, so `import("lua/...")` resolves inside a thread job the same way as on the main thread.
