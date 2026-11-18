# Tessellated height maps

A material with a height map and `HeightTessellate` (or every height mapped material with `r_tessellation_all`) is drawn as real displaced geometry instead of the parallax march. `goluwa/render3d/scene/tessellation.lua` owns it; it is a gbuffer extra with its own pipeline variant set (`gbuffer_tessellated`, registered in `passes/gbuffer.lua`).

## How it is drawn

- `bridge.set_raster` routes eligible rows to `tessellation.SetRow` and drops `RASTER_DRAW` for them. They keep `RASTER_SHADOW` and stay in the ray traced scene, both as the base mesh.
- Per mesh a topology buffer is built once on the CPU (keyed by mesh: static world batches re-upload theirs when decals change): per triangle the welded position id of each corner and, per edge, the vertex indices of the triangle on the other side (its uvs); per welded position the displacement direction (area weighted face normals), the uv scale (world size of one uv unit, so `HeightScale` means what it means for parallax) and the list of vertices that share it.
- Each frame two compute passes run in `PreDraw`: one copies world matrices from the instance tables (`draw.WORLD_FROM_GLSL`), one culls every base triangle against the frustum, gives each edge a power of two rate from its screen space error (see below) and appends the triangle to the bucket of its largest rate. `Draw` is one `DrawIndirect` of the buckets; the vertex stage builds the lattice point from `gl_VertexIndex` and pulls everything from the mesh's own buffers. It outputs what the multi draw stage does; the fragment shader is the plain one with the parallax march removed and shades with the base normal plus the height derived normal.

## Edge rates

- The rate is error driven and `r_cluster_lod_error` (`r_cluster_lod_rt_error` for the traced build) is the only knob, shared with cluster LOD. An edge whose relief (`height_scale` times the uv scale, or `TerrainShell`) projects to no more than the error stays uncut, so relief that cannot move a pixel costs nothing. Otherwise relief amplitude is assumed to shrink with the square root of its wavelength (rough natural surfaces; a linear falloff flattened close up relief visibly): a cut every `uv_size * (error / relief_pixels)^2` (one uv repeat of the height map, for terrain the layer with the largest relief) keeps the error under the threshold. Cuts never go below one height texel or below `error` pixels on screen, and at most 64 (8 traced) per edge.
- `tess_edge_rate` holds the formula for both passes; its inputs come from the job (`uv_size`, `texel`) and the welded position's scale, taken symmetrically over the edge's endpoints so both triangles agree.

## Terrain

- Terrain tiles with a shell (`TerrainShell`, the finest `ShellLevels`) are always tessellated when the path is available (`r_tessellation` and the `multiDrawIndirect` and `drawIndirectFirstInstance` device features, which the bucket draws need); coarser levels keep their flat path. They keep no polygon data, so the topology is read from the mesh's own CPU arrays; the shell's base copy (every corner `|tangent.w| > 1.5`) is skipped and skirt bottoms are not displaced, so skirts hang from the displaced edge.
- The relief is `terrain_shell_relief` at the base world point along the coarse terrain normal, the same function the shell march uses (`model_pipeline.TERRAIN_RELIEF_GLSL`, shared by the fragment shader and the vertex stage). It depends only on the world position, so vertices shared inside a tile match; tile borders are covered by the skirts.
- Terrain jobs draw with the `TERRAIN` feature variant, the rest with the plain one.

## Rules that keep it watertight

- An edge's rate is computed from its endpoints in welded id order, so both triangles get the same rate; vertices on an edge are snapped to that rate.
- Edge points are evaluated in welded id order (positions, directions, scales, uvs), so both sides produce the same bits.
- On a uv seam an edge point averages the height sampled on both sides' uvs (each side with its own lod from its uv length and the edge rate); a corner averages every uv of its welded position. Interior heights blend toward the seam average within `r_tessellation_seam_band`, so there is no wall along the seam.
- Displacement runs along the welded direction, never the vertex normal, so hard edges do not open.

## Ray tracing

- With `VK_NV_cluster_acceleration_structure` (`r_tessellation_rt`), tessellated models within `r_tessellation_rt_distance` of the camera are traced with their relief. Each frame `tessellation_rt_select` gives every base triangle distance based edge rates (`r_cluster_lod_rt_error`, at most 8 per edge, so a patch is one cluster of at most 64 triangles and 45 vertices), `tessellation_rt_vertices` evaluates the lattice with the same `tess_evaluate` the raster vertex stage uses and writes core and extras vertices and global indices, one cluster acceleration structure per patch is built against a static index template per rate, and one BLAS per model from its patches. Budgets are fixed (32768 patches a frame); models that do not fit keep their base mesh.
- Cluster ids of tessellated patches have the top bit set; `scene_hit_row` routes those hits to mesh row 0 (`meshes.TESSELLATION_ROW`), which describes the per frame vertex and index buffers.
- Shadow maps still draw the base mesh.
- The ray traced build (`tessellation.BuildRT`, from `instances.Build`) runs before the raster draw in a frame, so it refreshes the shared batch table itself: a job list that grew since the last draw would otherwise read batch records past the end (null vertex and extras addresses, device lost while terrain tiles stream in).

## Pitfalls

- The relief rises out of the base surface (height times thickness, the midlevel is ignored). Shadow maps and rays only see the base mesh; relief sunk below it is covered by it and goes black in GI.
- Shadow maps have no relief; rays only have it within `r_tessellation_rt_distance` and with the cluster extension.
- Decals (`Decal`) are tessellated; their vertices are pulled toward the eye by the parallax path's decal depth bias, since the variant does not write fragment depth and zero relief would z-fight the surface below. Their height is multiplied by the albedo alpha so the relief fades out with the decal instead of leaving an invisible shelf at its dithered edge.
- Not tessellated: double sided, transparent and vertex animated materials, height shells, skinned polygons and LOD chains.
- A base triangle is cut at most 64 times per edge; coarse base meshes stay coarse up close.
