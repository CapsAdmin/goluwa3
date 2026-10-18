# Terrain streaming: what the Limcore Terrain project does and what was taken from it

`local_stuff/terrain/` is a C++/Vulkan terrain renderer (`Limcore` the framework, `Terrain` the demo, everything in `Terrain/sources/main.cpp` and `Terrain/shaders/`). `test/harnesses/terrain/limcore_scene.lua` is its terrain (height function, textures, slope and height rules) as a goluwa `Terrain` with a `ShaderSource`, at its scale (5 km of height, 100 km of terrain, `Levels = 9`). Take shots of it with the command in the file.

## How it works

- No meshes are streamed. Height is a function (15 octaves of value noise, each divided by `1 + dot(sum_of_derivatives, ...) * erosion`) baked into 8 nested 2048^2 heightmap cascades (cascade i covers `0.075 * 2^i` of 10 km, so 750 m to 96 km), texels packed as height in two 8 bit channels and the normal derivatives in the other two. `TerrainValues` takes the finest cascade that contains the position and all of vertex, tessellation, fragment, shadows and the cpu ground height (a one thread compute pass into a mapped buffer) use it.
- A cascade is re-baked when the camera is 1/8 of its span from its centre, one cascade at a time, in 16 tiles of 512^2 (one dispatch a frame) into a shared staging image and copied over the live one on the last tile, so the live one is never half written and the per frame cost is constant.
- Geometry is three static plane meshes instanced over a grid (5 km chunks), positions computed from `gl_InstanceIndex` in the vertex shader, detail from tessellation: the control shader culls patches (outside the frustum with the real height of the centre, facing away by the baked normal) and sets each edge's level from its own length and distance, so neighbours agree.
- The camera stays near the origin, whole 625 m steps are moved into a `terrainOffset` uniform.

## What was ported

- Bake the height function once and derive the rest from it (the cascades hold normals next to heights, nothing is re evaluated): `ShaderSource` field texture, see `docs/performance.md` "Flying over the island".
- Level aware octaves: an octave is dropped once its wavelength is under two samples of the bake (`terrain_bake_step()`), with the sum normalised by the full octave count so levels agree (`limcore_scene.lua`, `pn_fbm_lod` in `goluwa/terrain/noise.lua` is the same idea).
- Same topology, one buffer: tiles of a shape share an index buffer, like the instanced plane meshes share theirs.

## What was not, and why

- The clipmap with displacement in the vertex or tessellation stage. goluwa's tiles are real triangles because the scene bvh (gi, reflections, soup shadows), the height colliders and scatter (one job per triangle of a surface) read them. A displaced mesh would need every one of those to read the height texture instead.
- Re baking one big cascade in slices. The tile system builds a handful of small chunks a frame already (`BuildsPerFrame`), and a chunk keeps its own splat and color textures, which a cascade does not.
- Patch back face culling by the baked normal: tiles are culled by the gpu culling as a whole, and a patch is a quad of 64 x 64 samples, a tile of a level never faces fully away.
