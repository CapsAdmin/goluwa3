# Tessellated height maps

A material with a height map and `HeightTessellate` (or every height mapped material with `r_tessellation_all`) is drawn as real displaced geometry instead of the parallax march. `goluwa/render3d/scene/tessellation.lua` owns it; it is a gbuffer extra with its own pipeline variant set (`gbuffer_tessellated`, registered in `passes/gbuffer.lua`).

## How it is drawn

- `bridge.set_raster` routes eligible rows to `tessellation.SetRow` and drops `RASTER_DRAW` for them. They keep `RASTER_SHADOW` and stay in the ray traced scene, both as the base mesh.
- Per mesh a topology buffer is built once on the CPU (keyed by mesh: static world batches re-upload theirs when decals change): per triangle the welded position id of each corner and, per edge, the vertex indices of the triangle on the other side (its uvs); per welded position the displacement direction (area weighted face normals), the uv scale (world size of one uv unit, so `HeightScale` means what it means for parallax) and the list of vertices that share it.
- Each frame two compute passes run in `PreDraw`: one copies world matrices from the instance tables (`draw.WORLD_FROM_GLSL`), one culls every base triangle against the frustum, gives each edge a power of two rate from its projected length (`r_tessellation_pixels`) and appends the triangle to the bucket of its largest rate. `Draw` is one `DrawIndirect` of the buckets; the vertex stage builds the lattice point from `gl_VertexIndex` and pulls everything from the mesh's own buffers. It outputs what the multi draw stage does; the fragment shader is the plain one with the parallax march removed and shades with the base normal plus the height derived normal.

## Terrain

- Terrain tiles with a shell (`TerrainShell`, the finest `ShellLevels`) are always tessellated when the path is available (`r_tessellation` and the `multiDrawIndirect` and `drawIndirectFirstInstance` device features, which the bucket draws need); coarser levels keep their flat path. They keep no polygon data, so the topology is read from the mesh's own CPU arrays; the shell's base copy (every corner `|tangent.w| > 1.5`) is skipped and skirt bottoms are not displaced, so skirts hang from the displaced edge.
- The relief is `terrain_shell_relief` at the base world point along the coarse terrain normal, the same function the shell march uses (`model_pipeline.TERRAIN_RELIEF_GLSL`, shared by the fragment shader and the vertex stage). It depends only on the world position, so vertices shared inside a tile match; tile borders are covered by the skirts.
- Terrain jobs draw with the `TERRAIN` feature variant, the rest with the plain one.

## Rules that keep it watertight

- An edge's rate is computed from its endpoints in welded id order, so both triangles get the same rate; vertices on an edge are snapped to that rate.
- Edge points are evaluated in welded id order (positions, directions, scales, uvs), so both sides produce the same bits.
- On a uv seam an edge point averages the height sampled on both sides' uvs (each side with its own lod from its uv length and the edge rate); a corner averages every uv of its welded position. Interior heights blend toward the seam average within `r_tessellation_seam_band`, so there is no wall along the seam.
- Displacement runs along the welded direction, never the vertex normal, so hard edges do not open.

## Pitfalls

- The relief rises out of the base surface (height times thickness, the midlevel is ignored). Shadow maps and rays only see the base mesh; relief sunk below it is covered by it and goes black in GI.
- Shadows and rays have no relief.
- Decals (`Decal`) are tessellated; their vertices are pulled toward the eye by the parallax path's decal depth bias, since the variant does not write fragment depth and zero relief would z-fight the surface below. Their height is multiplied by the albedo alpha so the relief fades out with the decal instead of leaving an invisible shelf at its dithered edge.
- Not tessellated: double sided, transparent and vertex animated materials, height shells, skinned polygons and LOD chains.
- A base triangle is cut at most 64 times per edge; coarse base meshes stay coarse up close.
