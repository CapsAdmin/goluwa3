# Surface conditions

Fire, frost and water (and game kinds such as poison) that cover patches of the static world: a sparse cell field simulated on the CPU, uploaded to the GPU and read by the gbuffer (char, embers, frost, wet film), plus particles (smoke, embers, mist, steam), procedural flame sheets and pooled point lights. Things that move are not part of the field; they react through exposure.

Start from `goluwa/render3d/surface_conditions.lua` (field, simulation, upload, gbuffer GLSL, lights), `surface_conditions/*.lua` (the engine kinds), `surface_condition_particles.lua` and `surface_condition_sheets.lua`. Example: `addons/examples/lua/examples/render3d/surface_conditions_demo.lua`.

## The field

- Cells are small voxels created only where a ray found a surface; a cell keeps that surface point and normal, the material's flammability (the `effect_response` feature) and whether it is thin fuel (alpha tested or vegetation).
- Every cell has every kind's channels (a few named floats, uploaded as unorm8) plus CPU-only state. Kinds read and write each other's channels: interactions (fire melts frost into water, water quenches fire) live in the kind that reacts.
- `surface_conditions.Apply(kind, position, radius, amount, normal)` finds surfaces with rays and fills the cells. `Query(position, radius, channel)` is the gameplay read. `Clear()` drops everything.
- The simulation ticks over active cells only. `surface_conditions.Reach` discovers neighbouring cells along the surface with a few rays and remembers misses. Rays are budgeted by time per tick, not by count, because CPU raycast cost varies hugely between scenes; a cell that runs out of budget retries next tick.
- The field only exists on static geometry. Rays skip non static bodies, and visuals the engine treats as moving (`Visual.Library.IsVisualDynamic`) are flagged in their instance rows (`instances.SetDynamic`, rescanned periodically or with `MarkDynamicVisuals()`) so the gbuffer skips the field for them.
- Weather: cells open to the sky (`IsExposed`, a cached ray along the precipitation direction) take wetness and snow from `surface_weather`, so a fire under a roof keeps burning in the rain.

## GPU side

- Cells are packed into bricks in staged scene store tables, found through an open addressing hash of brick coordinates. The Lua and GLSL hash must stay identical. Uploads run in a `PreRenderPass` listener before render3d's.
- The lookup warps the position along the surface with noise and blends the surrounding cells, renormalised over the cells that exist and weighted by normal agreement (so a wall burnt on one side stays clean on the other). The warp and jittered `Apply` rays are what hide the cell grid; keep both if the cell size changes, and keep effect boundaries soft.
- In the gbuffer: sample the field, let kinds' `glsl.weather` adjust the weather (heat melts snow, frost removes the rain film), then `apply_surface_conditions`. It returns how much of an alpha tested surface is consumed, which the gbuffer discards with a dither (burnt leaves disappear; their shadows do not). Wet looks use `apply_surface_wetness` (the same function rain uses) and films `add_surface_film`. Snippets must take noise from the effect position `e.P`/`e.N` (object local), not from world position.
- Looks come from a procedural tileable noise texture (`GetNoiseTexture`, triplanar), never from per pixel hashing.
- Sites: each tick the cells a kind wants visible are written as sites (position, normal, four kind values). The particle system spawns from them and the sheet renderer draws flame sheets per site.
- Flame sheets are camera facing quads along world up with a soft depth fade. They are partly opaque OIT layers plus a smaller additive share: purely additive sheets wash out where many overlap. Anything noise adds to the flame shape must still go to zero inside the quad or the edges show.

## Media

Optical constants come from `media.presets`: frost is `ice` (diffuse reflectance of a semi infinite body), char and ash use the `charcoal` and `ash` reflectances, flame sheet opacity is `media.GetOpacity("flame", ...)`, the wet film's F0 is water's. Embers and flames are blackbody emission; smoke, mist and steam are particles of the shared `conditions` medium.

## Adding a kind

Engine kinds are in `goluwa/render3d/surface_conditions/` (listed in `surface_conditions.kinds`); game kinds are files in any addon's `lua/surface_conditions/` (poison is `addons/jrpg/lua/surface_conditions/poison.lua`), found when `surface_conditions.lua` loads, before addon autorun, because the passes are built from the kind list. Kinds cannot be added after the passes are built. A kind has `name`, `channels`, `Init`, `Apply`, `Step` (returns whether the cell stays active; call `sim.Touch` after changing channels and `sim.Activate` for neighbours it wakes) and optional `exposure`, `Site`, `particles`, `sheet`, `light`, and `glsl.common` / `glsl.weather` / `glsl.surface` snippets. Copy an existing kind.

## Exposure

What touching a condition does to a moving thing. A kind's optional `exposure` list (in the kind file or `surface_conditions.SetExposure(kind, entries)`; jrpg sets the engine kinds' in `addons/jrpg/lua/autorun/render_3d/surface_exposure.lua`) maps a channel to a surface overlay kind ([surface-overlays.md](surface-overlays.md)) with a threshold and intensity.

- The `surface_exposure` component samples `Query` around the bottom of its entity's visuals and drives the overlay's intensity from the level. With `Latch` the level only rises and stays, which is how things stay `charred` after a fire.
- NPCs, the local player rig and sandbox props carry the component; an entity opts in with `surface_exposure = {}`.

## Trying it

Nothing in the game applies the field by itself. Console: `surface_condition <kind> [radius] [amount]` (at the crosshair) and `surface_condition_clear`. The `surface_test` weapon (`addons/game/lua/weapons/surface_test.lua`) applies, cycles kinds and clears by hand; stand an NPC or prop in the result to see exposure.

## Verifying

`test/tests/render3d/surface_conditions.lua` (discovery, spreading, interactions, rain against a roofed fire, the gbuffer change, dynamic visuals left alone, exposure) and `addons/jrpg/tests/render3d/surface_exposure.lua`. Judge looks with `Shot` both at a locked EV in daylight and at night with auto exposure: flames are emissive in absolute units and read very differently at the two.
