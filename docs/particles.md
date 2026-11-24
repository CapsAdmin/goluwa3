# Particles

GPU particle pools simulated by one compute pass and drawn through the translucent passes. Rain and snow are low level systems; `particle_emitter_gpu` and `particle_emitter_cpu` are the editor facing components.

Start from `goluwa/render3d/particles.lua` (the system; the `Register{...}` fields are documented at its top), `passes/particles.lua`, `precipitation.lua` (rain and snow), `particle_emitter.lua` (shared emitter properties and their lists), `particle_emitter_gpu.lua`, `particle_emitter_cpu.lua`, `particle_shaders.lua`, `medium_lighting.lua`.

## How it fits together

- A system is a pool of `Particle`s in one device local buffer, created when it first has something to show. Its behaviour is glsl bodies (`spawn`, `update`, optional `visibility`, `collide`, `should_spawn`, `shade`) and its own uniform block. Systems are matched by name, so a reloaded module takes over its slot and pool.
- `particles_simulate` is one dispatch over all active pools: dead slots spawn, live ones age, update, collide and get their light. It runs before `translucent`.
- Drawing is the `particles` entry of `translucent_extras.lua`: vertex pulling from the pools by device address; a particle is a capsule along its velocity (never thinner than about a pixel, fading instead) or a camera facing sprite.
- Light is computed per particle every few frames and stored, so the draws only read it: the sun through the same chain the froxel fog uses, local lights and DDGI or sky ambient. `medium_lighting.lua` is what fog and particles share; use it for any new medium. A system registers a `medium` (a `media.presets` name) for its phase function and albedo.
- Per slot random numbers come from the generation counter, so respawns differ.

## Precipitation

Rain and snow fill a box around the camera that wraps on every side, so density is constant and teleports cost nothing; each drawn particle stands for several real ones. Both collide with the shelter map, and a box wrap is not treated as a fall. `r_feature_precipitation` turns both off.

## Collision

A system sets `collision = "shelter_map" | "scene_depth" | "rays"` (switchable at runtime) plus a `collide` body that tests the step from the previous position. Helpers from `particles.GetCollisionGLSL`: `particle_stick`, `particle_bounce`, or set `p.life = 0.0` to die.

- `shelter_map`: depth from above along the precipitation direction; only sees tops of things.
- `scene_depth`: the view's depth and normals; only sees what is on screen.
- `rays`: a short ray query per particle against the scene; needs ray tracing, ignores alpha, keep counts modest.

## Emitter components

Plain `GetSet` properties (storable, prefab friendly). `particle_emitter.Step` decides how many particles to spawn per frame for both types, and the editor shows only what each type supports.

- `particle_emitter_gpu`: lit or emissive blended particles; all gpu emitters share one system (`emitters`) with a ring allocated range per emitter and a fixed number of emitter slots. A gpu emitter that finds no free slot or range draws nothing until room frees up instead of erroring, because an error in the pass listener would remove the particle pass for the rest of the session.
- `particle_emitter_cpu`: solid meshes simulated in Lua over ffi arrays and drawn through gbuffer instancing (lit like models). Transparent materials are drawn by single draws in the translucent passes instead. Collision is `none` or budgeted scene `rays`.
- The two backends run different code: a shape or force change that belongs in both has to be made in the glsl of `particle_emitter_gpu.lua` and in `particle_emitter_cpu.lua`.
- `emitter:BurstAt(count, position, direction)` queues a burst with its own origin, so one shared emitter can serve many bursts; `Burst(count)` spawns at the emitter's transform. `RatePerMeter` spawns along the path the emitter moved since the last frame, so fast sweeps leave no gaps.
- Properties flagged `range` in `particle_emitter.lua` take a number or `{min, max}` (`particle_emitter.GetRange`); each particle draws its own value. Ranges are opt in per property because each costs space in the gpu emitter block; to add one, flag it in the list, read it with `GetRange` in both backends, and give the field `Range = true` in `effects_schema.lua`.
- Band properties (`Size`, `Color`, `Emissive`) are values over the particle's life: a constant, a range, or a curve (optionally a band between two curves, so a particle that is big stays big). They are baked into sample tables (`particle_emitter.BakeScalar`, `BakeColor`) that the gpu shaders read by device address and the cpu emitter samples directly.
- Damage types can list `Debris` (cpu mesh bursts) for impacts and projectile trails.

## Shaders

A gpu emitter has a `Shader` (default `glow`) and `ShaderParams`. `goluwa/render3d/particle_shaders.lua` is the registry: `Register(name, {Params, Sprite, Source})`. Numeric params are packed into a fixed number of floats per emitter (16); texture params are looked up by name (vfx textures and flipbooks, then asset paths).

- `Source` is glsl with up to four optional functions, `spawn`, `update` (before drag and integration), `visibility` (multiplied into alpha) and `shade` (after the common shading), compiled into the shared `emitters` system after the common code. The compiler finds them by name, renames them per shader and dispatches by `e.shader`. Every param is a preprocessor name for its slot in `e.params`, so a function that reads a param needs `e` in scope and a local cannot reuse a param name.
- `Sprite` names the texture param: those particles are textured camera facing quads instead of capsules. Flipbooks play at `FlipbookFps` (0 plays once over the life); `Stretch` draws a streak along screen space velocity; `Orientation = "ground"` lays sprites flat. The `sprite` shader draws any texture with no hooks; `puff` is the flipbook smoke and fire look.
- A sprite texture may be a `.vtf` with a Source sprite sheet (`goluwa/render3d/sprite_sheets.lua`), drawn through a lookup of frame rectangles; the `Sequence` property picks each particle's sequence. Source images have row 0 on top, so their rectangles are flipped for the sprite quad's v.
- The glsl is compiled when the passes are built. After registering or changing a shader call `particles.Recompile()`: it rebuilds only `particles_simulate` and throws the compile error while the old pipeline keeps running (`particle_shaders.ParseError` maps it to a source line). Undo a bad shader before recompiling again.
- The game side is `addons/game/lua/particle_shader_library.lua` (data files in `addons/game/lua/particle_shaders/`), edited in the effects editor, see [data-driven-effects.md](data-driven-effects.md).

## Pitfalls

- A block layout table must nest sub layouts as an element; `unpack(...)` in the middle of a table constructor only yields one value (Lua semantics).
- A pass that reads a storage buffer from the vertex stage by address needs barriers by hand: compute to vertex after the dispatch, vertex to compute before it (see `particles_simulate`'s `on_draw`).
- Systems that depend on ray queries must still work with `GOLUWA_NO_RAY_TRACING=1`.
- `after_aa = true` draws a system after TAA (see [vfx.md](vfx.md), Effects after TAA).

## Verifying

`test/tests/render3d/particles.lua` reads pools back (`particles.Download(system)`) and covers the box, motion, lighting, spawning, collision modes and cpu emitters; also `particle_emitter_gpu.lua` and `particle_emitters.lua` there. `particles_demo.lua` (addons/examples) cycles collision modes. Measure gpu time with the `particles_simulate` scope and the particle draws inside the translucent passes.
