# Material baking

`goluwa/render3d/material_bake.lua` bakes what a material's flags derive (roughness, metallic, normals, tints, channel selection) into compressed textures once, so the shader samples them instead of evaluating the flags. Pvar: `r_bake_materials`.

## How it works

- `material_bake.Render(material, width, height)` runs the engine's own surface shader code (`BuildPBRSurfaceGlsl`) over uv space through the same material uniform blocks the gbuffer uses, into render targets. Because it evaluates the real functions, the bake cannot disagree with the flag path; there is no second copy of the logic.
- `Bake` compresses the targets with `texture_compress.Recompress` (see [texture-compression.md](texture-compression.md)) into `Albedo`, `Normal`, `MetallicRoughness` (r metallic, g roughness, b packed specular scale read through `PackedSpecularScale`), plus second layer textures for vertex blends and `Emissive` when the material emits. Runtime multipliers (`SpecularMultiplier`, `EmissiveMultiplier`) stay on the material.
- `Apply` swaps the material to the baked textures and resets every property that existed only to derive them.
- `Render` clears textures that must not be baked in for the draw and restores them: micro detail (would be applied twice) and the ground colour (sampled at a world position the uv draw does not have).

## Requests and cache

- Loaders call `material_bake.Request(material)` once a material is set up: the vmt loader and the cry loader. Baking is therefore a property of loaded content, not a global material path. A material carries `bake_name`, `bake_generation` (a reload bumps it so a stale bake is dropped) and optionally `bake_estimators`.
- The vmt loader creates textures deferred (`Texture.New{defer = true}`), so `Request` decides before any original is read: `CanBake`, then the key (`GetKey`: path plus a hash of every property and texture path). A hit loads the baked dds files and the originals are never loaded; a miss loads everything (`LoadDeferred`) and is baked a few per frame from the update loop once its textures are ready.
- Cache: `storage/cache/baked_materials/v<Version>/<name>_<hash>/`. `material_bake.GetVersion()` hashes the bake sources and the generated bake shader, so editing them re-bakes without anyone bumping a number; other versions' folders are deleted.
- `CanBake` says why a material is skipped and `GetStats()` counts skips. Texture transforms, proxies, some blend setups and specular mask modes are among the things that are not baked; detail, render state flags, height/parallax and screen space or environment dependent terms (antialiased roughness, weather, conditions, overlays) stay runtime.

## Rules

- Every deferred texture must end up loaded, except the ones a hit replaces; a texture that is never loaded stays the fallback.
- A bake must never run on a fallback or unloaded texture, so nothing wrong reaches the cache.
- The key must not depend on load order. Albedo-ready adjustments of the vmt loader are held in `material.deferred_adjustments` while baking is on: the key is taken first, then a hit drops them (their effect is in the baked textures) and anything else runs them when the albedo is ready. For the same reason the colour tint is baked and part of the key.
- Callbacks on a texture becoming ready run inside `MakeReady`; anything they read must be set before it.
- Baked textures are unique per material, so many materials need many bindless descriptors.
- Blends: the blend weight is vertex data and is never baked, but each layer is baked separately (`GetLayerKind`). Roughness and metallic derived from the mixed albedo or normal become the mix of the two layers' values.
- Alpha tested materials get albedo mips from `cutout_texture.Compress`, which keeps each mip's alpha from the original texture (the distance alpha test is dithered, so the whole alpha distribution matters); box filtered mips lose coverage and foliage vanishes in the distance.

## Estimators

Because the bake runs once per material over the whole texture, it can apply estimates too expensive or too wide for the per pixel path. They live in the bake shader only (`material_bake.estimators`, each switchable; strengths in `estimator_params`), so unbaked materials do not get them: `estimate_albedo` (de-light tileable world textures), `estimate_normal` (a gentle normal from albedo shading for materials without one) and `estimate_roughness` (rougher where normals or luminance vary, only without an explicit roughness source). The metal gate is not an estimator; it is the runtime feature `DerivedMetalAlbedo` (see [animation-and-source.md](animation-and-source.md)) and the bake just renders it.

To evaluate estimators, compare against a decomposition reference (for example the `pbr_assets` ComfyUI client, `comfy:Run` with `passes = {"albedo"}`) on structure, local contrast and saturation, never absolute brightness: Source lightmaps modulate world textures. Judge with a contact sheet over many material families, not one scene.

## Material file

Every bake writes `material.mat` (`material_file.lua`) next to its dds files: a luadata chunk with every non-default property and a `Meta` key (source info, key, inputs, and `unserialized`, the properties luadata cannot carry). Object valued properties are written as references through `material_file.RegisterReferenceType` (a texture is `{path, srgb}`, relative when it lives in the same directory; a scatter set is `{name}`). A texture without a path is written through the caller's `relative_paths` (texture to file) when it was made from decoded data. `material_file.Load(path)` resolves them, a name in the material's own directory winning over the same name looked up globally (one cached directory listing, no per file probing); `.mat` is a registered material extension. Saving a scene with its materials is in [scene-export.md](scene-export.md).

## Height from normals

`goluwa/render/height_from_normals.lua` solves for the height a normal texture describes (Frankot Chellappa Poisson solve with a gpu fft). It needs a square power of two texture and assumes it tiles. `cutoff` (cycles over the texture) removes the slowest frequencies, the drift a tiling solve cannot know; `height_cut` fades out everything finer than that many cycles, since parallax smears steep narrow grooves. `vmt_material` uses it for parallax heights (`NORMAL_PARALLAX`).

## Verifying

`test/tests/render3d/material_bake.lua` bakes a material with several derived flags, applies the bake to a copy and renders both through the same pass to compare. Loading a Source map twice should serve the second load from the cache.
