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

`source_loader` (Source 1 and 2 maps and games) and `crysis_loader` (Crysis levels) are independent addons that each `loaders.Register` a loader (`goluwa/loaders.lua`) and hold their content code under `lua/<name>/`. Their model decoders (`model_decoders/`: mdl, vmdl_c, vphys_c, bsp; cgf) register from `lua/autorun/render_3d/model_decoders.lua` and their components (`components/`: source_light, cry_level) from `lua/autorun/components.lua`, which `test/environment.lua` imports because tests skip autorun. Everything imports them by their real path (`addons/source_loader/lua/source_loader/...`) because worker threads, which run the decoders, do not mount addons. `gltf_loader` (the glTF scenes in its `scenes/` directory, and the `.glb`/`.gltf` model decoder) follows the same layout.
