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

## How layers are chosen and blended

The weight texture of a tile (`SplatSize` texels, baked by the source's `terrain_splat`) says where a layer is allowed. A texel covers more ground the coarser the tile, so a slope taken from it differs between levels (rock above 50% on 8.6% of the same ground in level 0 tiles and on 2.2% in the level 3 tile that covers it). Per layer values (`tiles.CreateMaterial`, `layer.<key>`, vec4 per four layers like the other `TerrainLayer*` values) decide the rest at the pixel:

- `slope_min`, `slope_max`, `slope_blend`: steepness is `1 - (normal.y * 0.5 + 0.5)` of the detail normal map, a layer's weight is multiplied by 0 outside of the range and fades over the blend (defaults: everywhere). Put the slope rule here instead of in `terrain_splat` and the weights only carry what the slope cannot (height, noise, trails). Scatter applies the same rules (`goluwa/render3d/terrain_layer_rules.lua` is the GLSL both include) to the weights of the first four layers with the ground normal and height at the point it looks at, so what grows on a layer is where the layer shows (scatter has the mesh normal, the surface the normal map, they differ a little at an edge). `LIMCORE_SCATTER = true` in front of `limcore_scene.lua` grows the builtin grass on its grass layer to look at it.
- `height_blend` (0 to 1): the layer's weight is scaled by `height * 2` of its height texture, a transition follows the grain of the layers instead of being a gradient (the layers need a height texture).
- `far_scale`, `far_distance`: a second scale (meters per repeat like `scale`) the layer fades to from half of `far_distance` to it, against repeats showing from far away. Limcore does this with four scales for its rock.
- `far_scale_b`, `far_distance_b`: a third scale after the second, same fade. Limcore's rock cross fades four scales by distance (5, 20, 200 and 1000 m per repeat, at 25, 150 and 2500 m).
- `fade_distance`: the layer fades to its average color (the smallest mip) from half of it and is not sampled past it, normal map included. Limcore does this to its grass at 75 to 100 m. 0 for never. The average is the last mip, so the layer's textures need mips (`mip_map_levels = "auto"` in the asset config): `assets.GetTexture` of a jpg has one level without it, `detail_strength` has the same need, and the "average" is then the texel at the middle of the texture (a brown one on Limcore's grass, and the terrain shimmers at a distance).
- `anti_tiling` (0 to 1): the layer is also sampled turned 37 degrees and shifted, and the two are swapped between by noise that changes over a few repeats (mostly one or the other with a short fade, normals turned back). Costs a second fetch of the albedo and the normal per projection. Limcore has nothing like it.
- `TriplanarSharpness` on the source (`ShaderSource.New{TriplanarSharpness = n}`, default 4): the exponent of the triplanar weights. Limcore uses 72, so on a slope one projection shows and not two overlapping copies of the texture.
- `cover_slope`, `cover_start`, `cover_range`, `cover_power`, `cover_blend`: a covering layer (snow) is laid over the others instead of mixed in by its weight (its baked weight is ignored). It covers the ground flatter than `cover_slope * ((y - cover_start) / cover_range) ^ cover_power`, fading over `cover_blend`, so the higher it is the steeper the snow holds. A `cover_slope` of 0 is a normal layer. Where it covers, the other layers' weights are scaled by what is left.

`test/harnesses/terrain/limcore_scene.lua` uses all of them for Limcore's rules (its snow is `cover_slope` 0.3, start -1250, range 1500, power 0.75).
