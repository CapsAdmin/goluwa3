# Procedural foliage

Trees, grass, rocks, flowers, bushes, ferns, mushrooms, logs and litter, made in Lua from a seed and a config, with textures drawn on the gpu. Nothing needs to be installed. Addon: `addons/foliage/`; modules in `lua/foliage/`, registered as assets at startup by `lua/autorun/render_3d/foliage.lua` (nothing is built until loaded).

## How it fits together

- `foliage.lua` is the registry. A generator (`AddGenerator(name, {category, defaults, build})`) makes one kind of thing from a config; `foliage.Build(name, config)` returns parts `{mesh, material}` and caches per config. A config only holds keys that differ from the defaults; unknown keys are errors. `AddPreset` registers a model asset `models/foliage/<category>/<preset>.lua`; `RegisterModel` adds more.
- **Model assets** are `procedural_model` descriptors loaded through `assets.GetModel`/`model_loader.LoadModel`, so the paths work wherever a model path does (visuals, the model component, scatter prototypes, billboards).
- **Reproducible**: all randomness comes from `random.lua` (exact 32 bit hashing). A part of an asset takes a named fork (`rng:Fork("leaves")`) so adding a draw to one part does not move the others. Texture glsl uses integer hashes, never `fract(sin())`, so every gpu draws the same picture.
- **Materials and textures**: `materials.lua` lists every material (`AddMaterial`; each needs albedo, normal and roughness). `textures.lua` kinds are glsl defining `Surface surface_at(vec2 uv)`; config keys are shader constants, so a config is a shader compiled once and cached. A request's config merges over the registered one (`assets.GetTexture(path, {config = {...}})`).
- **Cutouts** (leaves, needles, fronds, heads) are painted premultiplied and made into textures by `goluwa/render/cutout_texture.lua`: colours are dilated into clear texels and every mip keeps the alpha-test coverage of mip 0 so cards do not thin out. Billboards bake through the same code.
- **Storage**: every foliage texture is block compressed (see [texture-compression.md](texture-compression.md)) and cached as dds under `storage/cache/foliage_textures/`, keyed by a hash of the glsl, the channel and the generating sources. Compression matters for alpha tested passes, which fetch albedo alpha per fragment. Cutout mips are the coverage preserving ones, encoded level by level (`texture_compress.CompressLevels`). A compressed texture cannot be `Download`ed; `textures.BuildData` returns the dds for tests.
- **Meshes** (`mesh_builder.lua`) are written in the packed vertex layout. Give triangles counter clockwise from the side the normal faces; the builder converts to the engine winding.
- **Light through leaves**: leaf-like materials set `DiffuseTransmission` and related keys; leaf materials set `BentNormals`.

## Generators

- `trees.lua`: a Weber and Penn style branching engine (`BuildTree`), leaf cards with normals bent away from the trunk so the crown shades as one shape; species and `BuildPalm`. Pine sprays need a crossed second card or they vanish edge on.
- **LOD**: tree species can build a coarse model for the same seed. Growth consumes the random stream identically, so the silhouette matches; only the output is thinned. `foliage.RegisterModel` appends it as `LODLevel` 1 polygons, read by scatter's `lod` and the scene's visual LOD. Rocks carry their own LOD 1.
- `grass.lua`, `rocks.lua` (uv is a cube face atlas shared with the `rock` texture kind; `FACES` in `rocks.lua` must match `face_direction` in the texture glsl), `plants.lua`, `scatter_sets.lua` (`foliage_meadow/forest/tropical/rocky/wetland`, `Combine` for other terrain layers).

## Wind

- Bending is shared engine code in `goluwa/render3d/deformation.lua`. Parts of a model share `BendHeight`; materials set `Bending` and `DetailBending`. Vertex colour: r flutter, g phase, b stiffness (1 rigid). Main bending sways the model about its root; detail bending moves vertices by `1 - b`, so b marks where the pivots are. See [crysis.md](crysis.md) for how this maps onto CryEngine's `_DetailBending`.
- Trunks are rigid; branches lose stiffness with reach from their parent (`trees.Stiffness`, `trees.StiffnessAlong`). Small plants need their own amplitudes (`SMALL` in `materials.lua`); tree amplitudes on a small blade stretch it many times its length.
- The clock is `atmosphere.GetWindTime()`/`GetWindDetailTime()`, scaled by `weather.SetWindTimeScale` (0 stops plants). Far plants blend to their rest pose (`r_wind_still_pixels`), identically in every pass so a plant and its shadow stop together.
- Every consumer (raster, translucent, shadow maps, the visibility buffer's animate pass, ray traced copies) calls the one `deform()` in `deformation.lua`; deformed positions are not cached for the raster.
- Rays see bending through `goluwa/render3d/scene/deformed_copies.lua` (`r_rt_deform`, `r_rt_deform_distance`, `r_rt_deform_triangles`): copies of meshes deformed by the same `deform()` with refit BLASes, assigned to instances on the gpu from per-part pools (`scene/parts.lua`). Instances without a copy are traced at rest; too few copies shows as flickering, still shadows on moving plants. Hit shading reads the resting mesh.
- **Pushers**: `vegetation_pushers.lua` uploads the nearest non-static rigid bodies with a short pose history; the shader rotates each piece of a plant away from contacts (rotation only) with a damped-spring lag. Each vertex carries its piece's skeleton (`pivot`, `chain_mid`, `chain_tip`), and a model has a root chain per LOD (`vegetation_pivots.FindRoot`) so separate meshes (crown and trunk) move together. Pieces not on the root chain do not follow each other, so build a frond as one mesh.
- Builders that know their skeleton must state it rather than let it be inferred: `MeshBuilder:SetChain(pivot, mid, tip)` stamps vertices built after it and `Build{root_chain = {...}}` states the root. Everything in the foliage addon does this, and the foliage test builds every generator with inference off and requires a chain on every bending vertex. The root's flex must equal what its own vertices use, or children lag or lead it.

## Pitfalls

- Paint cutouts premultiplied and divide by coverage at the end; mixing over a background colour leaves a halo after dilation.
- A cutout normal map must treat a clear neighbour as the texel's own height (`surface_normal`), or every leaf gets a bevel. Keep large-scale albedo noise out of a normal map's height when the mesh is displaced by a different noise.
- Normal map orientation: x is +u, y is +v (the bitangent of `BuildTangents`), no green flip; check with a lit dome.

## Verifying and looking at it

- Tests: `test/tests/render3d/foliage.lua` (determinism, chains), `test/tests/render3d/vertex_animation.lua`.
- Examples in `addons/examples/lua/examples/render3d/`: `foliage_world.lua` (a landscape using every preset; `foliage_world_view N`, `foliage_world_labels`), `foliage_showcase.lua` (every preset on flat ground), `vegetation_debug.lua` (bending and pushers on flat coloured debug plants; hold Q for pusher controls; judge pushers here rather than on real assets).
- Right after a camera jump, terrain can show holes while its tiles swap; settle longer before shots.
