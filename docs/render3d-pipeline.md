# Render3D pipeline, Vulkan pitfalls, LOD, surface features and test scenes

How the 3D frame is put together and the invariants that are easy to break. Pass sources are in `goluwa/render3d/passes/`; the list and order is `default_passes` in `render3d.lua`. Each pass has an `r_pass_<name>` pvar; a disabled pass is still built, except `optional` entries, which are only built while on. Toggling one, or a build time pvar like `r_ray_shadows`, rebuilds the bundle in the background (`render3d.RebuildPipelineBundleAsync`): the old pipelines keep drawing until every new one has compiled, then they swap. Code that toggles and draws at once calls `render3d.FinishPipelineRebuilds()` first (the Test3D `draw()` does; `Shot.WaitLoaded` waits for it). The ray traced scene store and the culled draw path are in [gpu-scene.md](gpu-scene.md); lighting is in [render3d-lighting.md](render3d-lighting.md); measurement is in [performance.md](performance.md).

## Frame structure

- `render3d.lua` records, before any pass: `UpdateScene`, skinning, the scene store's instance update and TLAS build, and the main view cull (`scene/draw.lua`). Geometry reaches the gbuffer through the culled multi draw pipeline variants (`gbuffer_multi_draw`, vertex pulling, per batch records from `BatchTable`), `gbuffer_instancing` for what the cpu still draws, and gbuffer extras.
- **Gbuffer extras** (`gbuffer_extras.lua`) draw geometry that is not a scene model (tessellation, cluster streaming): `name` (pipeline variant), optional `BuildPass`, `PreDraw(cmd)` (compute, before the render pass) and `Draw(pipeline, cmd)`. `geometry_block.lua` is the per frame uniform block they share. The translucent passes have the same kind of list in `translucent_extras.lua`.
- **Async compute.** With a compute-only queue family (`GOLUWA_ASYNC_COMPUTE=0` disables it at device creation) resources use concurrent sharing and passes with `queue = "compute"` record into a compute segment between `render.BeginCompute` and `render.JoinCompute`. Passes marked `compute_input` are recorded before the split. A compute pass must not read anything a graphics pass between the split and the join writes (mark the writer `compute_input`), and may only use compute queue commands. The split replaces the frame's command buffer, so anything holding it across the pass loop must fetch it again (`render.GetCommandBuffer()`).
- **Draw order**: scene meshes and scatter, then extras, then depth writing relief/parallax and terrain layer pipelines last, so the most expensive fragments are rejected by what is in front of them. Only height map pipelines write `gl_FragDepth`, to keep early-Z elsewhere. Fragment shaders with side effects (atomics) lose early-Z; `early_fragment_tests` is wrong for alpha tested geometry.
- Fullscreen passes (`EasyPipeline` with `fragment = {...}`) must set `CullMode = "none", DepthTest = false, DepthWrite = false`, or the triangle is silently culled. A pass that outputs exactly zero: check this first.
- Rotate anything the gpu reads across frames (descriptor sets, ring buffers) by `render.frame_serial`, not `system.GetFrameNumber()`: a blocking wait inside Update can record a second frame with the same frame number.

## Resolution, upscaling and TAA

