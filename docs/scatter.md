# Scatter

Models (grass, flowers, rocks, bushes, trees) grown over surfaces on the gpu.

- `goluwa/render3d/scatter_set.lua`: sets are property objects like materials. Its header lists every key of a prototype's rules; unknown keys are errors.
- `goluwa/render3d/scatter.lua`: baking placements and the per-frame cull.
- Drawing and ray traced presence are the scene's draw streams (see [gpu-scene.md](gpu-scene.md)).
- Presets: `addons/game/lua/autorun/render_3d/scatter_presets.lua` (Crysis classes, empty without Crysis installed) and `addons/foliage/lua/foliage/scatter_sets.lua` (procedural, see [foliage.md](foliage.md)). `ScatterSet.GetGrass()` is a builtin set that needs no assets.

## How it fits together

- A material says what grows on it with `ScatterSet` and `ScatterDensity`; terrain uses `TerrainLayerScatter` per layer and a prototype's `layers` picks from them. `ScatterSet.New{Name, Prototypes}` makes a set, `ScatterSet.AddFactory(name, create)` registers one built on first `ScatterSet.Get(name)`, `set:Use()` loads its models. `DensityMultiplier` and `DistanceMultiplier` scale a set live.
- **Baking**: what a surface grows is baked per *unit* (a cell of a surface, split finer near the camera) and kept. Units are baked a few per frame, ordered by `goluwa/render3d/view_priority.lua` (shared with terrain), by compute passes `scatter_tiles` (jobs per triangle and prototype) and `scatter_instances` (hash, jitter, thin, rule tests, optional cover ray query), writing matrices into the unit's room in a `buddy_pool.lua` pool. A unit is re-baked when the camera enters a nearer distance band or when its set, multipliers, surface or density change.
- **Per frame**: `scatter_cull` (on `PreSceneBuild`) thins by exact distance, picks the model, mid or billboard tier and appends instances to that tier's draw stream (view list with a dither fade, and a shadow list for `shadow` prototypes). The scene cull then handles them like any other scene row.
- **Placement is deterministic**: a cell's hash decides jitter, priority and all randomness, and priority against the density at the camera's distance decides whether an instance exists, so nothing moves or flickers as the camera does.
- **Tiers**: `billboard = {distance, fade}` asks `render3d/billboard.lua` for a baked billboard; `lod = {distance, fade}` adds a mid tier from the model's coarsest mesh LOD (a hidden companion prototype that is never baked). Tiers dither-crossfade. Pvars: `r_scatter_billboards`, `r_scatter_billboard_distance`, `r_scatter_lod`.
- **Slopes**: `align` stands a model on the ground normal. `conform = true` measures the ground under the footprint with ray queries at bake time and fits a plane into the instance matrix, so rasters, shadows and rays all see the tilt. It needs the ground in the ray traced scene when the unit bakes.
- **Ray traced scene**: prototypes with `shadow` and `bvh` are traced through the stream rows (`r_rt_streams`, `r_rt_stream_distance`). `bvh = false` / `shadow = false` keep a prototype out of rays / shadow maps.
- **Rooms**: each stream's room follows what the gpu counted (`scene_draw.GetStreamDemand`). `scatter.GetPoolStatus()` shows where the bake pool went; check it before assuming it is full.

## Placed instances

Prototypes with `placed = true` have no placement rules; they stand where they were put (a level's painted vegetation, earth objects) and go through the same cull, tiers, shadows, conform and ray traced scene. `scatter.AddPlacements(proto, matrices, count)` returns a handle for `RemovePlacements` / `SetPlacementsHidden`. The `scatter_placements` component (`goluwa/entities/components/scatter_placements.lua`) is the normal way to use it; its records are a hidden property, and the editor's scatter brush (`addons/editor/lua/terrain_editor.lua`) paints and erases them on any surface. Placed instances are conformed again periodically, so ground that streams in later is found.

## Pitfalls

- Models need an index buffer (the multi draw pulls vertices through the index pool). Meshes from `shapes.Build*` must be uploaded with indices. LOD 0 is the model and the coarsest LOD level is the optional mid tier; other levels are ignored.
- `bending` sets `Bending` on the model's materials, which are shared with every other use of that model.
- Shadow lists are not cut by the camera frustum; shadow maps are recorded before the frame's cull and draw what the last frame appended.
- Thinning, tiers and tile jobs come from the main camera; a second view sees the main camera's instances.
- Jobs past `MAX_JOBS` are dropped: if a big scene loses chunks, check the job count.
- The tile pass box must be grown by the instance radius, or tree crowns whose root is out of view are lost. The cover ray is only used on surfaces without a layer mask (overlapping LOD tiles would hit each other).
- A surface must be in `Visual.Library.GetSceneMaterialUsers()` to grow anything; check that before reading shaders.
- Dither fade comes only from distance thinning; fading by density turns bushes into ghosts. Prefer a cluster `amount` over a low `density` for patches.
- Terrain tiles hand over only once replacements' vegetation is baked (`scatter.Preload`, `IsSurfaceReady`, `Terrain:IsTileReplaced`); `SetRetiring` deprioritizes tiles about to go.
- Data the gpu reads that the cpu rewrites every frame (the prototype buffer) is recorded into the command buffer (`cmd:UpdateBuffer`), never written to a host visible buffer that an in-flight frame may still be reading.
- Ray traced stream rows are only valid in the frame they were written, so the cull runs on `PreSceneBuild` and calls `scene_draw.EndStreams` after appending.
- Tests need unique set names and mesh sizes (meshes with identical vertices are shared and may be on their way out).

## Measuring

The cost of scatter is mostly drawing (triangle volume), not baking. Count what a view submits with `scene_draw.ReadBackCull(0)` (`triangles`, `streamed`, `by_group`) before guessing, and reduce it with density, distance, earlier billboards or a `lod`. Compare `gpu_frame` with the frame time before blaming the gpu. When flying, hold a constant altitude (altitude changes rebake the atmosphere LUT). See [performance.md](performance.md).

## Verifying

`test/tests/render3d/scatter.lua`. Examples under `addons/examples/lua/examples/render3d/`: `scatter_showcase.lua`, `island_terrain.lua`, `foliage_world.lua`. Wait for `scatter.pending_bakes` to reach 0 before measuring. `glw bench scatter_meadow` (with `SCATTER_OFF=1` as baseline).
