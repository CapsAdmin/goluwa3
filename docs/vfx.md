# VFX layer

`goluwa/render3d/sprites.lua`, `vfx.lua`, `trails.lua`, `clips.lua`, `screen_fields.lua` and the ribbon path of `beam.lua` are the engine side of short lived effects; game code composes them (see [jrpg.md](jrpg.md), `addons/game/lua/grenade_effects.lua`, `weapon_effects.lua`). Gpu particles are in [particles.md](particles.md), data files and the effects editor in [data-driven-effects.md](data-driven-effects.md).

## Building blocks

- Sprites are immediate mode: `sprites.GetBatch(texture, extra, color)` returns a batch (one entity, one dynamic mesh, one draw); `batch:Add`, `AddFlat`, `AddAxial` and `AddStreak` add camera facing, planar, axial and streak quads. Call them every frame the sprite should show; a `LateUpdate` pass uploads and hides unused batches. Per sprite colour is the vertex colour: the `VertexTint` material flag makes the translucent and forward overlay shaders multiply emission (or albedo, for lit batches) by it, so one shared material serves every colour.
- Ribbon beams (`Beam.New{Ribbon = true}`) write straight into an owned ffi vertex array. `vfx.AcquireBeam` is a pooled two point tinted ribbon, `vfx.AcquireQuad` a pooled flat quad with its own material for non additive looks.
- `trails.lua` is the gpu ribbon path for anything that follows a moving point (`vfx.AcquireGpuTrail{...}`): each trail owns a ring of history points in a host visible buffer, the cpu pushes one point per frame and the vertex shader smooths, widens, tapers and drifts them. All trails are one draw, so unused vertices must repeat the last real point. History is one point per frame, so a trail's length in time depends on frame rate.
- `vfx.AcquireSlashTrail` (the sword trail) is two beams over one strip: an additive ribbon and a near transparent pane that only exists to carry a surface overlay (a beam's mesh is a scene store mesh, so overlays work on it like on any visual). With `UVStretch` the overlay is mapped along the strip's uv so its pattern keeps its size whatever the trail length.
- `vfx.DefineBurst(key, properties)` + `vfx.Burst(key, position, direction, count)` share one gpu emitter per key; `vfx.DefineDebris`/`vfx.Debris` the same for cpu mesh bursts. Redefining a key drops the old emitter after its particles finish, so it takes effect on the next use. A module that defines bursts lazily behind `vfx.HasBurst` prefixes its keys and calls `vfx.ClearBursts(prefix)` while loading, so a hot reload rebuilds them.
- `vfx.Flash(position, color, lumen, duration, options)` is a small pool of point lights with decay, colour cooling, swelling source radius, drift, sustain and flicker options. Shadows are off by default because every shadowed point light renders a cube of shadow maps.
- `vfx.CreateEmitter` / `vfx.StopEmitter(entity, linger)` for gpu emitters that follow something; `vfx.AddTimed` / `RemoveDelayed` run a timeline.
- `vfx.GetTexture(name)` and `vfx.GetFlipbook(name)`: procedural textures and flipbooks are data files in `lua/vfx_textures/<name>.lua` (`Source` glsl, a flipbook has `Columns`, `Rows`, `TileSize` and defines `flipbook_frame`, optionally `flipbook_normal`). `vfx.UpdateFile` rebakes live and restores the previous data on a glsl error.

## Flipbooks

- Tile edges must be transparent with a constant rgb: mips bleed between tiles.
- Drive the loop through a circle in noise space so the last frame meets the first.
- `vfx.GetFlipbookBatch(name)` returns a lit translucent sprite batch (an additive unlit one when the flipbook has no normal; its rgb must then be premultiplied, since additive emission ignores texture alpha). Lit batches use the `SimpleLighting` material path (direct light plus DDGI ambient), which is far cheaper under heavy overdraw than the full translucent path.
- Give each particle its own start frame, rate and roll so a group is never in sync. Use one sprite per particle: cross fading two frames by drawing the puff twice only sums correctly where texture alpha is 1, so soft edges pulse.
- Never light translucent smoke from the screen GI texture: it holds the surface behind, whose shape then shows through.
- Examples: `fireball_demo.lua`, `smoke_flipbook_demo.lua` in `addons/examples/lua/examples/render3d/`.

## Clips

`goluwa/render3d/clips.lua` is the animation layer (a tracker like GNU Rocket): `clips.Define(name, {Duration, Follow, Tracks, Events, Layers})` + `clips.Play(name, params)`. A clip runs on `vfx.AddTimed`, owns its layers and releases them at the end. Definitions can be pure data, see [data-driven-effects.md](data-driven-effects.md).

- `Tracks` are named eased curves over normalised time (`goluwa/math/track.lua`, easings in `goluwa/math/easing.lua`); each frame their values land in `v`.
- `Events` fire once at a time: bursts, debris, emitters, flashes, scripts.
- `Layers`: `orb`, `gpu_trail`, `sprite`, `quad`, `emitter` (a gpu emitter that follows a param), `slash` (the slash trail) or custom (`Setup`/`Update`/`Remove`). A layer property is a number, a track or param name, or an expression.
- `params` carries what varies per play (`position`, `normal`, `color`, `size`, `entity`, ...). `Follow` moves `params.position` each frame; `EndWithEntity` ends with the entity; `Duration = math.huge` runs until `clip:Stop()`; `clip:End(seconds)` fades out through `v.release`; `clips.Play(name, params, true)` is a manual clip the owner updates itself (no frame of lag against physics).

## Screen fields

`screen_fields.Add{Position, Duration, Radius, Expand, Blur, Ring, Aberration, Darken, Haze, Zoom, ...}` puts a world space sphere on a timeline; the `screen_fields` pass (after motion blur, only active while a field exists) reconstructs world positions from depth and adds radial blur, shockwave ring, aberration, heat haze, zoom and darkening. One primitive builds explosions, zoom punches, dimming and heat haze (`screen_fields_demo.lua`). It evaluates analytically instead of writing the velocity buffer, so TAA never reprojects the fake motion. Sums are taken in `post_source` compressed space because raw sun values overflow half floats; avoid `pow` with a negative base in its shader (undefined in GLSL).

## Exposure compensation

Emissive effects are in absolute units, so the same glow is blown out at night and invisible in daylight. `goluwa/render3d/exposure_compensation.lua` scales an effect's emission by the current camera EV relative to a reference, with an `amount` per effect (0 off, 1 follows the camera fully). It is per effect, never global: the `ExposureCompensation` material property and emitter property, the trail option, and `vfx.SetExposureCompensation(category, amount)` (console `vfx_exposure <category> <amount>`) for the defaults of `particles`, `sprites` and `trails`. Overlay kinds have `Daylight`. jrpg keeps its values in `addons/jrpg/lua/jrpg/effect_exposure.lua`.

## Effects after TAA

TAA keeps a faint copy of thin bright features, so fast thin effects leave gray twins in pixels they have already left, which no mask written by the effect can reach. The `effects_post` stage (after AA, before dof) draws marked effects into their own HDR layer, depth tested against the gbuffer, and adds it to the anti aliased scene; bloom includes it. These effects get no AA and no occlusion by translucent surfaces in front, so give them soft outlines.

- Mark a particle system with `after_aa = true` in `particles.Register{}`; all gpu emitters share one system, so it is all or nothing for them.
- The normal translucent draw skips marked effects only while the layer is active (`post_source.IsEffectLayerActive()`).
- Another translucent extra supports it by providing `IsPostActive` and `BuildPostPasses` and being listed in `translucent_extras.post_list`.

## Pitfalls

- A batch or beam whose geometry moves must call `visual:BuildAABB()` after writing its AABB in place: setting the same table is not a change, so cpu and gpu culling keep the first frame's box and the effect vanishes depending on view angle.
- Write vertex data through a `float *` cast of the vertex array; struct field access per vertex is slow in the interpreter. Big fused loops can fail to compile in the JIT ("register coalescing too complex"); split them into passes (see [performance.md](performance.md)).
- Alpha blended effects are order dependent: smoke drawn in front of fire hides it.
- Emitter slots are shared by every gpu emitter, so cache bursts by a small set of keys.

Tests: `test/tests/render3d/sprites.lua`, `clips.lua`, `clip_mix.lua`, `screen_fields.lua`, `vfx_textures.lua`, and `addons/jrpg/tests/render3d/blade_trail.lua`.
