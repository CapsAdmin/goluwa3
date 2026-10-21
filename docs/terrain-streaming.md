# Terrain

`goluwa/terrain/` builds terrain as streamed tiles of real triangles from a height `Source` (`source.lua`, `shader_source.lua`: a glsl field baked once per tile, with normals, splat weights and color derived from it). `terrain.lua` is the tile manager, `tiles.lua` builds tile meshes and materials, `height_physics.lua`/`physics.lua` give colliders. `local_stuff/terrain/` holds the C++/Vulkan Limcore Terrain project used as a reference (a heightmap clipmap displaced by tessellation) and a goluwa port of its scene (`limcore_scene.lua`).

## Tile streaming

- `Terrain` has `Levels` (LOD rings) and `GridSize` (chunks per side of a level; the finer level fills the middle half, so the ring is `GridSize / 4` chunks thick; it must be at least 4, because the two levels snap differently). Reach is `GridSize * 64 * 2^(Levels-2)` m across; layout changes cost tiles, triangles, memory and load time but not gpu frame time.
- A tile is kept until its replacements are built (`IsTileReplaced`), then the replacements are shown and the old tile is removed once the culling that is drawn was dispatched after they were shown (`AreReplacementsDrawn`, `gpu_culling.GetDrawnCullFrame`, so `draw.Draw` must call `MarkMainViewDrawn`). A fixed delay is both too short (holes) and too long (z-fighting overlap). When a replacement has a scatter set it also waits for its vegetation to be baked (see [scatter.md](scatter.md)).
- Removed tiles' chunk textures are released `ReleaseFrames` later (`PendingReleases`, at most `ReleasesPerFrame` a frame): the bindless array swaps a released texture for the fallback and reuses its index, so releasing early shows another chunk's texture. Bake textures are pooled by size and format (`RecycleTexture`).
- Build order is `goluwa/render3d/view_priority.lua` (shared with scatter): tiles with nothing drawn under them come before tiles that only refine; inside that, the nearer of the camera now and where it will be in 0.5 s to the tile's box, times `1 + OutsidePenalty * (how far outside the view)`. It must be a multiplier, not an offset, or tiles under a moving camera starve. The build queue is worked every frame (`BuildsPerFrame`) and re-prioritised each update; replacements of one retiring tile share their best member's priority so they appear together.
- Ray traced presence is throttled: `InSceneBVH` per visual, `BVHLevels` (finest levels in the scene), `BVHDelay` (a tile enters only after being wanted that long, since fast flight makes tiles that are gone before they are used) and `BVHPerFrame`. Flying fast and jumping make hundreds of tiles due at once; any per-frame work over all of them must be budgeted.
- Per-frame scans over all tiles must use cached tile bounds and per-level grids (`GatherOverlappingDesired`), not recompute levels or compare every retiring tile with every desired one.
- Debug: the `terrain_tiles` command (`Terrain:GetDebugReport()`) lists counts and tiles that should be drawn but are hidden; the TERRAIN tab of the PERF window (`terrain_stats`). `addons/examples/lua/examples/render3d/terrain_debug.lua` is a bare rolling terrain with a hue per level; oblique views only (top-down from high looks grey).

## Layers

The weight texture of a tile (`SplatSize` texels, baked by the source's `terrain_splat`) says where a layer is allowed; a texel covers more ground on coarser tiles, so slopes taken from it differ between levels. Per layer values (`tiles.CreateMaterial`, `layer.<key>`, vec4 per four layers) decide the rest at the pixel:

- `slope_min`, `slope_max`, `slope_blend`: steepness from the detail normal; put slope rules here rather than in the splat. Scatter applies the same rules (`goluwa/render3d/terrain_layer_rules.lua` is the glsl both include), so what grows on a layer is where the layer shows.
- `height_blend`: scales the weight by the layer's height texture so transitions follow the grain.
- `far_scale`/`far_distance`, `far_scale_b`/`far_distance_b`: extra texture scales the layer fades to with distance, against visible repeats.
- `fade_distance`: fade to the layer's average color (the smallest mip, so the layer's textures need mips: `mip_map_levels = "auto"`; `detail_strength` has the same need).
- `anti_tiling`: samples a rotated and shifted copy and mixes by noise; costs a second fetch.
- `TriplanarSharpness` on the source: exponent of the triplanar weights.
- `cover_slope`, `cover_start`, `cover_range`, `cover_power`, `cover_blend`: a covering layer (snow) laid over the others, covering ground flatter than a slope that grows with height.

## What the Limcore reference does that tiles do not

Limcore bakes a height function into nested heightmap cascades re-baked incrementally around the camera, and displaces instanced planes in the vertex/tessellation stage. Tiles here are real triangles because the ray traced scene, height colliders and scatter (one job per triangle) read them; a displaced mesh would need each of those to read the height texture. Ported from it: bake the height function once and derive the rest from it, level aware octave dropping (`pn_fbm_lod` in `goluwa/terrain/noise.lua`), and sharing one index buffer between tiles of a shape.

## Verifying

`test/tests/render3d/terrain.lua` and `terrain_streaming.lua`. For streaming changes fly a terrain scene fast with periodic teleports and look at frame times of the terrain stages and at per-frame coverage (count drawn tiles covering points ahead of the camera: 0 is a hole, 2+ an overlap). Long frames after a jump usually come from many tiles becoming due at once.
