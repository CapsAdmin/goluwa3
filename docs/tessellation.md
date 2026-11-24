# Tessellated height maps

A material with a height map and `HeightTessellate` (or every height mapped material with `r_tessellation_all`) is drawn as real displaced geometry instead of the parallax march. `goluwa/render3d/scene/tessellation.lua` owns it; it is a gbuffer extra with its own pipeline variant set (`gbuffer_tessellated`, registered in `passes/gbuffer.lua`). `tessellation.IsEligible` decides which entries qualify. Test: `test/tests/render3d/tessellation.lua`.

## How it is drawn

- `bridge.set_raster` routes eligible rows to `tessellation.SetRow` and drops their `RASTER_DRAW`. They keep `RASTER_SHADOW` and stay in the ray traced scene as the base mesh.
- Per mesh a topology buffer is built once on the cpu: welded position ids per corner, edge neighbours, per welded position a displacement direction (area weighted face normals) and a uv scale (world size of one uv unit, so `HeightScale` means the same as for parallax).
- Each frame `PreDraw` runs compute passes that copy world matrices, cull base triangles against the frustum, give each edge a power of two rate and append triangles to buckets by their largest rate. `Draw` is one indirect draw per bucket; the vertex stage builds lattice points from `gl_VertexIndex` and pulls everything from the mesh's own buffers. The fragment stage is the plain one without the parallax march. With the visibility buffer on, tessellation draws ids and small patches can be rasterized in compute ([render3d-pipeline.md](render3d-pipeline.md)).

## Edge rates

- Rates are error driven and `r_cluster_lod_error` (`r_cluster_lod_rt_error` for the traced build) is the only knob, shared with [cluster-lod.md](cluster-lod.md). An edge whose relief projects to less than the error stays uncut; otherwise the cut spacing comes from a model of how relief amplitude falls with wavelength, bounded by the height texel size and the pixel error. `tess_edge_rate` holds the formula for both raster and ray tracing.
- The rate is capped per edge (`tessellation.MAX_LOG`), so coarse base meshes stay coarse up close.

## Terrain

- Terrain tiles with a shell (`TerrainShell`, the finest `ShellLevels`) are always tessellated when the path is available (`r_tessellation` and the `multiDrawIndirect` and `drawIndirectFirstInstance` device features). Their vertices are written on the gpu ([terrain-streaming.md](terrain-streaming.md)), so the topology comes from the tile template (`polygon3d.TopologySource`) and is shared by every tile; only heights differ on a tile grid. The shell's base copy is skipped and skirt bottoms are not displaced, so skirts hang from the displaced edge.
- The relief is `terrain_shell_relief`, shared with the shell march (`model_pipeline.TERRAIN_RELIEF_GLSL`). It depends only on world position, so shared vertices match.

## Rules that keep it watertight

- An edge's rate and its points are computed from its endpoints in welded id order, so both triangles produce the same rate and the same bits; vertices on an edge snap to that rate.
- On a uv seam an edge point averages the heights sampled on both sides' uvs, a corner averages every uv of its welded position, and interior heights blend toward the seam average within `r_tessellation_seam_band`.
- Displacement runs along the welded direction, never the vertex normal, so hard edges do not open.

## Ray tracing

- With `VK_NV_cluster_acceleration_structure` (`r_tessellation_rt`), tessellated models within `r_tessellation_rt_distance` are traced with their relief: `tessellation_rt_select` picks distance based rates (a lower cap than raster, so a patch fits one cluster), `tessellation_rt_vertices` evaluates the lattice with the same `tess_evaluate` the raster uses, and one cluster acceleration structure per patch builds one BLAS per model. The patch budget is fixed; models that do not fit keep their base mesh.
- Cluster ids of tessellated patches have the top bit set; `scene_hit_row` routes those hits to `meshes.TESSELLATION_ROW`, which describes the per frame vertex and index buffers.
- `tessellation.BuildRT` (from `instances.Build`) runs before the raster draw in a frame, so it refreshes the shared batch table itself; otherwise a grown job list reads batch records past the end.

## Limits

- The relief rises out of the base surface (midlevel ignored). Shadow maps always see the base mesh, rays only see relief within `r_tessellation_rt_distance` with the cluster extension, so relief sunk below the base would be hidden in shadows and GI.
- Decals are tessellated; they are biased toward the eye like parallax decals since the variant does not write fragment depth, and their height fades with albedo alpha.
- Not tessellated: double sided, transparent and vertex animated materials, height shells, skinned polygons and LOD chains.
