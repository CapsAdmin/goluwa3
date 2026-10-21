# Procedural foliage

Trees, grass, rocks, flowers, bushes, ferns, mushrooms, logs and litter, made in Lua from a seed and a config, with textures drawn on the gpu. Nothing needs to be installed. Addon: `addons/foliage/`; modules in `lua/foliage/`, registered as assets at startup by `lua/autorun/render_3d/foliage.lua` (nothing is built until loaded).

## How it fits together

- `foliage.lua` is the registry. A generator (`AddGenerator(name, {category, defaults, build})`) makes one kind of thing from a config; `foliage.Build(name, config)` returns parts `{mesh, material}` and caches per serialized config. A config only holds keys that differ from the defaults; unknown keys are errors. `AddPreset` registers a model asset `models/foliage/<category>/<preset>.lua`; `RegisterModel` adds more.
- **Model assets** are descriptors `{kind = "procedural_model", create_primitives(options)}` loaded through `assets.GetModel`/`model_loader.LoadModel`, so the paths work wherever a model path does (`Visual:SetModelPath`, the model component with `ModelOptions`, scatter prototypes and billboards). A virtual model's load returns what a Lua model file would; the category finishes the entry (`loads_virtual`).
- **Reproducible**: all randomness comes from `random.lua` (xorshift with exact 32 bit hashing, `mul32`). A part of an asset takes a named fork (`rng:Fork("leaves")`) so adding a draw to one part does not move the others. Textures use integer hashes in glsl, never `fract(sin())`, so every gpu draws the same picture. `test/tests/render3d/foliage.lua` checks determinism.
- **Materials and textures**: `materials.lua` lists every material and how its textures are drawn (`AddMaterial`; each needs albedo, normal and roughness). `textures.lua` kinds are glsl defining `Surface surface_at(vec2 uv)` (albedo, alpha, height, roughness, transmission); `Texture:Shade` renders a channel of it, the normal map from the height. Config keys are shader constants, so a config is a shader compiled once and then cached. A request's config merges over the registered one (`assets.GetTexture("textures/foliage/oak_bark_albedo.lua", {config = {...}})`).
- **Cutouts** (leaves, needles, fronds, heads) are painted premultiplied into a canvas and made into textures by `goluwa/render/cutout_texture.lua`: colors are dilated into clear texels and every mip keeps the alpha-test coverage of mip 0 so cards do not thin out. Billboards bake through the same code.
- **Meshes** (`mesh_builder.lua`) are written in the packed vertex layout and uploaded with `Polygon3D:UploadVertexArray`, tangents from `vertex_math.BuildTangents`. Triangles are given counter clockwise from the side the normal faces; the builder converts to the engine winding.
- **Light through leaves**: leaf/needle/frond/blade/petal materials set `DiffuseTransmission`, `TransmissionColor`, `TransmissionScattering`, tree and bush leaves also a `TransmissionTexture`. Leaf materials set `BentNormals` (the back of a double sided card mirrors the normal instead of reversing it).

## Generators

- `trees.lua`: a Weber and Penn style branching engine (`BuildTree`: trunk or stems, optional split, levels of branches, crown shape, curved branches), leaf cards placed on outer levels with normals bent away from the trunk (so the crown shades as one shape), species oak, pine, birch, willow, dead_tree, palm (own builder), bushes. `AddFrond` is shared with ferns. Pine sprays need a crossed second card or they vanish edge on.
- `grass.lua`: tufts of curved blades, seed heads, reeds. `rocks.lua`: cube sphere displaced by noise, cut by planes; uv is the vertex direction's place in a 3x2 atlas shared with the `rock` texture (`FACES` must match in both); a half-grid LOD is what scatter puts in the ray traced scene. `plants.lua`: flowers, fern, mushrooms, log, stump, leaf litter, branches. `scatter_sets.lua`: `foliage_meadow/forest/tropical/rocky/wetland`.

## Wind

- Parts of a model share `BendHeight`; materials set `Bending` and `DetailBending` (`leaves`, `grass`). Vertex color is the bending convention of `model_pipeline.lua`: r flutter, g phase, b stiffness (1 rigid). Main bending sways the whole model about its root; detail bending moves vertices by `1 - b` and flutters along the normal by r. A part with constant b moves rigidly; where b falls along a part it turns about where b is 1, so b is where the pivots are.
- Trunks are rigid (b 1). A branch is held where it leaves its parent and loses `flex` of stiffness per meter of horizontal reach (`trees.Grow`, `trees.Stiffness`). Children start with the parent's stiffness; cards, blades and heads follow the same rule (`trees.StiffnessAlong`, `grass.FLEX`). Small plants use their own amplitudes (`SMALL` in `materials.lua`) and `BendDetailPhase`; reusing tree amplitudes on a 10 cm blade stretches it many times its length.
- The clock is `atmosphere.GetWindTime()` (and `GetWindDetailTime`), scaled by `weather.SetWindTimeScale` (0 stops plants). Far plants stand still: `r_wind_still_pixels` blends toward the pose at time 0 once the motion spans fewer pixels, identically in the gbuffer, translucent passes and shadow maps so a plant and its shadow stop together.
- The lean is a curve of wind speed in m/s (`MAX_BENDING`, `BENDING_SPEED` in `model_pipeline.lua`). See [crysis.md](crysis.md) for how this maps onto CryEngine's `_DetailBending`.
- Verify with `test/tests/render3d/vertex_animation.lua` and the `wind_debug.lua` example (every part of the bending on flat colored debug trees and grass, wind and multiplier controls).

## Pitfalls

- Paint cutouts premultiplied and divide by coverage at the end; mixing over a background color leaves a halo after dilation.
- A cutout normal map must treat a clear neighbour as the texel's own height (`surface_normal`), or every leaf gets a bevel. Keep large-scale albedo noise out of a normal map's height when the mesh is displaced by a different noise.
- Normal map orientation: x is +u, y is +v (the bitangent of `BuildTangents`), no green flip; check with a lit dome.

## Looking at it

`addons/examples/lua/examples/render3d/foliage_world.lua` (a landscape using every preset through one scatter set; `foliage_world_view N`, `foliage_world_labels`) and `foliage_showcase.lua` (every preset on flat ground). Right after a camera jump terrain can show holes while its tiles swap; settle longer before shots. Building is fast (trees 10-20 ms, rocks 15-40 ms, the rest a few ms); a texture costs a draw plus, for cutouts, a download and cpu mips.
