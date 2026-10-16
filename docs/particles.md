# Particles

*GPU pools, one compute pass, drawn through the translucent passes; rain and snow are low level systems, the particle_emitter_gpu and particle_emitter_cpu components are the high level ones; collision with the shelter map, the scene depth or the scene bvh (2026-10-16)*

`goluwa/render3d/particles.lua` is the particle system, `precipitation.lua` registers rain and snow on it (the physics, the rates, the size distributions and the extinction stay there). It replaced the stateless instanced draw that rain and snow had: positions from a hash and the time, lit by an analytic ambient, no way to simulate or light anything better.

## How it works

- A system (`particles.Register{...}`, the fields are documented at the top of `particles.lua`) is a pool of `max_count` 64 byte `Particle`s in one device local buffer (`position age velocity life radiance visibility width user`), created when the system first has something to show. Its behavior is three glsl bodies: `spawn`, `update` and an optional `visibility`, and its own uniform block (`<name>_data`, the system's `block` and `WriteBlock`).
- The `particles` pass (`passes/particles.lua`, before `translucent` in `default_passes`, so `r_pass_particles` turns every system off) has one compute pipeline, `particles_simulate`: one dispatch, x the particle, y the system, over the largest active pool. A slot whose life is over (or that never lived: the buffer starts as zeros) spawns, otherwise it ages and updates. Then it gets its visibility (fading by the distance to the camera, by its age, and the system's own), and its light. A slot spawned the first time starts at a random age or they all end together. The generation (`p.user.x`) seeds the system's random numbers (`pcg3d_unorm(uvec3(index, generation, k))`).
- Drawing is a `translucent_extras.lua` entry (`particles` is the extra): `particles_moments` and `particles_accumulate`, vertex pulling from the pools by their device addresses, `gl_InstanceIndex` runs through the systems in order (`systems[k].first`). A particle is a capsule along its velocity over `streak_time` and `width` wide, never thinner than a pixel and a half and fainter by as much, the coverage profile, the alpha (width / (path + width), times the system's coverage scale), the motion vectors and the blend into the moments are the ones precipitation had before.
- `particles.systems` entries are matched by name, a module that loads again takes over the slot and the pool.

## Light

The light of a particle is computed once per `RELIGHT_INTERVAL` (4) frames, when it spawns and when it stops being hidden, and stored in it, so the two draw passes only read it:

- the primary directional light (the sun, the moon at night) through the same chain the froxel fog uses: the atmosphere's transmittance, the fog layer and precipitation above the point, the sun's shadow maps and the clouds' shadow, times the Henyey-Greenstein phase of the system's `scatter_g` towards the viewer;
- the local lights around it (`medium_lighting.GetLocalLightsGLSL`, the same function the fog uses, at most 8 lights, with their shadows and occlusion maps), through the phase function too;
- the light around it: the DDGI probes where there are probes that can see the point (`ddgi_sample_irradiance`, with the confidence fade into the next source), the sky's environment irradiance (`sample_environment_irradiance`, what the translucent pass falls back to) where there are none or `r_pass_ddgi` is off. The irradiance is looked up on both sides of the particle, along the view direction (the light behind it, which it scatters forward) and against it (scattered back), weighted by the share of the phase function's integral over each hemisphere (`get_forward_fraction`, 0.95 for rain, 0.88 for snow).

Things this means in a scene: the sun is part of the lighting only as far as the ground fog model lets it through, so in a snowstorm (the precipitation extinction is uniform up to 1.1 km) the direct term is zero and the flakes are lit by the sky and the probes, like the surfaces are; at night a lamp makes the snow and rain around it glow, most where the lamp is behind the particle (forward scattering), and a particle indoors is hidden by the shelter map; rain and snow against a bright sky are as bright as the sky behind them, so they show against dark backgrounds and are nearly invisible against the haze, which is what they look like.

`medium_lighting.lua` is what the fog and the particles share (the primary sun out of the lights block, writing that block, the local lights' scattering). Use it for the next medium that needs lighting.

## Precipitation

- Rain and snow are boxes of 20 m around the camera, wrapped on every side (`wrap_into_camera_box`), so the density is the same wherever the camera goes and a teleport costs nothing. The drawn count is the physical number of particles in the box capped at 131072 per system, each one standing for `coverage_scale` particles (snow at 5 mm/h has 27). Rain and snow keep the size distributions, fall speeds and extinction they had (`precipitation.lua`, the same functions weather and the fog read), snow also has a flutter that is added as the change of an analytic function of the age over the step, so it doesn't drift.
- The wind is read every frame (a gust changes the velocity of the particles that are in the air, the stateless version jumped them), the size when a particle spawns (so a rate or a temperature change reaches all of them within a lifetime, 8 to 16 s for rain, 12 to 24 s for snow).
- Rain and snow collide with the `shelter_map` (below). A drop that hits dies and its slot spawns again, a flake is stuck on the surface (`particle_stick`, half sunk by its size), `user.y` 1 and `user.z` the age it landed at, and fades over `SNOW_LAND_TIME` (1.5 s). A particle that is under something it did not fall through (it spawned there, or the box wrapped it there) is hidden by the system's visibility. The box wrapping a particle is not a fall: the update sets `particle_previous = p.position` so the step is not tested.
- `r_feature_precipitation` turns both off.

## Collision

A system says what its particles collide with: `collision = "shelter_map" | "scene_depth" | "rays"` (nil is nothing), read every frame so it can change while the game runs, and `collide`, the body of `void <name>_collide(uint index, inout Particle p, vec3 previous, vec3 hit, vec3 normal)`. After the update the simulation tests the step from `particle_previous` (where the particle was before the update) to where it is, and a hit calls `collide` with the point and the surface's normal, facing the particle. What a hit usually does is in `particles.GetCollisionGLSL`: `particle_stick` (lie on the surface), `particle_bounce(p, hit, normal, restitution, friction)`, or `p.life = 0.0` to die.

| mode | what it sees | cost | where it fails |
|---|---|---|---|
| `shelter_map` | the depth map of the world from above along the precipitation (`surface_weather.shelter_map`, what keeps rain off roofs, cascade 1 of the sun shadow) | one texture read at each end of the step | only the tops of things: sides, undersides and overhangs are not there, nor is anything past the map's extent. Hit when the step goes from above the stored depth to under it, the point is found along the map's depth gradient |
| `scene_depth` | the depth buffer and normals of the view (`gbuffer`, so before translucent) | one read of the pixel the particle ends in | what is not on screen, or behind something. A hit needs the particle behind the visible surface by less than a thickness (0.3 m, 5% of the depth, or its step, so a fast one does not go through) and in front of it at the start of the step |
| `rays` | the scene bvh (`scene_bvh_trace`, the software traversal, so it works on a gpu without ray tracing, and with it on dynamic objects as the bvh holds them) | one short ray per particle (the step plus the radius) | the bvh has no alpha (foliage cards, glass), it must be built (`scene_bvh.EnsureBuilt` is called while a system asks for rays, `bvh_ready` is 0 until it has triangles); keep the count to tens of thousands |

The bvh is the right thing for general collision (it is world aligned, solid, and a step of a few centimeters is a few nodes, size matters little), the other two are for when it is too much: weather has far too many particles for a ray each, and `scene_depth` is for effects that only matter where the camera looks. The pass binds the bvh buffers always (a placeholder buffer while it is not in use, `bvh_ready` 0), so a system can switch mode at runtime.

## Particle emitters

Systems above are shader code (`spawn`, `update`, ...), the advanced way. The particle emitter components are the high level one, built for an editor: plain properties (`GetSet`, storable, so a property editor lists them in groups and a prefab saves them), no code. There are two of them, and they are different things that follow each other where they can and deviate where they have to, so the editor shows only what each one can do. `particle_emitter` is the base both extend (like the lights extend `light`), it is not added by itself. The properties are lists in `goluwa/render3d/particle_emitter.lua`: `common`, `gpu` and `cpu`.

**Both** (the base): `Rate` (per second), `Burst(count)` (a method), `Loop`, `Duration` (a non looping emitter emits for that long after `Restart()`), `Playing`, `Seed`, `Visible`; `Shape` (point, sphere, cone, box, disc), `ShapeSize`, `Spread` (degrees, the cone around the axis); `LifetimeMin/Max`, `SpeedMin/Max`, `InheritVelocity` (of the emitter), `GravityScale`, `Drag`; `SizeStart/End` (meters); `OnHit` (`bounce`, `stick`, `kill`), `Restitution`, `Friction`. The particles are thrown along the entity's up, from its position, in world space, and the emitter can move. Every frame `particle_emitter.Step` says how many particles to spawn (the rate carried over, bursts, capped by `MaxParticles`), the same for both.

| | `particle_emitter_gpu` | `particle_emitter_cpu` |
|---|---|---|
| for | thousands of sparks, smoke, dust, magic | hundreds of solid things: debris, pebbles, leaves, shells |
| `MaxParticles` | up to 16384, default 1000 | up to 4096, default 100 |
| look | blended capsules. `ColorStart/End` (alpha fades it), `Lit`, `Emissive` (cd/m2 added to the color) | a mesh (`Mesh`: quad that faces the camera, sphere, cube) with the emitter's `Material` (a `render3d_material` property like `visual_primitive`'s, edited like any material, white matte when unset), and `Spin` |
| lighting | the light of the scene computed per particle (sun with shadows, local lights, DDGI or the sky), or glowing | the gbuffer's: lit like a model, with fog, AO, TAA, motion vectors |
| `Collision` | `none`, `shelter_map`, `scene_depth`, `rays` | `none`, `rays` |
| shadows, bvh, GI | no | no (they do not cast shadows and are not in the bvh or DDGI) |
| code | `particle_emitter_gpu.lua` | `particle_emitter_cpu.lua` |

The gpu emitter is one particle system, `emitters`, for all of them: each gets a range of slots in a pool of 65536 (`MaxParticles` slots, at most 32 emitters), the cpu says how many slots of the range spawn this frame (a ring, so rates and bursts are exact) and the shader spawns, moves, collides (any mode, per emitter), lights and colors them. Changing `MaxParticles` frees the range and kills its particles. The cpu emitter simulates in lua over ffi arrays and queues every particle each frame for the gbuffer's instancing path (`gbuffer_instancing.Queue` from the `Draw3DGeometry` event) with its previous position as the previous matrix. Its rays are the scene's raycast, at most `RAY_BUDGET` 256 a frame over all emitters (a particle that gets none goes through that frame). A particle shrinks to `SizeEnd`, alpha is not drawn.

They do not run the same code, so a change to a shape or a force that should be in both has to be made in `particle_emitter_gpu.lua` (the glsl) and `particle_emitter_cpu.lua`; a way to turn a cpu emitter into a gpu one is not there yet. What the framework gained for the gpu one: a scheduled spawn (`should_spawn` in `Register`, a dead slot stays dead unless asked for), `shade` (what is drawn from the light), `collision = "per_particle"` with `collision_mode`, `UsesRays`, and a particle record of 80 bytes (`light` apart from `radiance`).

`addons/examples/lua/examples/render3d/particles_demo.lua` is a yard with a wall, a hut and a pillar under light rain and two emitters thrown at the wall: sparks (a `particle_emitter_gpu`, `Lit` off, `Emissive` 1e5) that cycle through the gpu collision modes every 6 seconds (`particles_demo_collision <mode>`, `PARTICLES_DEMO_CYCLE=0`), and debris (a `particle_emitter_cpu`, cubes, rays): with `rays` the sparks gather on the wall's face, with `shelter_map` they go through its side and only the ground stops them, `scene_depth` is the same as rays where the view sees. `test/harnesses/particles/sparks_shot.lua` takes a picture per mode. `test/tests/render3d/particles.lua` covers the ring spawn (rate, bursts, duration, wrapping, resizing), both gpu collision modes against a wall the cpu emitter (the count, the instances queued, rays against a wall) and that each type has only its own properties, with ray tracing on and off.

## Measuring and testing

- `test/tests/render3d/particles.lua`: the pool read back (`particles.Download(system)`) stays in the box, moves along its velocity from one step to the next, is lit; a lamp lights the flakes in front of it; nothing runs without precipitation. It passes with `GOLUWA_NO_RAY_TRACING=1` too (the pass uses no ray queries).
- `test/harnesses/particles/precip_scene.lua`: a yard with a hut (a roof, a door), a pillar and a lamp, `KIND=rain|snow`, `RATE`, `ELEVATION` (negative is night), `VIEWS=yard,hut,up,sun`, `OUT`; `inspect.lua` prints what is in a pool after a few seconds (visible count, radiance, speed, the bounds around the camera); `perf.lua` prints the gpu time of the passes with nothing, snow, rain and both falling. 131072 snow particles: `particles_simulate` 0.25 ms, each of the two draws 0.07 ms (inside `translucent_moments` and `translucent_accumulate`), 2026-10-16 on this machine at 1080p, no `--validate`.
- Checking lighting numbers: `inspect.lua` with `GI=0` (`r_pass_ddgi` off) and `GI=1` gave the same scale (the probes read 78% of the environment in the open yard), no factor of pi between them.

## Pitfalls found on the way

- `glsl_metadata.build_ffi_struct` did not count the padding it inserted before a field that needs more alignment than the offset has (a `uint64_t` array after a block of 4 byte fields), the C struct came out smaller than the glsl block and the block check failed ("GLSL expected size: 808, FFI actual size: 804"). Fixed in the non struct field branch, structs were right already. A `uint64_t` array in a block is fine now.
- A pass that reads a storage buffer from the vertex stage through its address needs the barrier by hand: compute to vertex after the dispatch and vertex to compute before it (the pass does both, see `particles_simulate`'s `on_draw`).
- `unpack(...)` in the middle of a block layout table only gives one field: nest the list (`light_occlusion.GetBlockLayout()` as an element, blocks are flattened).
