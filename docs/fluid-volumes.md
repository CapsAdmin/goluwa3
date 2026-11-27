# Fluid volumes

Simulated or procedural gas in a box: smoke, fire, poison, steam, fog banks.

Sources: `goluwa/render3d/fluid_volumes.lua` (registry, grid state, simulation kernels, light bake, atlas, shared GLSL), `fluid_volume_passes.lua` (the simulate pass, run through `passes/fluid_volumes.lua` before `lighting` so lighting reads this frame's atlas, and the raymarch view pass, spliced into `passes/volumetric_fog.lua`), components `fluid_volume` and `fluid_emitter`. Example: `addons/examples/lua/examples/render3d/fluid_scene.lua` (`CAM=fire|poison|steam|overview|buttons`; it exposes helpers such as `fluid_scene.Puff()`, `Drop()`, `Explode(pos)` to poke the volumes). Tests: `test/tests/render3d/fluid_volumes.lua`.

## Model

- A volume is a uniform grid over its `Size` in the entity's local frame (`Resolution` cells along the longest side). Fields per cell: velocity (m/s) and `(smoke, temperature in kelvin, fuel, flame)`. `smoke` is the concentration of the volume's `Medium` (a `media.presets` name), `flame` is luminous soot.
- `Simulation = "fluid"` steps a stable fluids solver each frame: semi-Lagrangian advection (MacCormack for smoke), Boussinesq buoyancy, weight, turbulence forcing, emitters, vorticity confinement, then a pressure solve and projection. Box faces are open; `Floor` makes the bottom solid.
- Combustion: fuel above the ignition temperature burns, heats up to the flame temperature and becomes flame, which oxidizes into smoke. Every absorber emits `absorption * blackbody(T)` (Kirchhoff, `glsl_common.GetBlackbodyGLSL`), so hot smoke glows and cool gas does not. Emission is extremely steep in temperature, so sharpened temperature fields show as thin bright streaks.
- `Simulation = "procedural"` fills the grid from wind scrolled noise and shape properties (height falloff, edge softness, a core falloff from the centre to the faces or along the radius) with no solver: fog banks and large slow media. Procedural fluids also write an analytic optical volume record (`scene/ray_materials.lua`) so ray traced hits and light transmittance see them.
- `Obstacles` voxelizes the scene into the grid with ray queries periodically; without ray queries only `Floor` exists. `Pushers` rasterizes moving rigid bodies into the solid mask each frame as moving boundaries, so the pressure solve shoves gas aside and pulls a wake. Body velocity comes from interpolated position history, because kinematic character bodies have no solver velocity.
- Emitters (`fluid_emitter`) and splats (`fluid_volumes.Splat(pos, radius, {...})`) feed only the finest volume that contains their center, so overlapping volumes do not emit twice. A splat waits for a frame that steps.
- `Space = "world"`: the box is axis aligned and follows its entity in whole cell steps, shifting the contents back so the gas stays in the world and a moving emitter leaves a trail. `"local"` (default) carries the gas rigidly with the entity. Fast movers want particles or trails, not grids.
- Grid state is pooled by cell counts, so spawning reuses textures; `fluid_volumes.Prewarm(size, resolution, count)` fills the pool ahead of time. `fluid_volumes.Spawn{...}` splats into an existing transient world space volume or creates one, and transients are removed when their stats say they are spent.

## Lighting and rendering

- After stepping, a bake pass writes each volume into shared 3d atlases (stacked, sampled with clamped texel coordinates so filtering never crosses volumes): the fields, and optical depths toward the sun, the sky and up to a few local lights per volume, plus shadow map visibility. Optical depths are in concentration times meters, so spectral medium coefficients apply at render time and renderers only do lookups.
- `Raymarch = true` (small, near, detailed): `fluid_volumes_view` marches each pixel through the boxes and outputs pre-exposed scatter, depth and transmittance; the fog composite splits the froxel fog at that depth.
- `Raymarch = false` (large, coarse): the froxel passes sample the atlas, so it also fogs translucents and particles, at froxel resolution.
- Shadows: `fluid_sun_transmittance` and `fluid_local_light_transmittance` read the baked depth at the box entry point (one fetch per volume, no march). They shade opaque surfaces (`FLUID_SHADOWS` in `surface_lighting`), froxel fog and other raymarched volumes. Translucent surfaces, particles and water do not receive fluid shadows.
- `SunScattering` scales how much the sun scatters into a volume (not its shadowing), for imported fog that a game does not light with the sun. The sky/GI ambient always scatters: without it an albedo 1 medium reads as a black absorber.
- `EmitLight`: the bake sums the flame's emitted luminous intensity and temperature, and a hidden point light per volume follows it with a blackbody colour. Its brightness follows the flame physically; lower the flame temperature for a dimmer fire.
- `fluid_volumes.GetStats(volume)` reads back maxima, totals and mean height a few frames late. Use it in tests instead of pixels.

## Pitfalls

- Coarse grids have no subgrid entrainment, so full strength buoyancy shoots one cell thin jets; buoyancy defaults low and `Turbulence` stands in for the missing mixing.
- Fields are fp16; froxel mode clamps emission to stay finite, so prefer raymarch for fire.
- The model is gas only: liquids (a free surface) are not simulated, and simulated grids are not seen by DDGI or reflection rays.
