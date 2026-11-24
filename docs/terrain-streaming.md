# Terrain

`goluwa/terrain/` builds terrain as streamed tiles of real triangles from a height `Source`:

- `source.lua`, `shader_source.lua`: a source whose glsl height field is baked once per chunk on the gpu; normals, splat weights and color are derived from that bake.
- `heightmap_source.lua`: a source made from data (heights, a color map, a per-cell layer id map, detail layers). `heightmap_file.lua` saves and loads that data as a directory.
- `terrain.lua`: the tile manager (LOD rings, build queue, handover, ray traced presence). `tiles.lua` builds tile meshes and materials. `height_physics.lua`/`physics.lua` give colliders.
- `noise.lua` (`pn_fbm_lod`: level aware octave dropping), `layer_texture.lua`/`layer_textures.lua` (layer textures).
- The `terrain` component (`goluwa/entities/components/terrain.lua`) owns heightmap data: `SetData(data)` or `Path` (a saved directory).

`local_stuff/terrain/` (git-ignored) holds the external Limcore Terrain project (a heightmap clipmap displaced by tessellation) used as a reference. Tiles here are real triangles instead because the ray traced scene, height colliders and scatter (one job per triangle) read them; a displaced mesh would need each of those to read the height texture. Ideas taken from it: bake the height function once and derive everything else from it, level aware octave dropping, one shared index buffer per tile shape.

## Terrain from maps

