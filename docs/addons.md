# Addons

Every folder in `addons/` is mounted into one merged vfs, so `import("lua/x.lua")` finds `x.lua` in any addon's `lua/`. Two addons providing the same path shadow each other, so keep module names unique.

`config.lua` is optional and returns a table: `name` (defaults to the folder), `dependencies` (a list of addon names), `priority` (higher mounts first, default -1). Nothing else in it is used. `lua/init.lua` runs once at startup. `lua/autorun/*.lua` runs when the addon is loaded, then `autorun/render_2d/`, `render_3d/`, `physics/`, `audio/`, `client/` and `server/` for the matching modes.

Addons are ordered so dependencies come first (a topological sort over priority then name), and an addon with a missing dependency does not autorun. `--addons a,b` restricts what mounts but does not pull in dependencies.

An addon that imports another addon's file (a `lua/` path only that addon has, or `addons/<folder>/...`) must list it in `dependencies`, directly or through a dependency; `test/tests/other/addon_dependencies.lua` checks every import in every mounted addon, tests included. When a lower addon needs behaviour from a higher one, the higher one plugs in (an event, a registry, or overriding a method from its autorun, like `jrpg` replacing `ai_controller:Cast`) instead of being imported.

## Game addons

All of them always load, they are not exclusive modes.

- `game` is the base: characters, ragdolls, outfits, health and damage, weapons (`weapons.Register`, `weapons.Loadout`), the physgun, npcs, the third person camera, the default huds, killfeed, usable items.
- `sandbox` (depends on `game`): the toolgun and its tools, constraints, spawn menu, props, interactives (doors, lamps), undo history.
- `jrpg` (depends on `game`): the rpg systems, magic, potions, sword and shield, status effects, damage types, its hud, the battlecam, hitmarkers and item highlighting (some of these are active as soon as the addon loads, without `!rpg`).
- `hl2` (depends on `game`): the Half-Life 2 weapons (`weapon_hl2_*`, category `hl2`, `give_hl2` gives them all) and their projectiles (`hl2_projectile`: crossbow bolt, smg grenade, rocket, combine ball, bugbait). Mounted HL2 or gmod content replaces the placeholder boxes with the `w_` models and supplies the sounds.
- Addons whose folder starts with `__` or `.` are disabled. A local, git-ignored content pack addon can plug into the game through events (the animation pack answers `RedirectSourceClip`, see [animation-and-source.md](animation-and-source.md)); the game and the engine work without it.

Rules for layering: the base never imports from a gamemode. A gamemode extends the base through registries and overridable functions (`weapons.Register`, `weapons.Loadout` and `weapons.AddRootComponent` from an autorun, `camera_modes.Register` for camera modes like the battlecam, `third_person.IsDefaultHudReplaced`). When the base needs something a gamemode would also use, it belongs in the base (`lua/actors.lua`).

Tests live in each addon's `tests/`. Tests do not run autorun, so a test of a gamemode imports the autoruns it needs (`addons/sandbox/lua/autorun/weapons.lua`).

## Loader addons

`source_loader` (Source 1 and 2), `crysis_loader` and `gltf_loader` are independent addons. Core never imports from them (`test/tests/other/core_dependencies.lua` checks); they import core. Core finds what they provide by file, the way `autorun` works: `vfs.GetAddonModules(dir)` lists `lua/<dir>/*.lua` across the mounted addons (first mount wins) and core imports the file named after what it needs, on first use. The file registers itself on import, so adding one needs no list anywhere.

- `lua/loaders/<name>.lua`: calls `loaders.Register(name, ...)` (`goluwa/loaders.lua`). `map`, the load window and mounting import them by name or all at once.
- `lua/model_decoders/<ext>.lua`: `model_loader` imports it the first time a path with that extension has no decoder. One file per extension; a decoder with two extensions has a one-line alias file for the second (`vmesh_c.lua`, `glb.lua`). Code a worker job imports must not live here (it would register on import): `crysis_loader/cgf.lua` is the worker side of `model_decoders/cgf.lua`.
- `lua/material_loaders/<ext>.lua`: `Material.GetOverrideFromPath` imports it for an unknown extension.
- `lua/components/<name>.lua`: returns the component meta. `Entity.GetValidComponents()[name]` imports it on first lookup and keeps it, so nothing registers components by hand; a component whose module defines pvars or event listeners when imported still needs a plain `import` from an autorun so they exist before the first entity uses it (`Entity.RegisterComponent` is for components not in a file of that name). Only components that were looked up take part in the entity property search that adds the component owning an unknown property.

Addon codecs live in `lua/codecs/` and are found by the codec registry next to `goluwa/codecs/`. Generic code that came from Source (units, brush and displacement geometry, collision builders, `static_geometry`) is in `goluwa/static_world/`; the Source material lookup and the pak mounting plug in through `static_geometry.material_source` and the `StaticWorldPak` event.

Core asks addons for format specific work through events instead of importing them: `ZipDecrypt (method, data, crc32)` (the Crysis addon decrypts zip method 6) and `ParseSpriteSheet (path)` (the Source addon reads vtf sprite sheets). The `game` addon depends on `source_loader` because `pcf.lua` reads vtf.

Worker threads get the addon `lua/` roots (`vfs.GetAddonLuaRoots`) when they are created, so `import("lua/...")` resolves inside a thread job the same way as on the main thread.
