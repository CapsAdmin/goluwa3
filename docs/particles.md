# Particles

GPU particle pools simulated by one compute pass and drawn through the translucent passes. Rain and snow are low level systems; `particle_emitter_gpu` and `particle_emitter_cpu` are the editor facing components.

Start from `goluwa/render3d/particles.lua` (the system; the `Register{...}` fields are documented at its top), `passes/particles.lua`, `precipitation.lua` (rain/snow physics and rates), `particle_emitter.lua` (shared emitter properties), `particle_emitter_gpu.lua`, `particle_emitter_cpu.lua`, `medium_lighting.lua`.

## How it fits together

- A system is a pool of `max_count` `Particle`s (80 bytes) in one device local buffer, created when it first has something to show. Its behavior is glsl bodies (`spawn`, `update`, optional `visibility`, `collide`, `should_spawn`, `shade`) and its own uniform block. Systems are matched by name; a module that reloads takes over its slot and pool.
- `particles_simulate` is one dispatch over the largest active pool (x particle, y system). A dead slot spawns, otherwise it ages, updates, collides, gets visibility, and gets its light. The pass is in `default_passes` before `translucent`.
- Drawing is the `particles` entry of `translucent_extras.lua`: vertex pulling from the pools by device address; a particle is a capsule along its velocity, never thinner than about a pixel and a half (fainter by the same amount).
- Light is computed per particle every `RELIGHT_INTERVAL` frames and stored, so the draw passes only read it: the primary sun through the same chain the froxel fog uses (atmosphere, fog layer, shadow maps, cloud shadow, Henyey-Greenstein phase), local lights (`medium_lighting.GetLocalLightsGLSL`), and DDGI probes or the sky environment for ambient. In surfel mode particles on screen read the fog's GI grid (`froxels.gi`, the 8 nearest cells, skipping -1) and blend their light over relights against its noise; elsewhere they use the surfel lookup. `medium_lighting.lua` is what fog and particles share; use it for any new medium.
- Per-slot random numbers come from the generation counter (`p.user.x`) so respawns differ.

## Precipitation

Rain and snow fill a box of `BOX_SIZE` (20 m) around the camera, wrapped on every side, so density is constant and teleports cost nothing. The drawn count is capped and each particle stands for `coverage_scale` real ones. Wind is read every frame; size is read at spawn. Both collide with the `shelter_map`; a box wrap is not a fall (the update resets `particle_previous` so the step is not tested). `r_feature_precipitation` turns both off.

A system with `after_aa = true` is drawn after TAA in the effect layer (see vfx.md, Effects after TAA), which removes TAA ghosting of fast thin streaks.

## Collision

A system sets `collision = "shelter_map" | "scene_depth" | "rays"` (read each frame) plus a `collide` body; after the update the step from `particle_previous` to the new position is tested. Helpers in `particles.GetCollisionGLSL`: `particle_stick`, `particle_bounce`, or `p.life = 0.0` to die.

- `shelter_map`: the depth map from above along the precipitation. One read per end of the step; only sees tops of things.
- `scene_depth`: the view's depth and normals. Cheap; only sees what is on screen.
- `rays`: a short ray query per particle against the scene store (`hit.GetTraceGLSL`, solid mask). Needs ray tracing; no alpha; keep counts to tens of thousands.

The pass binds all resources whatever the mode, so a system can switch at runtime.

## Emitter components

Plain `GetSet` properties (storable, prefab friendly): rate, bursts, loop/duration, shape, speed, lifetime, gravity, drag, size, `OnHit`. `particle_emitter.Step` decides how many particles to spawn per frame (the same for both types). The two types follow each other where they can, and the editor shows only what each supports.

- `particle_emitter_gpu`: thousands of lit/emissive blended capsules; all gpu emitters share one system (`emitters`) with a ring-allocated range per emitter (`POOL_SIZE`, `MAX_EMITTERS`). All collision modes.
- `particle_emitter_cpu`: hundreds of solid meshes simulated in Lua over ffi arrays and queued into the gbuffer instancing path each frame (lit like models, with fog/AO/TAA). Collision is `none` or `rays` via the scene raycast, at most `RAY_BUDGET` per frame.

A `particle_emitter_cpu` whose `Material` is transparent (refractive, translucent, additive) is drawn by single draws in the translucent passes instead of the gbuffer instances: it extends the translucent depth range and requests the refraction source in `PreDraw3DTranslucent`, and thickness is `RefractionThickness` or 0.3 x the particle size. Meshes tumble around a per particle axis (`Spin` is the rate); `shard` is a faceted bipyramid. `Sparkle` (gpu) twinkles each particle's alpha. `Fizzle` (gpu, m/s^2) pushes each particle in a fast changing noise direction once `FizzleStart` (fraction of its life) has passed, so a burst that has slowed down scatters before it dies. `Flow` (gpu, m/s^2) adds the curl of a value noise field (`FlowScale` is its spatial frequency, features are 1/`FlowScale` m, the emitter `Seed` offsets it) to every particle's velocity, so a burst drifts in swirls; it is static in time, unlike the flow ribbon spray (`flow_ribbons.lua`) whose field also moves. Damage types can list `Debris` (material, `Trail` for projectiles, `Emitter` for impacts; `Mesh` per emitter) and the impact effect bursts it. `SwayAmount`/`SwayRate` push cpu particles sideways with a per particle phase and `RockAngle` rocks a mesh back and forth instead of tumbling (feathers).

`emitter:BurstAt(count, position, direction)` queues a burst with its own origin (one is consumed per frame, the emitter does not move), so a shared emitter can serve many bursts a frame; `Burst(count)` spawns at the emitter's transform. A gpu emitter past `MAX_EMITTERS` simply gets no range and draws nothing, it does not error.

They run different code: a shape or force change that belongs in both has to be made in `particle_emitter_gpu.lua` (glsl) and `particle_emitter_cpu.lua`.

## Pitfalls

- A block layout table must nest sub-layouts (`light_occlusion.GetBlockLayout()` as an element); `unpack(...)` in the middle only yields one field.
- A pass that reads a storage buffer from the vertex stage by address needs the barriers by hand: compute to vertex after the dispatch, vertex to compute before it (see `particles_simulate`'s `on_draw`).
- Systems that depend on ray queries must work with `GOLUWA_NO_RAY_TRACING=1` (the particle test passes with it).

## Verifying

`test/tests/render3d/particles.lua` reads pools back (`particles.Download(system)`) and covers the box, motion, lighting, ring spawn, both collision modes and cpu emitters. The example `particles_demo.lua` (addons/examples) cycles collision modes. Measure gpu time with the `particles_simulate` scope and the two draws inside `translucent_moments` / `translucent_accumulate`.