- The terrain manager has no extent: tiles stream around the camera forever, and a finite map is a source whose answer outside its data is its `outside` policy.
- `HeightmapSource.SampleHeight(data, x, z)` is the same height on the cpu (the static world's `TerrainHeight` for roads, decals, foliage, the editor).
- `crysis_loader/terrain.lua` only translates a Crysis level into heightmap data (`Translate`) and adds the component (`SpawnTerrain`). See [crysis.md](crysis.md).
- Put the component on the static world's entity rather than on an extra child. `static_world.Find` starts at the parent; an entity's own static world is `entity.static_world`.
- The color map must be ready before the first tile bakes from it.

## Editable terrain

A `terrain` component with an empty `Path` owns its data as properties (size, resolution, height range, up to four registered layers from `terrain.RegisterLayer`, a scatter set, and the height and layer maps as hidden binary strings), so the scene file, undo, clone and load handle it like any property. It is centered on the world origin whatever its entity's transform. `IsEditable()` tells the two kinds apart.

- Edits change the sample arrays and call `UpdateRegion(box)`, which re-uploads the maps and has `Terrain:Invalidate` rebake tiles and colliders over the box under a new generation; `CommitMaps()` writes the samples back to the properties.
- With at most four layer ids, a layer id is always the same material slot, so scatter `layers` weights mean the same layer in every chunk.
- The editor brush is `addons/editor/lua/terrain_editor.lua` (raise, lower, smooth, flatten, paint; one stroke is one undo entry). It also paints `scatter_placements`.

## Tile streaming

- `Levels` (LOD rings) and `GridSize` (chunks per side of a level; the finer level fills the middle half) set the layout. Layout changes cost tiles, memory and load time, not gpu frame time.
- A tile is kept until its replacements are built and drawn: the old one is removed only once a culling dispatched after the replacements were shown has been drawn (`IsTileReplaced`, `AreReplacementsDrawn`, `gpu_culling.GetDrawnCullFrame`; `draw.Draw` must call `MarkMainViewDrawn`). A fixed delay gives either holes or z-fighting. With a scatter set it also waits for vegetation (see [scatter.md](scatter.md)).
- Released chunk textures go out a few frames later (`ReleaseFrames`), because the bindless array reuses a released index at once and an early release shows another chunk's texture. Bake textures are pooled (`RecycleTexture`).
- Build order is `goluwa/render3d/view_priority.lua`, shared with scatter: uncovered tiles before refinements, then distance to the current and predicted camera, scaled by how far outside the view. The out-of-view penalty must be a multiplier, not an offset, or tiles under a moving camera starve.
- Fast flight and teleports make hundreds of tiles due at once; any per-frame work over tiles must be budgeted (`BuildsPerFrame`, `BVHPerFrame`) and use cached bounds and per-level grids rather than all-pairs comparisons.
- Ray traced presence is throttled per level and delay (`BVHLevels`, `BVHDelay`); ray traced copies are coarser (`BVHStride`).
- Shader sources write visual tile vertices on the gpu (`tiles.RecordGpuMesh`) into a buffer the chunk owns; the cpu still reads back heights for physics and bounds. Tiles use that buffer only after the cpu has seen the bake batch's fence.
- A tile's splat, color and normal textures are at least as fine as its mesh on every level: a camera looking straight down sees far rings without foreshortening.

## Planet curvature

Sources work in local height (above the planet datum: `HeightGLSL`, map samples, `HeightmapSource.SampleLocalHeight`). Baked heights, meshes, colliders and `SampleHeight` are world y, the local height minus `planet.GetDrop(x, z)` (see [render3d-lighting.md](render3d-lighting.md), Planet). Splat and color bakes get the local height back.

## Height functions of a shader source

`terrain_bake_step()` is the spacing of the texture being baked and differs between the mesh bake and the finer normal, splat and color bakes of the same tile. Anything that changes the height itself by level must use `terrain_tile_step()` (the mesh spacing, the same in every bake of a tile), or mesh, normals and splat disagree. Patterns finer than a few mesh samples alias, so procedural patterns should coarsen with `terrain_tile_step()`.

## Layers

The splat texture says where a layer is allowed; per layer values in `tiles.CreateMaterial` decide the rest per pixel: slope rules, height blending, parallax or shell relief, distance scales and fades, anti-tiling and a covering layer (snow). Read `tiles.lua` and `goluwa/render3d/features/terrain.lua` for the full list.

- Put slope rules in the layer values, not in the splat. Scatter includes the same glsl (`goluwa/render3d/terrain_layer_rules.lua`), so what grows on a layer is where the layer shows.
- Distance fades sample the smallest mip, so layer textures need mips.
- The finest `ShellLevels` levels use a height shell (`TerrainShell`, the chunk height as `TerrainHeightTexture`) and the shared shell march (see [render3d-pipeline.md](render3d-pipeline.md)). The shell measures height above the tile's own triangles (same diagonal as the mesh), not a bilinear sample, or rays on steep curved cells start above the shell. The chunk height texture has a one sample border so a ray leaving one tile resolves in the neighbour instead of a seam. Layer textures are sampled at the ray's foot point on the ground, not at the hit.

## Earth (`addons/earth`)

`lua/earth/earth.lua` streams the real Earth as terrain: `earth.Start{lat, lon, ...}` with optional features (clouds, buildings, water, land cover, roads, canopy, objects, weather). Example: `addons/examples/lua/examples/render3d/earth_real.lua` (`EARTH_LAT`/`EARTH_LON`).

- Frame: the origin stands on the anchor lat/lon, +x east, -z north; world x, z map onto the sphere below the tangent plane (`planet.GetDrop`, `geo.lua`). Heights are above sea level.
- `source.lua` (`EarthSource`) is a shader source whose chunks get extra per chunk textures (a world to web mercator map computed in doubles on the cpu, since float32 cannot hold mercator pixels at deep zooms; height and imagery mosaics; feature grids). Chunks wait for their tiles and fall back to coarser zooms; the terrain marks unwanted requests `request.cancelled`.
- `tile_set.lua` downloads (disk cache under `storage/cache/earth/`), decodes on the thread pool and keeps an LRU. Heights come from Mapterhorn pmtiles (`mapterhorn.lua`, `pmtiles_archive.lua`), imagery from a chain of sources (`imagery_sources.lua`).
- Feature modules: `buildings.lua`/`building_mesh.lua`, `water_bodies.lua`/`water_grid.lua`, `land_grid.lua`, `road_grid.lua`, `canopy_tiles.lua`, `objects.lua` and friends, `cloud_cover.lua`, `weather_feed.lua`. Overture data goes through `overture_tiles.lua` and `tile_grids.lua`; meshes are built on the thread pool from heights the main thread samples. Data that arrives after a chunk baked calls `Terrain:Invalidate` on its area.
- `earth.Recenter(lat, lon)` moves the origin: the old terrain is frozen (`Terrain:Freeze`) and drawn rigidly moved until the new one has loaded; listeners follow through the `EarthRecenter` event.
- `png.DecodeBuffer` writes rows bottom up; jpg and webp decode top down.

## Verifying

- Tests: `test/tests/render3d/terrain.lua`, `terrain_streaming.lua`, `heightmap_file.lua`.
- `terrain_tiles` command (`Terrain:GetDebugReport()`) lists counts and tiles that should be drawn but are hidden; the TERRAIN tab of the PERF window (`addons/debug/.../terrain_stats.lua`).
- `addons/examples/lua/examples/render3d/terrain_debug.lua`: bare rolling terrain with a hue per level (use oblique views).
- For streaming changes, fly fast with periodic teleports and check terrain stage frame times and per-frame coverage (count drawn tiles covering points ahead of the camera: 0 is a hole, 2+ an overlap).