- The scene renders at `r_upscale_height` (0, or at least the window height, is native). `r_aa` picks the anti-aliasing: `taa` (an FSR3 style upsample and accumulate, split into `taa_inputs`, `taa_reactivity`, `taa_shading` at internal resolution and `taa` at window size), `fxaa`/`ssaa` at internal resolution followed by `easu` (FSR1) upscaling, or DLSS ([dlss.md](dlss.md)). RCAS (`rcas.lua`, `r_sharpen`) follows.
- Every pass before `taa` in `default_passes` is internal sized (`render3d.GetInternalRenderSize`, recreated by `UpdateInternalRenderSize`); passes from `taa` on are window sized. A pass can force `resolution = "internal"`. `render3d.GetRenderSize()` is the internal size, `render.GetRenderImageSize()` the window.
- A post pass that reads gbuffer textures must map its pixel into them (`(pixel + 0.5) * gbuffer_size / size`) or sample by uv, never `texelFetch` with its own pixel.
- Material textures use a negative mip bias for the upscale ratio (`render3d.GetMaterialMipBias`, the camera block's `mip_bias`).
- The camera's `Jitter` is in window pixels. `render3d.GetPreviousProjectionMatrix()` re-applies the current jitter, so velocities carry no jitter and must not be corrected for it. Previous frame textures at internal resolution are sampled at `uv - motion + (previous jitter - jitter) / viewport`.

## Conventions

- **Reverse-Z**: `Camera3D:BuildProjectionMatrix` applies `Matrix44:ReverseDepth()`: near is 1, far is 0, `d32_sfloat` cleared to 0, depth tests `greater_or_equal`, sky is `depth == 0`. "Further" is smaller, so min/max swap (Hi-Z keeps the min). Code that rebuilds a ray from `inv_projection` with depth 0/1 has near/far swapped. Depth tolerances must be relative. Shadow maps use standard-Z. The engine's NDC y points down; check sign conventions numerically.
- **Vertex layout**: `vertex_layout.lua` is the only place that lists vertex fields (ffi type, offsets, Vulkan attributes, GLSL accessors). Fields are in two buffers: packed **core** (position, normal, uv, tangent) and **extras** (`EXTRAS_BINDING`; meshes with uniform extras share a default buffer via `vertex_extras.GetShared`). Producers write full float vertices which `vertex_layout.Split` encodes and `Join` decodes; never read gpu core arrays as floats on the cpu. Nothing else may hardcode an offset or stride: Lua uses `GetFloatOffset(name)`, shaders use the generated accessors. A new field is one entry in `Fields`. Test: `test/tests/render3d/vertex_layout.lua`.
- **Pipeline variants** (`shader_features.lua`): unused shader code still costs registers, so multi draw pipelines are compiled per feature set. Each feature is a define (default 1, so shaders built outside the system keep everything) with a glsl gate. A variant is a shape (plain, relief, nearer) plus feature bits (`draw.GetVariant`); rows get bits from their material (`draw.SetRow`, `Material:GetSurfaceParamBits()`), global state remaps them in the cull (`resolve_variants`). Variants build lazily (`render3d.RegisterPipelineVariants`) and rows draw through the full variant until theirs is ready. `shader_features.param_groups` splits material params into groups whose absence folds the glsl away; each group doubles the variant count, so keep params common content uses out of groups. Adding a feature: add it to `shader_features.list`, gate its glsl on the define, set its bit per row or globally. A feature only one kind uses (`refraction`, translucent only) is left out of the other kinds' feature masks (`SetVariantKind`), so their rows never build a duplicate variant for it. Rarely taken branches in a shader still cost registers on every pixel; a feature bit that folds them away is often the cheapest speedup.

## Surface features and the gbuffer layout

`goluwa/render3d/features/*.lua` holds surface features, listed in `surface_features.lua` (whose header documents every key and snippet scope); `surface_features.New(list)` makes a registry of any list (tests use it). A feature is one table:

- `params` become `Material` GetSets, factor block fields and the default check; `block = "own"` with `active(material)` gives an own uniform block.
- `fields` are what the gbuffer stores; a field with a `member` gets its `Surface` member, default, decode and write generated.
- Snippets that build a `Surface` are shared by the gbuffer, forward translucent and lighting passes; lobe snippets are spliced into `get_direct_light`/`get_indirect_light`.
- **Stage order matters**: features run in list order within a stage, core must stay first, and a feature that adds ambient light must come before one that layers over it. Ray hits (reflections, probes) shade with the core lobes only (`ibl.GetHitBRDFGLSL`).
- `surface_finish` runs on a `Surface` that was decoded, never defaulted: every member a feature sets there must be assigned before use, or it reads uninitialised memory that shows only on some materials.
- To add a feature: write `features/<name>.lua` and add it to `default_list`.

`gbuffer_layout.lua` packs `fields` into `r16g16b16a16_unorm` targets (at most 8); `unorm8`/`unorm4` fields are bit ranges read with `texelFetch`, so packed fields are never filtered. The budget is bits: `gbuffer_layout.Describe()` prints what is free. Encoders, decoders and `gbuffer_set_defaults()` are generated. `gbuffer_inspect.SetView{...}` shows targets and decoded fields. Test: `test/tests/render3d/gbuffer_encoding.lua`, `gbuffer_inspect.lua`.

**Absorbing media** (`features/medium.lua`, `media.lua`, `medium_common.lua`, `optical_rays.lua`): a material's `Medium` names a `media.presets` entry (per channel absorption and scattering in 1/m, phase, IOR) and renders the surface as the skin of an absorbing, scattering body (ice, water, translucent solids). A material references its medium through a small per session slot table (`media.Acquire`, `Material:GetMediumSlot`) because the gbuffer only has a few bits for it. Shared transmission math lives in `medium_common.lua`; change the model there, not in one shader. Water volumes, fog, fluid volumes, particles and the transmission/subsurface helpers (`media.GetTransmission`, `media.GetSubsurface`) take their optical data from the same registry. The traced thickness terms need closed meshes and ray queries; open meshes fall back to scene level assumed thickness. Rays that sample a per pixel value should be aimed along the smooth `s.N`, using `geometric_N` only for the origin offset, or every triangle of a decimated mesh prints into the result. The `pbr_parameters` example shows media side by side.

## Visibility buffer

`r_visibility_buffer` (build time, set with `GOLUWA_PVARS`) lets dense geometry rasterize only a triangle id and shades each visible pixel once in compute. Source: `goluwa/render3d/visibility.lua`, hooks in `passes/gbuffer.lua`, `scene/draw.lua` and `render3d.lua`. It needs fragment shader barycentrics, compute shader derivatives and 64 bit buffer atomics (`visibility_buffer_supported`); otherwise everything draws classic.

- Routing: the cull routes a group (and each cluster lod cluster, and scatter streams) to the id variants when its triangles per covered pixel reach `r_visibility_buffer_density`; tessellation always uses them. Everything else stays classic and writes visibility 0, so both kinds mix by depth in one pass. A variant draws ids only once its id and resolve pipelines are ready (`visibility.IsResolveReady`).
- The resolve (classify into 2x2 quad jobs binned by material, then one pipeline per bin running the multi draw vertex stage for three vertices and the gbuffer fragment stage on derivative quads) is generated from the multi draw shader sources by text rewriting. Those stages may only use `gl_FragCoord.xy`, `gl_FrontFacing`, `gl_VertexIndex`, `gl_InstanceIndex`, `gl_DrawID` and `gl_Position`.
- Vertex animation must stay inside `deform()` (`deformation.lua`), which records or replays its offsets for the resolve.
- Avoid `gl_PrimitiveID` in fragment stages (expensive on NVIDIA); indexed draws pack the three vertex indices from `pervertexEXT`, which limits id meshes to 2^21 vertices (`CLASSIC_ONLY`).
- Storage images cannot be sRGB, so the albedo target is unorm with manual sRGB encoding.
- Software raster (`scene/software_raster.lua`, `r_visibility_raster*`) rasterizes small dense clusters and tessellated patches in compute with 64 bit `atomicMax`, producing the same ids the hardware pass would.
- Measuring: compare the `gbuffer` scope against `gbuffer` plus the `visibility_*` scopes; `gbuffer` already contains the software raster and extras' compute. Synthetic scene: `examples/render3d/micro_triangles.lua` with its saved views. Test: `GOLUWA_PVARS="r_visibility_buffer=1" luajit glw test render3d/gbuffer_encoding.lua`.

## Projected decals

Decal components with a `terrain`, `terrain_objects`, `objects`, `planar` or `road` projection are not meshes (`r_projected_decals`, on by default; `brush` decals stay meshes). `goluwa/render3d/projected_decals.lua` turns them into records in one device buffer: vertical quads for terrain decals and road segments (inverse bilinear uv, fades), boxes for the rest, sorted by `SortPriority` and binned into an XZ grid. `apply_projected_decals` blends them over a surface in that order and is shared by:

- the gbuffer: a compute pass right after it (`projected_decals.Resolve`, called where `visibility.Resolve` is) rewrites albedo, normal, roughness and metallic in place, so decals follow tessellation and relief, cast no shadows and blend with real alpha. Compute has no derivatives, so texture gradients come from the neighbouring depth samples (the plane of the geometric normal fails on micro triangles). The gbuffer targets have storage usage for this.
- ray hits: ray material entries carry the grid address and the receiver mask; the path tracer applies decals at mip 0 with normals, screen GI and the radiance cache read their averages (`ray_material_decal_albedo`).

- terrain relief: `terrain_shell_relief` (tessellation, the shell march, ray traced tessellation) blends each terrain decal's height map over the layers' relief by the decal's alpha (`projected_decal_relief`), so decal heights stay a function of world position and seams stay watertight. Terrain materials carry the grid address (`TerrainDecalsLow`/`High`) since those shaders only see the material. A tile's shell includes the tallest decal relief over it (`projected_decals.GetMaxRelief`); adding, moving or removing a height decal invalidates the terrain tiles under it (`ProjectedDecalReliefChanged`). Relief in meters is the material's `HeightScale` times the decal's uv size, like a mesh height map. Shadow maps see the undisplaced terrain.

Only surfaces whose material sets `DecalReceiver` (1 terrain, 2 static objects; a 4 bit gbuffer field) receive decals; terrain tiles and Crysis materials set it. It is per material, so a moving thing sharing a static material receives decals inside a box.

## Materials

- `Material.New{...}`: unknown keys are errors. **A raw `Material.New{}` is fully metallic** (`MetallicMultiplier` 1, a tinted mirror); `shapes.Material` (`goluwa/render3d/shapes.lua`) has matte defaults. Set metallic to 0 explicitly in scratch scenes before judging shading.
- Material properties are versioned: changing one stamps a version, and everything derived (upload keys, pipeline uniform memos, `BatchTable` records) follows the version. In-place changes of a vector/color or direct field writes are invisible: call `material:Touch()` afterwards, and only when something changed. Tests: `batch_table.lua`, `material_upload_keys.lua`.
- `VertexTint` multiplies albedo by vertex colour in the raster only; ray hits do not see it.
- `AlphaTest`/`AlphaCutoff` discard with derivative sharpened, temporally dithered coverage; `AlphaCoverage` uses the alpha as coverage instead.
- Ray evaluated emission (GI, reflections, emitter sampling) goes through `ray_hit_emission`, which samples the emissive texture at the hit. Emitter importance uses `EmissiveMean`, so a wrong mean only costs noise.
- `Unlit` translucent materials write only emission; every other translucent pixel runs the full lit shader, so glow-only effects should be unlit (`Beam.CreateRibbonMaterial` sets it for additive materials).
- `Visual:SetOverlayMaterial(material)` draws entries again in the forward overlay pass (unlit, no depth test unless `OcclusionRadius` is set); `RimColor`/`RimPower` add a view angle edge. Animated overlays are in [surface-overlays.md](surface-overlays.md).
- `Visual` `CullDistance` limits drawing (shadows still cast). Very large camera far planes break the ocean pass.

## Beams

`goluwa/render3d/beam.lua` draws tubes or camera facing ribbons along a point list (ropes, lasers, trails). `Beam.New{...}`, then `SetPoints` (or `SetRibbonPoints` every frame for ribbons). It is a dynamic Polygon3D without shadows, BVH or occlusion culling; glow is an emissive material plus bloom, not a light. Geometry rewritten in world space every frame must update its `LocalAABB` in place, since translucent draw bounds are cached per item. Test: `test/tests/render3d/beam.lua`.

`Visual:SetGroundHeight(y)` rests a loaded model's world AABB bottom on `y` (it shifts the local position, so rotated or scaled parents give the wrong offset).

## LOD

`goluwa/render3d/lod.lua` and the `lod_*` pvars (`lod_level` -1 auto or a forced level, `lod_scale`, `lod_fade`). Polygon3D carries `LODLevel`, `LODDistance` (in bounding radii) and `LODBillboard`. `RenderEntries` holds LOD 0 (raycast, translucent and cpu draws see only that); `GetLODRenderEntries()` holds every level for the scene store. The gpu picks the level by distance and crossfades with complementary dither (`discard_lod_fade()`); shadows hard switch. Billboards (`billboard.lua`, `Visual:SetBillboard(true)`) are baked atlases; material overrides must not apply to `LODBillboard` polygons. Large static models use [cluster-lod.md](cluster-lod.md) instead.

## Parallax and height shells

`get_ssdm_data` in `passes/gbuffer.lua` marches the height texture (`HeightLayers` scaled by view angle, bisection refine). It only moves depth and shading: shadow maps, local lights and rays see the flat surface. [tessellation.md](tessellation.md) is the displaced geometry alternative.

Height shells (`HeightShell`, `Polygon3D:AddHeightShell()` before upload) let relief rise out of a mesh: a pushed out top copy, the base copy and boundary quads march `shell_trace` through prisms of the base triangles (shared with terrain shells, only `shell_sample` differs). Only entry fragments march from themselves; others march from the eye and only while the eye is near a shell (`draw.IsEyeNearHeightShell`), otherwise the walk wanders. The pass writes `depth_less` (reverse Z) to keep early depth rejection. Shells need a non indexed mesh and draw both faces; culling, shadows and rays see the base mesh.

## Vulkan and driver pitfalls

- **Never `tonumber()` a Vulkan handle or device address**: they exceed 2^53 and doubles drop low bits (fails only in large scenes as "Invalid ... Object"). Keep `uint64_t` cdata.
- `goluwa/bindings/vk.lua` is generated by a tool outside this repo; check multi-dimensional arrays against the headers if it is regenerated (see [vulkan-raytrace.md](vulkan-raytrace.md)).
- **GLSL `%` with a negative operand is undefined (unsigned on NVIDIA).** Shift into the positive range first (`RADIANCE_CACHE_WRAP` in `radiance_cache.lua`). Matters for scrolling grids, clipmaps and rings.
- **Flags are a `FlagSet`** (`goluwa/render/flag_set.lua`): the set owns bit assignment, names past 32 start the next word, duplicates error. Uniform blocks flatten a set to one int per word; consumers read words (`material:GetFillFlags(word)`), never a single int.
- **Bindless textures are one global set** (`goluwa/render/vulkan/bindless.lua`): set 1 of every graphics, compute and ray tracing pipeline, so bindless samplers are declared in set 1. `GetTextureIndex` returns a global index; releasing is global and indices are reused only some frames later. Pipelines that never sample engine textures can pass `Bindless = false`.
- The pipeline cache file has a version header (`PIPELINE_CACHE_HEADER` in `render.lua`): drivers reuse cached pipelines across descriptor layout changes they do not hash, so bump it when layout semantics change. If the cache grows every run, a shader bakes changing values into its source (use push constants or uniforms). Time startup with `__GL_SHADER_DISK_CACHE=0` when comparing shader changes.
- NVIDIA inlines every glsl call and its compile time grows with every inlined copy, so call expensive helpers (trace loops, inscatter loops) from one site and split work around them: a loop over the cases instead of one call per case, flags instead of one wrapper per variant, one shared call for branches that differ only in their inputs. Measure by timing one pipeline's driver compile with a source change that reaches the SPIR-V (an unused constant is stripped and hits the cache), and stub functions with neutral values: a stub that returns 0 for a visibility lets the driver delete everything after it.
- **CPU reads of mapped gpu memory are very slow** unless the memory is `host_cached`; anything the cpu reads back must be cached readback memory. Never grow a mapped buffer by copying out of the old mapping; keep a cpu copy. `host_visible`+`device_local` allocations fail once BAR memory is full.
- **Range pools** (`index_pool.lua` over `offset_allocator.lua`) bin requests, so a free block of exactly the requested size can fail (`Alloc` returns nil): grow by more than the request. Free through the returned node.
- Meshes over 65536 vertices need 32 bit indices.
- Compute pipelines hand out descriptor sets per command buffer object; `RenderNow` style code needs a fresh cmd per call.
- A `ComputePass`'s `on_pre_draw` is called as `(self, cmd, frame, desc)`: a shared helper that takes `desc` third writes into another frame's descriptor set, so the pass silently traces or reads last frame's bindings. Indirect dispatches over per pixel lists need a 2D grid; a full resolution frame's rays exceed `maxComputeWorkGroupCount` in x.
- glslang is located or fetched by `render/glslang_locator.lua` (hashes in `goluwa/bin_manifest.lua`).
- Lavapipe (no GPU): `maxStorageBufferRange` is small, render3d tests use a lot of memory, and a segfault in JIT shader code is shader memory corruption, not Lua; bisect by skipping dispatches.

## Shared GLSL helpers

`glsl_common.lua` (`luminance`, `pcg3d`/`pcg4d`, value noise, every block `#ifndef` guarded) and `screen_reconstruct.lua` (view and world position from depth). Check them before writing a hash, noise or luminance helper; a shader using `luminance()` must include its GLSL, and a local named `luminance` shadows it. A texture's mean is `texture_average(idx)`, never a top mip read: loaded mip chains can stop above 1x1. Low level helpers (`batch_table`, `instance_batcher`) must not import `render3d`.

## Culling invariants

- Hi-Z mips are floor sized, so the reduce folds the remainder into the last texel and the cull maps uv to texels with `uv * base_size / 2^mip`, clamped; otherwise large near boxes get culled.
- The main view writes world and previous world matrices per instance for velocity. Anything that moves relative to what draws beside it must be written for the frame it is drawn.
- Tests: `test/tests/render3d/culling.lua`, `scene_cull.lua`, `instancing.lua`, `batch_table.lua`.

## Scene view, model preview

`ModelPreview` -> `SceneView` (`scene_view.lua`) -> a shared pipeline bundle run through `render3d.RunPipelineBundle` with a render context (`camera`, `render_size`, `lights`, `environment`, ...) -> `view_resolve`. `Environment` (`environment.lua`) owns an envprobe from an HDR file or atmosphere. `forward_preview.lua` is only used for billboard baking.

- Render targets are upright in memory but render2d shows them mirrored (`ModelPreview:Draw` flips uv). Check orientation on a screenshot with an asymmetric model; pixel tests cannot catch it.
- Per frame cached uploads must be reset between runs (`pipeline:ResetFrameUploads()`); module global state the passes read (lights, atmosphere, frame caches) must be checked when adding a second view.
- Preview entities must be `visual:SetVisible(false)` or they also render in the world.
- `ComputePipeline`/`RayTracingPipeline` `OnRemove` must unregister texture listeners (`test/tests/render/pipeline_removal.lua`).

## Test3D

`T.Test3D(name, function(draw)` initializes render3d with only the gbuffer and blit passes, so `T.GetScreenPixel` reads the blitted gbuffer; tests needing other passes re-initialize with their own list (see `test/tests/render3d/translucent.lua`). `draw()` runs a whole frame. Before trusting a pixel test, check the pass is in the bundle and read a no-geometry baseline. The brdf LUT is missing there, so metallic surfaces render black. Full engine checks use `--3d` scratch scripts with `Screenshot`/`Shot` ([screenshots-and-cameras.md](screenshots-and-cameras.md)).
