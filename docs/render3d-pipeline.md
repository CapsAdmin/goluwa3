# Render3D pipeline, Vulkan, culling, LOD and test scenes

Notes collected from past sessions. Dated numbers are snapshots; re-measure before relying on them.

The notes below about the GPU culling dataset (`dataset.generation`, entry and batch lists, `GetVisibleMainGPUEntries`, `RunMainViewFrustumCulling`, async cull results, `test/harnesses/terrain/coverage.lua`) describe code that was removed on 2026-10-18, when the main view and the shadow maps moved to the scene store: see [gpu-scene.md](gpu-scene.md). They stay for the reasoning behind the bugs.

## Running the suite on lavapipe in a cloud container

*Ubuntu + Mesa 25.2.8 lavapipe; limits, memory and the ddgi crash*

The cloud container has no GPU. Lavapipe reports one 15.7 GiB device-local heap that is just host RAM, and it cannot see the container's cgroup cap (13.4 GiB on a 16 GiB machine), so lavapipe memory is real process memory. Setup that worked: apt `mesa-vulkan-drivers vulkan-tools libvulkan-dev libshaderc-dev libwayland-dev libxkbcommon-dev`, LuaJIT built from the commit in `flake.nix`, libwayland 1.24 (the engine calls `wl_proxy_get_interface`), the LunarG SDK validation layers (Ubuntu's are too old for Vulkan 1.4), `libshaderc.so.1` symlinked as `libshaderc_shared.so`, and headless `weston --backend=headless` for `WAYLAND_DISPLAY`.

- **Memory:** one worker costs about 70 MB idle and a `render3d` file about 1.3 GB just to initialize (8 gbuffer pipeline variants at about 83 MB each plus the compute pipelines; only 174 MB of it is device memory, the rest is lavapipe's compile memory). Validation layers add about 25%. The runner starts another file only while `system.GetMemoryInfo()` shows 4 GiB of headroom. Finished worker Lua states are closed with `lua_close` now; before that every file leaked its whole engine (22 MB CPU-only, 32 MB with a device).
- **Limits lavapipe enforces that GPUs hide:** `maxStorageBufferRange` is 128 MiB (spec minimum). `scene_bvh` BLAS staging is capped to it.
- **Ray tracing:** lavapipe 25.2 advertises ray tracing. `GOLUWA_NO_RAY_TRACING=1` starts the engine without ray tracing: no BVH scene consumers (DDGI traces, light occlusion, particle ray collision), see [DDGI without ray tracing](render3d-lighting.md#ddgi-without-ray-tracing). There is no software fallback.
- **Open: `test/tests/render3d/ddgi.lua` "produces a screen gi texture" segfaults** in JIT-compiled shader code with or without ray tracing, even with one job. The faulting code is a waterfall loop (`tzcnt` over the active lane mask) that loads a buffer descriptor through a per-lane set pointer that is NULL, so heap corruption can then show up in unrelated tests. What is known: skipping the `ddgi_trace` or the `ddgi_shade` dispatch stops it, but each of them alone is fine; it needs real hits flowing from trace to shade. It is not the `scene_bvh_soup` descriptor array (constant-index chunk selection and `SOUP_CHUNKS = 1` both still crash), not the UV soup (`ddgi.ALBEDO_UVS = false` still crashes), and not the albedo/triangle read in `ddgi_hit_albedo` (reduced to a constant still crashes). Next steps: find which descriptor array the shade pass still indexes dynamically (`textures[nonuniformEXT]` through `ddgi_albedo`, light grid, materials), and test whether a newer Mesa fixes it.

**How to apply:** when a lavapipe run dies with `bad callback` PANICs or `free(): corrupted ...`, suspect shader memory corruption, not the Lua side; bisect by skipping pipeline dispatches (`pipeline:Draw()` in the render3d PreRenderPass loop), and use `LP_NUM_THREADS=0` under gdb to get the faulting JIT address.

## Shared GLSL helpers

Helpers several shaders need live in one place, not pasted per module: `glsl_common.lua` has `luminance`, `pcg3d`/`pcg4d`/`pcg_unorm`/`pcg3d_unorm` and `value_noise2`/`value_noise3`, `screen_reconstruct.lua` has `get_view_pos`, `get_view_depth` and the world position getters. Every `glsl_common` block is `#ifndef` guarded, so including one twice through different chains is fine. A shader that calls `luminance()` must include `GetLuminanceGLSL()` itself (`compute_helpers.GetScreenHelpersGLSL` and `GetColorHelpersGLSL` already do). A local variable named `luminance` shadows the function, name it `x_luma`. Check the list before writing a hash, noise or luminance helper.

## GLSL negative % is unsigned on NVIDIA

*wrap with a positive offset, not ((x%P)+P)%P*

On this machine's NVIDIA driver, `(-12) % 24` in GLSL evaluates as if the operand were unsigned (4294967284 % 24 = 4), not -12 or 12. GLSL leaves `%` undefined for negative operands, so `((x % P) + P) % P` is NOT a safe wrap. This silently mapped half of the DDGI probe grid to the wrong world probes. The fix is `DDGI_WRAP(v) = (v + P * 65536) % P` in `goluwa/render3d/ddgi.lua`.

**Why:** the symptom looked like light leaking into sealed rooms and whole rooms taking the sky fallback. Nothing pointed at the index math until the stored probe coordinates were dumped.
**How to apply:** in any GLSL that wraps possibly-negative ints (scrolling grids, clipmaps, ring buffers), shift into the positive range before `%`. Related: [GI measurement needs an exposure lock and a real camera](render3d-lighting.md#gi-measurement-needs-an-exposure-lock-and-a-real-camera) (the scan rig that exposed it).

## Fullscreen passes need CullMode none

*otherwise culled silently, target stays black*

A fullscreen fragment pass in render3d (EasyPipeline config with `fragment = {...}`) must set `CullMode = "none", DepthTest = false, DepthWrite = false`. Without them the fullscreen triangle is back-face culled. The pass's write() still runs, but its target stays cleared to (0,0,0,1) and there is no error. This is why the old SMAA passes never worked.

**Why:** cost a debugging round when adding TAA (2026-09-24). The output was black, the exposure metered -7 EV and the whole frame went dark.
**How to apply:** when a new post pass outputs exactly zero, check CullMode first. Copy the config from volumetric_fog's composite pass.

## Bindless array written outside registry

*wrong texture that heals when more visuals load*

Symptom: with few visuals, a material showed another texture (the gbuffer's own albedo) or went black. Adding visuals or moving things fixed it. Cause: `EasyPipeline:OnWindowFramebufferResized` wrote the pipeline's own framebuffer attachments into bindless slots 0..n directly, and the registry never knew. It stayed wrong until a new texture registration marked the array dirty and rewrote it. Fixed 2026-09-28 by removing that write.

**Why:** the per-pipeline texture registry (pipeline_common.lua) assumes it alone owns binding 0 of the bindless set.
**How to apply:** if a wrong texture "heals" once new textures load, look for descriptor writes that bypass GetTextureIndex. A quick test: force the flush at `GraphicsPipeline:Bind` every time. If that fixes it, the array was clobbered.

## vk.lua 2D arrays were reversed

*generator bug broke RT transforms; recheck on regen*

`goluwa/bindings/vk.lua` is generated by a tool that is not in this repo, and it reversed every 2D array (`VkTransformMatrixKHR` came out as `float matrix[4][3]` instead of `[3][4]`). That silently degenerated the RT instance transforms, so every ray missed. All 2D arrays were hand-fixed on 2026-09-23.

**Why:** this took several sessions to find because every other RT input checked out correct.
**How to apply:** if vk.lua is regenerated, re-check its multi-dimensional arrays against the Vulkan headers. When an RT struct looks right but misbehaves, dump its raw bytes from the GPU buffer. Related: RT pitfalls in `docs/vulkan-raytrace.md` (instance flags live in the high 8 bits of sbrtAndFlags; chs/miss need `rayPayloadInEXT`).

## Never tonumber() Vulkan handles

*doubles round handles past 2^53; invalid-object errors only in big scenes*

Never pass a Vulkan handle or device address through `tonumber()` or store it in a Lua number. Keep it as `uint64_t` cdata, e.g. `arr[0] = ffi.cast("uint64_t", handle)`. On this driver, with validation enabled, handles look like `0x38a9_0000_0038a9`, which is above 2^53, so a double drops the low bits (`...38a9` becomes `...38a8`). Small scenes stay under 2^53, so the bug only appears once many objects exist. It surfaced as "Invalid VkAccelerationStructureKHR Object" in `vkUpdateDescriptorSets` (fixed 2026-09-23 in `goluwa/render/vulkan/internal/device.lua`).

**Why:** the failure is scene-size dependent, so small tests never catch it.
**How to apply:** when a validation error names an invalid handle whose two halves don't match (e.g. `0x38a9...38a8`), look for a double conversion. Related: [vk.lua 2D arrays were reversed](#vklua-2d-arrays-were-reversed).

## CPU reads of mapped GPU memory are slow

*30 MB/s uncached; host_cached for readback, cpu copy for growth*

Measured on this NVIDIA machine: 32 MiB written to a `{"host_visible","host_coherent"}` buffer takes 4 ms, **read back takes 958 ms**, ram to ram 2 ms. Plain host buffers go to memory type 4 (VRAM through the BAR window) or type 2, both uncached for the cpu. Memory types: 1 = VRAM, 4 = VRAM host visible, 2 = system RAM, 3 = system RAM host cached.

- Anything the cpu reads every frame (cull results, visible entry index lists) must be `{"host_visible","host_coherent","host_cached"}` (gpu_culling `create_readback_buffer`). Only for plain gpu stores, not for atomics or indirect buffers.
- Never grow a mapped buffer by copying out of the old mapped one. Keep a cpu copy (index_pool.lua and scene_bvh staging do). That was a 450-700 ms hitch on Beach.
- Type 4 filled at ~7 GiB, a request for `{"host_visible","device_local"}` then fails with out of device memory while VRAM is not full. See [GPU pass timing](performance.md#measuring-correctly).

## Index buffer 16-bit limit

*>65535 verts spiked via uint16 sequential indices in gpu_culling; Mesh errors now*

gm_construct_m3 displacement meshes merged per (visibility group, texture) reached 142k vertices. `gpu_culling.ensure_entry_index_buffer` gives non-indexed meshes sequential indices via `mesh:UploadIndices`, which defaulted to uint16 and truncated, so triangles spiked to other vertices. Fixed by passing uint32_t past 65535; `Mesh` now errors if a uint16 index buffer sits on >65536 vertices.

Also fixed: `IndexBuffer:GetIndexType` was defined twice and the raw-string one won, so batch_table's `index_is_32` was always 0.

**How to apply:** if a big mesh shows vertices attached to wrong positions, suspect index width before geometry. See [gm_construct_m3 profiling](performance.md#what-cost-what).

## NVIDIA shader cache full

*slow startup = uncached pipeline compiles; compare with __GL_SHADER_DISK_CACHE=0*

On 2026-09-29, `--3d` startup took 25 s instead of 3 s. `vkCreateGraphicsPipelines` took 2–6 s per gbuffer/translucent pipeline. The engine passes no VkPipelineCache, so it relies on NVIDIA's disk cache (`~/.cache/nvidia/GLCache`, 1.1 GB, over the default 1 GB limit). Unchanged shaders still hit the cache, but changed ones were recompiled on every run. With `__GL_SHADER_DISK_CACHE=0`, HEAD itself takes 16 s.

The terrain POM shader made it worse. Four layers × three projections each inlined a 15-step march, and uncached startup went from 16 s to 34 s. Loops with a single call site brought it down to 17 s. `dont_unroll` (GL_EXT_control_flow_attributes) made it slower, at 17 s instead of 11 s with the cache on.

**Why:** a faster startup with old code only proves a cache hit. Every compare needs the same cache state.
**How to apply:** time startup with `__GL_SHADER_DISK_CACHE=0` when comparing shader changes. Keep expensive GLSL helpers at one call site inside a loop, because the NVIDIA driver inlines each call. Since 2026-09-29 the engine keeps its own VkPipelineCache in storage/cache/vulkan_pipeline_cache.bin. It is saved about 2 s after a burst of pipeline creation, not on shutdown, so it survives crashes. If that file grows every run, some shader bakes changing values into its source; the atmosphere sky view did, and now uses push constants. See [Perf measurement pitfalls](performance.md#measuring-correctly).

## Depth prepass not worth it

*gbuffer not fragment bound; early-Z fixed via height map pipelines instead*

On Crysis Quarry the gbuffer pass (~1.8 ms of a ~7.4 ms GPU frame) ran no faster with a near-empty fragment shader. That means it's bound by vertices, raster and MRT writes, so a depth prepass would only add a second vertex pass. The real problem was `gl_FragDepth` being written in every gbuffer shader, which disabled early-Z. Now only height-mapped materials write it, through separate `*_height_map` pipelines, and gpu_culling splits batch commands into 4 groups (double sided × height map).

**Why:** the user asked whether a depth prepass fits the renderer. The answer was no, and the early-Z fix got committed as ef94a601.
**How to apply:** don't propose a depth prepass again unless the gbuffer fragment cost grows a lot. Re-measure first with the trivial-fragment-shader test. See [GPU pass timing](performance.md#measuring-correctly), [Crysis look-around perf](crysis.md#crysis-performance).

## Atomic counters disable early-Z

*the removed r_overdraw heatmap showed worst case, not real cost*

`goluwa/render3d/overdraw.lua` and the `r_overdraw` pvar no longer exist (removed 2026-10-10). The lesson stays: a fragment shader with side effects (an `atomicAdd` overdraw counter) loses early depth testing on this driver, so every surface behind another gets counted. On gm_construct (2026-09-30) the ground read 3-4 layers and the far tree band 16+ with the counter alone; adding `layout(early_fragment_tests) in;` dropped the ground to 1. `early_fragment_tests` can't stay on permanently: it writes depth before `discard`, which breaks alpha-tested foliage. For a true count use a counting variant with early_fragment_tests (alpha-test correctness is lost while counting) or a pipeline-statistics query. All world/prop geometry goes through `gbuffer_multi_draw`, the plain gbuffer pipeline draws nothing there. Related: [Depth prepass not worth it](#depth-prepass-not-worth-it).

## gpu_culling generation per publish

*same-generation republish left GPU buffers stale; garbage main view after spawns*

visual.lua rebuilds and publishes the scene acceleration whenever `scene_acceleration.dirty` is set. ScanWorldAABBs sets that flag without calling gpu_culling.InvalidateSceneAcceleration. Before 2026-09-25 this republished a new dataset under the same generation. ensure_dataset_buffers then skipped the upload, and IsCullResultCurrent still accepted old results.

Symptom: after spawning entities on gm_construct, the main view showed skybox props in the play area and the new entities were missing. GPU-culled shadows dropped casters.

Fixed: PublishSceneAcceleration now bumps the generation when the current one was already published.

**Why:** anything keyed on `dataset.generation` (buffer uploads, cull-result validity, per-output instance matrix uploads) assumes one generation means one dataset.
**How to apply:** if GPU-culled draws show wrong or missing instances, first compare the dataset buffers read back via Map() against the Lua dataset (entry order, batch records). Related: [Perf measurement pitfalls](performance.md#measuring-correctly)

## Async cull results were dropped

*HiZ wait discarded culls; drawn set lagged ~40 frames; lag = submit - published serial*

2026-09-27: `gpu_culling.WaitForCullsSamplingHiZ` waited on a pending cull's fence and cleared `cull_pending_serial` without collecting the result. When the GPU ran a frame behind, most culls were thrown away and `published_async_slot` stayed old. Symptoms: objects stayed culled after turning around, or appeared only after seconds or after moving (crysis_vegetation example). Fixed: the wait now calls `update_async_slot_completion`.

**How to apply:** if culled objects pop in late, measure `gpu_culling.main_view_submission_serial - gpu_culling.published_async_slot.cull_completed_serial` per frame. A healthy lag is 1-2. (test/tests/render3d/culling.lua passes.) Related: [gpu_culling generation per publish](#gpu_culling-generation-per-publish), [Import order in render3d](render3d-lighting.md#import-order-in-render3d)

## CPU instancing path verification

*occlusion/GPU culling bypass the CPU queue; which flags reach the shadow batcher*

`gbuffer_instancing.Queue` (visual.lua draw_geometry_entry / DrawEntriesForPass) is skipped for visuals using occlusion culling (default on → `using_conditional_rendering`), and with GPU culling on static batches go through `DrawGPUCulled`. To exercise the CPU queue in a tmp script: `gpu_culling.SetEnabled(false)` and `visual:SetUseOcclusionCulling(false)` per visual; 5 cubes sharing mesh+material → instanced_draws=1.

Shadow CPU batching (`InstanceBatcher` in shadow_map) runs only with GPU culling on: `DrawGPUCulled` fallback entries, or `DrawVisibleComponents` when `Visual.Library.noculling = true`. With GPU culling off shadows draw per component, unbatched. `test/tests/render3d/instancing.lua` and `batch_table.lua` cover the batchers.

**Why:** a naive scene showed 0 queued instances both before and after the refactor, which looks like a regression but isn't.
**How to apply:** when touching gbuffer/shadow batching, use the setup above and compare against a baseline from a copy or worktree (never `git stash`, the user commits while you work).

## LOD system

*GPU-side level selection, dither crossfade via world[0][3], Source fixup lod arrays, Cry $LOD nodes, Crysis billboards*

LOD is chosen in the two GPU cull shaders (gpu_culling.lua main_view_linear and shadow_view_aabb), not on the CPU.

- Polygon3D carries `LODLevel`, `LODDistance` (in bounding radii of the visual) and `LODBillboard`. `Visual:RebuildRenderEntries` keeps only the lowest level in `RenderEntries` (BVH, raycast, grass, translucent, CPU draws all see LOD0 only) and puts every level in `GetLODRenderEntries()`, which only gpu_culling serializes. Entries get `lod_level/lod_near/lod_far/lod_last`; entry flag 0x4 marks them, so scenes without LODs take no new path.
- Ratio = distance(camera, visual aabb center) / (sphere_radius * lod_scale). The main pass fades: around a switch both levels are drawn, the fade (-1..1, 0 = none) is written into `world[0][3]` of the instance matrix (affine matrices leave it free), the gbuffer vertex stages output `lod_fade` and `discard_lod_fade()` dithers with complementary patterns. Shadow passes hard switch. Non batched entries (translucent, ignore_z) also hard switch.
- pvars (Rendering / LOD): `lod_level` (-1 auto, N forces, past the last clamps to the last, billboard counts as last), `lod_scale`, `lod_fade` (band half width as fraction of the switch distance). `LODSettingsChanged` bumps shadow_visible_list_version.
- Source: VVD fixups are per lod. The lod-n vertex array is the lod 0 array filtered by `fixup.lod >= n` (vvd.Decode returns `vertex_lods`), and a mesh's VTX ids count from the filtered rank of its lod 0 base (verified: max id = lod_vertex_count[n]-1). Negative VTX switch point = shadow lod, skipped. Radii = switch_point * 0.5 (calibrated guess, not from the engine). Skins are shared across lods only when no vertices were filtered, flexes only on those.
- Cry: `$LODn_name` nodes inside the cgf (were skipped by the `$` rule) and `name_LODn.cgf` siblings; level n starts at 6*n radii (guess, cryengine stores no distances).
- Billboards (render3d/billboard.lua): for vegetation prototypes with `UseSprites=1`, `Visual:SetBillboard(true)`. Bakes two orthographic side views through ModelPreview into one atlas (dilated, mipmapped), two crossed quads, last level at max(14, last mesh level + 6) radii. The atlas gets a CPU mip chain whose alpha is rescaled per level to keep the alpha-test coverage (plain mips make sparse foliage vanish at distance), and the quads copy DiffuseTransmission/TransmissionColor from the model's first alpha tested material. `Visual` must not apply MaterialSlotOverrides/MaterialOverride to LODBillboard polygons (it did once: leaf texture stretched over the quads, far forest looked gone). Billboards look a bit grayer than lit leaves.

**Why:** user asked for LOD for Source and Cry assets, billboards for Crysis vegetation, a pvar override and smooth transitions.
**How to apply:** before touching culling or entry lists, remember LOD1+ entries exist only in the GPU dataset. Test with the `lod_level`/`lod_scale` pvars and `glw --3d shot`. See [gpu_culling generation per publish](#gpu_culling-generation-per-publish).

## Scene view / model preview / model viewer

*SceneView+Environment+view_resolve, AutoRender viewer, atmosphere-shader env presets; frame UBO cache, per-cmd descriptor ring, same-frame probe slot reuse, harness has no BRDF LUT*

The model preview is now deferred + PBR: `ModelPreview` (thin) -> `SceneView` (goluwa/render3d/scene_view.lua: camera, size, preset, output Framebuffer) -> a shared pipeline bundle per (preset, render size) run through `render3d.RunPipelineBundle` with a render context -> `view_resolve` (exposure + tonemap + supersample into r8g8b8a8_srgb, straight alpha). The texture memory is upright (row 0 = top), but render2d shows render-target textures vertically mirrored, so `ModelPreview:Draw` must keep `PushColorUV(0, 1, 1, 0, 0)`; dropping it made every thumbnail upside down. `Environment` (environment.lua) owns an envprobe probe baked from an HDR file or the procedural studio (`Environment.GetShared()`), shared by all previews. The old forward Blinn-Phong pipeline lives on as `forward_preview.lua`, only billboard baking uses it (it needs unlit albedo; port it via a `lighting_albedo` preset later).

Context fields a view sets: `camera` (auto Push/PopCamera), `render_size`, `lights`, `environment`, `transparent_sky`, `draw_geometry` (replaces the Draw3DGeometry scene draw in the gbuffer pass), plus the existing `allow_*`/`ocean_enabled`. A view-only seam for split screen is `SceneView:Render(cmd)`; a preset that keeps history needs its own bundle per view (bundles are shared by size today).

**Model viewer (2026-10-09):** `addons/editor/lua/model_viewer.lua` is a Window with a perspective `OrbitCamera` (goluwa/render3d/orbit_camera.lua), an environment dropdown, background/auto rotate/exposure controls, opened from the asset browser (View button, double click, context menu). It uses a `SceneView{AutoRender = true}`: `view:Invalidate()` makes the PreRenderPass listener draw it in the frame's own cmd, no stall; AutoRender is off until the size is known and the model loaded. Views release their shared bundle on removal (refcount, freed 5 s after the last user), and the viewer renders at multiples of 16 px after a 0.25 s resize debounce. `Environment.presets` / `GetPreset(name)`: Studio plus shader ones, a `Shader` is any render3d/atmospheres module defining `get_atmosphere(dir, sun_dir, cam_pos)` (nishita, temple), rendered with `Texture:Shade` into an equirect (top row up, like an hdr file) and used for the full resolution background; `Ground` adds a sky-lit ground since nishita is black below the horizon. night_sky.lua is not standalone (needs the atmosphere prelude), the physical atmosphere is not offered yet.

**Orbit rule (user's choice, 2026-10-09):** the view follows the mouse like a panorama: dragging right moves the background right (camera goes around the target to the right, `Yaw += dx`), dragging down moves it down (`Pitch += dy`), so a model's near side moves the opposite way. `OrbitCamera` is shared by the viewer window and the asset browser's detail preview; the detail preview no longer rotates the entity with Euler angles, it sets `ModelPreview:SetViewOffset(orbit:GetViewOffset())` and the model stays still. `OrbitCamera.New()` works without a camera.

**Pitfalls (each cost a debugging round):**
- `envprobe.PrefilterProbe` used to release the cubemap's bindless slot right after recording, so a second probe baked in the same frame got the same slot and the first one's draws sampled the wrong cube (black probe). Releases are deferred to the next PreRenderPass now, and skip pipelines removed by `CreatePipelines` (an error in that listener stopped the others and DDGI never traced).
- `ComputePipeline`/`RayTracingPipeline` `OnRemove` never unregistered their `TextureRemoved`/`TextureViewChanged` listeners (graphics did), so a freed compute pass threw `attempt to call method 'RefreshTextureView'` the next time any texture finished loading. Compute pipelines were rarely removed before; the viewer's bundle is freed 5 s after it closes. Fixed, test/tests/render/pipeline_removal.lua.
- The engine's projection has NDC y pointing down (a +y world point has ndc y < 0); right is +x. Check conventions numerically before writing sign tests.
- `T.Test3D(name, function(draw)`: `draw()` runs a whole frame including PreRenderPass listeners, use it to test frame-cmd paths.
- Preview entities must be `visual:SetVisible(false)` or they also render in the world (the gallery forgot, fixed).
- The contour banding on the gallery's sphere tiles is a harness/viewer artifact (user confirmed), see [Screenshot banding can be a viewer artifact](performance.md#screenshot-ab). Don't chase it.
- gbuffer camera UBO has `upload_scope = "frame"`, cached by frame number: two runs of one bundle in a frame reused the first camera. `RunPipelineBundle` now calls `pipeline:ResetFrameUploads()` first.
- Compute passes hand out descriptor sets per command buffer *object* (16 per pipeline per cmd, ring resets only when the cmd changes). `RenderNow` records into a fresh cmd each call; reusing one cmd dies after ~48 renders ("descriptor set ring exhausted"). Such cmds set `cmd.gpu_timing_disabled`, otherwise gpu_timing makes a query pool per cmd and its removal calls device WaitIdle.
- Textures registered in a push-constant `write` come after Bind, so the first draw samples a stale descriptor (first render empty). Register in `on_pre_draw` like blit does.
- `light_occlusion.Draw` iterates `render3d.GetLights()`: with overridden lights it wiped the world's occlusion maps, so lighting skips it when `AreLightsOverridden()`.
- Probe layout transitions must be recorded in the same cmd as the first bake. Creating a probe mid-frame put them in the frame cmd, which runs after the one-shot submit, so the probe stayed undefined.
- Test harness (`T.Test3D`): `assets.GetTexture("textures/render/brdf_lut.lua")` is nil there and Material MetallicMultiplier defaults to 1, so a default material renders black. Use `MetallicMultiplier = 0` in preview tests.
- Ortho camera: every pixel has the same view direction, so a visible HDRI background (`TransparentSky = false`) is one flat color. Needs a perspective option.
- A pixel test of the texture cannot catch an orientation bug in how it is drawn: check a screenshot of the UI with an asymmetric model (cone: apex up).
- `Screenshot{update_events = n}` runs n Update events inside one frame, so n previews per tile can exhaust the descriptor ring.

**How to apply:** when adding another view/preset, start from `presets` in scene_view.lua, check every module-level global the passes read (`render3d.GetLights`, atmosphere/envprobe state, frame-scoped UBO caches) and verify with two views in one frame. Related: [HDR environment override](render3d-lighting.md#hdr-environment-override), [Test3D harness passes](#test3d-harness-passes), [Scene color is pre-exposed](render3d-lighting.md#scene-color-is-pre-exposed).

## Test3D harness passes

*only gbuffer + blit exist in Test3D; overlay/lighting don't run there*

`test/test_render.lua` `Init3D` calls `render3d.Initialize{passes = {gbuffer, blit}}`. Inside `T.Test3D`, the forward overlay, lighting, translucent and other passes don't exist, so e.g. `IgnoreZ` materials never draw and `T.GetScreenPixel` reads the blitted gbuffer scene. Tests that need other passes re-initialize render3d with their own pass list (`test/tests/render3d/translucent.lua`).

**Why:** on 2026-09-27 a "forward overlay never culls" finding came from a Test3D reading the screen: the overlay upload was called 0 times and the screen centre was red with no quad at all. The full engine culled correctly.
**How to apply:** before trusting a screen-pixel test of a pass, check the pass is in the bundle (count calls to its upload function) and read a no-geometry baseline. For full-engine checks use a `--3d` tmp script with `Screenshot`. Related: [Test3D: max 16 draws per test](#test3d-max-16-draws-per-test), [CPU instancing path verification](#cpu-instancing-path-verification).

## Test3D: max 16 draws per test

*17th silently stops rendering; sealed-room sky baseline is noisy*

Inside one `T.Test3D` body, `draw()` more than 16 times fails with "EasyPipeline.ComputePass: descriptor set ring exhausted for frame 1 (17 > 16)". The PreRenderPass listener is removed, so later draws render nothing. A GI readback then returns the previous values and looks like a plausible measurement.

**How to apply:** budget draws across all measurements in a test (e.g. 4 draws × 4 measurements) and grep test output for "rror" when numbers look repeated.

Also, DDGI's sealed test rooms pick up a noisy sky baseline (16–35 in `gi_mean` sums) that varies per `ResetHistory`. Leak tests need a light bright enough to dwarf it, see [DDGI without ray tracing](render3d-lighting.md#ddgi-without-ray-tracing).

## Test scene material defaults

*MetallicMultiplier defaults to 1; Material.New ignores Color/Roughness keys*

`Material:GetSet("MetallicMultiplier", 1.0)`: a material with no metallic texture is fully metallic. A `shapes.Material{Color = ..., Roughness = ...}` scene without `Metallic = 0` renders every surface as a tinted mirror, which looks like a shading bug (e.g. translucent glass reading milky white because F0 = albedo).

`Material.New{...}` calls `Set<Key>` only when that setter exists and otherwise just stores the field, so `Color`/`Roughness` do nothing there; use `ColorMultiplier`, `RoughnessMultiplier`, `MetallicMultiplier`. (`shapes.Material` is different: it maps `Color` to an albedo texture and `Roughness`/`Metallic` to 1x1 textures.)

**Why:** cost a debugging detour while validating the forward translucent pass (2026-09-25).
**How to apply:** set metallic to 0 explicitly in any tmp/ or test scene before judging shading. Related: [GI measurement needs an exposure lock and a real camera](render3d-lighting.md#gi-measurement-needs-an-exposure-lock-and-a-real-camera)

**Update 2026-10-03:** `shapes.lua` moved to `goluwa/render3d/shapes.lua` (import it directly, `import("lua/shapes.lua")` is gone) and `shapes.Material` now defaults MetallicMultiplier 0 and RoughnessMultiplier 0.6 unless the config gives Metallic/MetallicMultiplier or Roughness/RoughnessMultiplier. Raw `Material.New{}` is still fully metallic. tmp scripts that import "lua/shapes.lua" need the new path.

**Update 2026-10-03 (later):** `Material.New` now takes what `shapes.Material` took: `Color`, `Shared`, and for texture properties a color/number/GLSL string via `Material.ResolveTexture` (`Albedo = Color(...)`, `Roughness = 0.5`), and an unknown key is an error (it used to be stored silently). `shapes.Material` is just `Material.New` plus the matte defaults (metallic 0, roughness 0.6 when unset); those can't live in `Material.New`, since loaders create a bare material and set textures later, and glTF's metallic/roughness factor of 1 only makes sense next to a texture. Callers that hold GLSL under texture keys (example_materials) must strip them before `Material.New`.

**Update 2026-10-03 (multipliers):** `Material.New` no longer makes a solid texture for a color or number. `Color`/`Albedo = Color` sets ColorMultiplier, `Emissive = Color` EmissiveMultiplier, and `Roughness = 0.5` / `Metallic = 0` / `Specular = n` set the multiplier, with no texture bound (debug_draw already ran this way). Only strings (GLSL) and textures become textures, and colors/numbers on a property without a multiplier still fall back to `Material.ResolveTexture`'s cached constant texture. `Color` together with `ColorMultiplier`, or with `Albedo`, is an error. Rendered pixels matched the texture version within GI noise (crate 133,79,91 vs 130,78,90).

## Material versions and what is cached on them

*`property_version`, `Material:Touch()`, upload keys, the uniform offset memo, batch records*

A property declared with `versioned = true` (all of Material's, `Material:StartStorable({versioned = true})`) stamps its object with a new `property_version` when it is set to a different value, and the object goes into the ring `objects.version_log` (65536 slots, `objects.version_counter` is the newest stamp, a consumer that is more than `VERSION_LOG_SIZE` stamps behind has to check everything). Changing a vector or color of a material in place, or writing a field directly, is invisible to it: call `material:Touch()` afterwards (material proxies do, and only when a proxy changed something, a `Touch` every frame rewrites that material's batch records every frame).

Everything that is derived from a material follows the version instead of being worked out per draw:

- `model_pipeline.GetPBRFactorUploadKey`/`GetPBRAuxUploadKey` and the feature block keys keep their answer on the material for one version.
- Pipelines whose uniform buffers are all per frame or declare `memo_key` (`model_pipeline.GetMaterialMemoKey`: the material and its version, nothing for a material with vertex animation) keep the dynamic offsets of the last upload per key and frame (`uniform_memo` in `easy_pipeline_graphics.lua`), the same as what each block's own frame cache would return, just one lookup. A new uniform buffer on such a pipeline that depends on more than the material must not declare `memo_key`, which turns the memo off for the pipeline.
- `BatchTable` (multi draw batch records of the gbuffer and the shadow passes) writes a record when its batch is another object than the one the index was written from, when the material of the batch was stamped, for the animated part of an animated batch when `animation_version()` changed (`write_animated`, the wind: `atmosphere.GetWindVersion`, bumped by `SetWind` when the vector differs, the times of the wind are not in it because the multi draw shaders take them from the frame), and 4 records per update as a safety net. A change of `batch_serial` (a row was set or cleared) or a freed buffer that had a device address (`Buffer.address_release_serial`) only makes it look at every index again: the batch objects are compared by identity (a row table is replaced when its mesh or material changes) and, after a release, the addresses of the mesh against the record, so only what differs is written. It used to rewrite all records (17k on Quarry, 65-300 ms for each of the 6 tables) on every such change, which while flying was every few frames. Each frame's buffer is kept mapped and gets the records it is behind on. Tests: `test/tests/render3d/batch_table.lua`, and `test/harnesses/m3/verify_caches.lua` compares every record against a from-scratch write on the real map.
- `Visual`'s translucent and glass collection keep per component what is true of its entries until the entries, the material override or a material version changes, and per entry what is true of its world matrix until the matrix changes (compared by content).

Per draw paths that have a bound pipeline use `pipeline:UploadConstantsBound()`, which skips `GraphicsPipeline:Bind` (every dynamic state setter) when the pipeline is already bound and only pushes constants and rebinds descriptor sets; the draw sets the dynamic state it needs itself (cull mode, blend).

## Visual CullDistance is 1000 km

*very far test geometry vanishes but still casts shadows*

`goluwa/entities/components/visual.lua`: `Visual:GetSet("CullDistance", 1000000)`. Anything whose AABB is more than 1000 km from the camera is not drawn, though it still renders into shadow maps. For distant test geometry (mountains), call `ent.visual:SetCullDistance(0)` (0 = unlimited). The default was 2000 when this was found (2026-09-27), it is 1000000 now (the camera FarZ is 1000000 too, raised with reverse-Z). A FarZ of 4000000 turned the ocean pass to inf/nan (whole frame white), 1000000 and 400000 are fine. Related: [Test scene material defaults](#test-scene-material-defaults)

## Mirror test scene

*BVHSceneReady-driven capture, CreatePlane normal flip, colored-box control*

Traced reflections (screen space misses -> scene_reflection ray queries on the ddgi TLAS) only work once the BVH is built, which waits several seconds. Drive captures from the `BVHSceneReady` event plus `Shot.Capture(..., {settle = 4})`, not from wall-clock time. test/harnesses/mirror_shot.lua does this; test/harnesses/mirror_scene.lua is the scene (mirror wall, alyx and red/green control boxes behind the camera, `Visual.Library.noculling = true`).

`Polygon3D:CreatePlane(pos, normal, ...)` produced a face pointing opposite to `normal` (fixed 2026-10-03: plane/cube/sphere/heightmap builders moved to `shapes.BuildPlane(poly, pos, normal, ...)` etc. in render3d/shapes.lua, which derives right/up from the normal). A mirror built with the intended normal rendered only sky/ground plus a sky-pole circle and never showed scene geometry (traced rays started behind the plane and hit its back face). Pass the flipped normal, and always add a plain colored box as a control before blaming the animated BVH.

Frozen-BVH control: `scene_bvh.ANIMATION_DISTANCE = 0` leaves characters as their baked bind pose in reflections (Source bind pose is side-on). Traced hits shade from the soup material colour, so characters look grey in reflections, that is expected.

Related: [Skeletal animation](animation-and-source.md#skeletal-animation)

## shaderc is located by render.Initialize
`goluwa/bindings/shaderc.lua` no longer searches for the library, `render.Initialize` calls `render/shaderc_locator.lua` which fills `storage/bin/libshaderc/` (copies from the Vulkan SDK/system, or prompts: Steam, download, manual) and hands the loaded lib to `shaderc.Initialize(lib)` after a smoke compile. Without a TTY it errors instead of prompting. The download comes from this repo's `shaderc-<ref>` release and is verified against the sha256 in `goluwa/bin_manifest.lua`; the release is built by `.github/workflows/build-binaries.yml` (manual dispatch), then paste the hashes from its job summary into the manifest. Google's own CI download links returned 404 for their artifacts on 2026-10-11, which is why we build it ourselves.

## Surface features and the gbuffer layout

*one file per lobe, the layout packs itself*

`goluwa/render3d/gbuffer_inspect.lua` and `passes/gbuffer_inspect.lua` show the gbuffer decoded: `gbuffer_inspect.SetView{mode = "sheet", names = {...}}` draws the named entries (all of them without names) in a grid, `{mode = "targets"}` every raw packed target, `{mode = "field", name = "roughness"}` one full screen, `{mode = "target", target = "packed0", channel = "g"}` a raw packed target (`SetView(nil)` is the normal image). `SetPreview(view)` renders the same without replacing the screen, for a window to draw (`GetPreview`, `IsFullScreen`). The entries come from `gbuffer_layout.fields` plus albedo, alpha, emissive, depth and velocity, so a new surface feature shows up by itself. `GetSheets()` groups the entries in sheets, a field's `sheet` key (its own name by default, `clearcoat_rain` has `sheet = "clearcoat"`) says which, the first entry named like the sheet is its primary. A field's `max` (default 1) is its decoded value that shows as white (specular and the transmission tint are stored over 0 to 2). Sky pixels show dark grey because they only hold the gbuffer defaults. It routes through `post_source.GetDebugTexture`. Test: `test/tests/render3d/gbuffer_inspect.lua`.

`goluwa/render3d/features/*.lua` holds the surface features: core (base color, normal, metallic, roughness, AO, emission), specular, transmission, clearcoat, secondary_specular, sheen, specular_tint, weather_response (what a material asks of the rain and snow), and the ones that are only params: displacement (the height map), refraction, terrain (the weight texture and eight layers), vegetation, scatter and detail (second albedo and normal, detail texture, ground color, uv transforms). The vertex animation block is not one: it holds the wind and the time next to the material params, so only vegetation's params moved out of `material.lua`. The base blocks (`model`, `color_model`, `factor_model`, `aux_model`) are the core material and stay in `model_pipeline.lua`. They are listed in `surface_features.lua`, whose header comment documents every key and the scope of every GLSL snippet (`surface_features.New(list)` makes a registry of any list, which is how the tests use it). A feature is one table:

- **`params`**: material parameters. They become the `Material` GetSets (listed under the feature's `category`), fields of the factor block, and the check that skips the upload for a material with every param at its default. A param with `getter` (and optionally `getter_expression` of `v`) gets its GLSL getter generated. A feature with `block = "own"` and an `active(material)` function gets a uniform block `<name>_model` that is only uploaded for materials it is active for, and can have texture and color params; transmission (`DiffuseTransmission > 0`), displacement (`HasHeightMap`), terrain (has a weight texture) and detail (has any of its textures or a uv transform) do. A param with `block = false` stays out of the block and is read through the material, and a param can set its own `category` from there on. `block = "none"` is for params the Lua side reads through the material, like refraction's, and gives them no block.
- **`fields`**: what the gbuffer stores. A field with a `member` (its own name unless it says another, `false` for none) also gets its `Surface` member, default, decode and gbuffer write generated, and `material` is the GLSL expression that fills the member from the material. A plain scalar feature like sheen needs no snippet for building a `Surface`, only its lobes.
- **Building a `Surface`**: `surface_members`, `surface_default`, `material_init`, `weather`, `surface_decode`, `surface_finish`, `gbuffer_write`, besides the generated parts. The same `Surface` is built by the gbuffer pass (`init_` or `default_surface_features`, `apply_surface_weather`, `weather_surface_features`, `write_surface_features`), the forward translucent pass (`init_surface_features`, then it overrides what it computes itself) and the lighting pass (`decode_surface_features`).
- **Lobes**: `direct_peak`, `direct_shadow`, `direct_layer`, `direct`, `indirect`, `indirect_layer`, spliced into `get_direct_light` and `get_indirect_light`.
- **Other passes**: `reflection` (the reflections pass traces off the smoothest lobe, a feature sets `N` and `roughness`) and `thin` (becomes `gbuffer_is_thin`, which ambient occlusion uses).

Geometry that is not a scene model (scattered models, see [scatter.md](scatter.md)) is a gbuffer extra, listed in `gbuffer_extras.lua` in draw order. An extra has `name`, `BuildPass(gbuffer_pass)` (optional: scatter draws with the `gbuffer_multi_draw` pipeline and names it), `PreDraw(cmd)` (before the render pass, for compute) and `Draw(pipeline, cmd)` (inside it, after the models are flushed), and `gbuffer.lua` loops over them, skipping a bundle that has no pipeline of that name. `geometry_block.New(name, fields, write_extra)` is the per frame uniform block they share: camera, previous camera, weather and their own fields.

The translucent passes have the same kind of list, `translucent_extras.lua` (the particle system, [particles.md](particles.md), is the one entry). An extra has `name`, `IsActive()`, `BuildPasses()` (its `<name>_moments` and `<name>_accumulate` configs) and `Draw(pipeline, cmd)`, which run inside the translucent moments and accumulate passes after the models. What those passes share (the moments glsl, the blend states, the depth warp) is in `translucent_moments.lua`.

Weather first asks the surface what it wants (`prepare_surface_weather`, the `weather_input` snippets: core derives the porosity from roughness and metal, transmission makes thin surfaces waxy, weather_response scales porosity, wetness and snow by the material's params) and then runs (`apply_surface_weather(inout Surface, inout SurfaceWeather)`) changes the base color, roughness, metallic and normal itself, and leaves snow, the rain film and its exposure in a `SurfaceWeather` that the `weather` snippets react to: core takes snow out of AO and emission, specular goes to ice, clearcoat takes the rain film, transmission thins.

`gbuffer_layout.lua` packs `fields` into targets: `unorm8` is a channel of an rgba8, `unorm4` half of one (16 steps, two fields per channel, set through `gbuffer_flush_packed()` which every writer ends with, read unfiltered), `unorm16` a channel and `octa` two channels of an rg16 or rgba16. Fields are ordered by their `readers` so the ones one pass reads sit next to each other; it errors past 8 targets (8 now, with 2 of the 16 rgba8 channels free). `gbuffer_layout.Pack(fields)` is the packer on its own. Decoders (`gbuffer_<name>`), encoders (`gbuffer_encode_<name>`, from `encode`) and `gbuffer_set_defaults()` are generated, and both gbuffer writers call it first.

**Stage order matters:** features run in list order within a stage. `direct_layer` runs before the base lobe is added (clearcoat attenuates `radiance`, transmission lowers `diffuse_weight`), `direct` after it, with what the layers left. `indirect_layer` (clearcoat) runs over everything `indirect` made, so list a feature that adds ambient light before one that layers over it. Core must stay first: it decodes the members the others read.

**Reflections:** the reflections pass launches the ray traced reflection from the same place as the screen space one, after the `reflection` snippets, so a feature's coat or smooth lobe moves both. What a reflection ray hits (and what a DDGI probe ray hits) is shaded as lambert from the BVH's material (`ddgi_material`), so no feature's lobe or transmission shows in a reflection or in GI; giving the hit a feature's params would mean putting them in that buffer.

**Adding a feature:** write `features/<name>.lua`, add it to `default_list` in `surface_features.lua`. Not covered yet: the sheen and secondary lobes don't take energy from the base lobe, and nothing sets the new params from the Source or glTF importers.

**Surface debug views:** these are part of `gbuffer_inspect` now (the old `r_surface_debug` pvar and `surface_debug` pass are gone). The gbuffer pass writes a different normal while something is inspected: `SetNormalSource("vertex")` the interpolated vertex normal, `"map"` the tangent space normal map, `"combined"` (default) the final one, so the `normal` field view shows them. `SetTerrainOnly(true)` sets `terrain_only` in the camera block (every pass that uses `BuildPBRSurfaceGlsl` sees it): `terrain_layers_hidden()` makes a terrain material skip its layers, so the `albedo` view shows only the chunk's baked color texture. Both only apply while a view or a preview is active, and they change what the scene is lit with, not just the view. A normal field view draws a reference half sphere in the corner (the map one is not rotated into the world). Scatter (grass, rocks) is separate, `r_feature_scatter 0` hides it.

## Terrain tiles swap when the replacements are drawn

*a replaced tile goes when the culling that is drawn was dispatched after its replacements were shown; chunk textures are released 12 frames after their tile*

The terrain keeps a tile until its replacements are built (`IsTileReplaced`), then shows them (`tile.shown` = the frame) and removes the old tile once `gpu_culling.GetDrawnCullFrame()` (the frame the scene was in when the drawn main view culling was dispatched) is at least `shown` for all of them (`AreReplacementsDrawn`). A fixed delay (it was 5 frames) was both too short (a hole when the culling lag was longer) and too long (old and new overlap and z-fight). `RetireTiles` runs every frame for that. A removed tile's chunk goes through `PendingReleases` and is released `ReleaseFrames` (12) frames later: the bindless array replaces a released texture with the fallback and hands its index to the next texture, so a tile that is still in flight showed an error texture or another chunk's texture for a frame. The `terrain_tiles` console command (`Terrain:GetDebugReport()`) lists the counts and the tiles that should be drawn but are hidden without a blocker, not visible, or not in the gpu dataset.

`Terrain` `GridSize` (default 4) is the chunks per side of a level; the finer level fills the middle half, so the ring is GridSize / 4 chunks thick (8 = two rings, 48 tiles per level instead of 12). It must be at least 4: the two levels snap differently (2 chunks each) and the finer one can poke out of a thinner ring.

`test/harnesses/terrain/stress.lua` (no `--validate`) flies `terrain_debug.lua` from 100 to 3000 m/s with a 5 to 65 km teleport every 7 s and prints, every 2 s, the frame time and the inclusive time of every terrain stage (`SLOW FRAME` lines name the stages of frames over 100 ms; `PROF=1` adds the JIT profiler, `NOGC=1` stops the collector). What it found (2026-10-14): the build queue kept the entries of released chunks and was sorted whole every frame (17000 entries after 30 s, now compacted and the best few picked by a scan, ~400); `UpdateTiles`/`RetireTiles` compared every retiring tile with every desired and built tile every frame (`GetLevelChunkSize` did `2^level` inside, 9% of all samples; 20-37 ms at 1000 tiles, now 0.7 ms: tile bounds are fields, a tile's overlapping desired tiles come from the grid of every level (`GatherOverlappingDesired`) once per update, not per frame); tiles created while not blocked never got `shown`, so the tiles they replaced stayed; the bake textures were allocated and freed per chunk (vkAllocateMemory and `texture:Remove` ~9%), `ShaderSource` now pools them by size and format (`RecycleTexture`), and `ProcessPendingReleases` frees at most `ReleasesPerFrame` (8) chunks a frame. Median frame 41.6 to 32 ms, frames in 32 s of flight 610 to 700-750. Left: frames of 300-900 ms with only ~10-20 ms of terrain Lua in them (not the GC, `NOGC` has them too; a gpu or driver wait, `scene_bvh.BuildIncremental` is ~10-20 ms of the frames around them), a `CreateTile` of 60-190 ms now and then (vertex buffer allocation, `BuildPolygon` is ~1 ms of Lua per tile), and up to ~1800 tiles when flying faster than the bakes: retiring tiles wait for replacements that are not built yet.

The scene bvh was the biggest cost of terrain tiles (2026-10-14, stress harness): `scene_bvh.EnsureBuilt` was ~40% of the wall time, almost all of it `build_sah` (a cpu binned SAH build of every tile's ~8.7k triangles, ~12 ms a tile, the 4 ms budget is only checked between visuals). `Visual.InSceneBVH` (default true) keeps a visual out of the bvh (no soup shadows, gi, reflections or traced hits from it). `Terrain` `BVHLevels` (default all) says how many of the finest levels are in the bvh and `BVHDelay` (default 1.5 s) lets a tile enter it only after it has been wanted that long, because flying fast makes tiles that are gone before their bvh is built. Stress run (`BVH_DELAY=0` is the old behaviour, `BVH_LEVELS=0` has no terrain in the bvh): 807 frames, median 30 ms with delay 0; 1363 frames, median 18 ms with 1.5 s; 1897 frames, median 12 ms with `BVH_LEVELS=0`. A bvh of only the finest 3 levels was not better than all 8 (the near tiles are the ones that churn), so a level cut is for steady scenes. `Polygon3D.GridCells` (cells per side, set by `tiles.BuildPolygon`) tells the scene bvh that the first cells * cells * 2 triangles are a regular grid (two per cell, z major), and `build_grid` splits the cells in halves down to 2x2 blocks instead of the SAH build, the skirts after them still get a small SAH; test `scene_bvh.lua` 'builds a grid polygon from its grid' checks the same triangle set and a valid tree (2026-10-14: stress median 30 to 22 ms at `BVHDelay` 0, 18 to 15 ms with 1.5 s). What is left of a tile's bvh cost (profile of `BuildIncremental`): `get_piece` 29% (a 560 KB `local_tris` array per tile and the index copy and transform), `get_shape` 31% (grid 13%, `prepare_child_sah` bounds 10%), `bake_triangles` into the soup 19%, `insert_top_leaf` 16%, all proportional to the triangle count and done three times per tile: fusing them for a translated polygon, or giving the bvh a decimated copy of a tile (terrain `Samples` 65 means 8.7k triangles), is what is left. The frames over 100 ms that remain (3-20 per 40 s run) are mostly the garbage collector with a 1-5 GB heap: the live heap is ~950 MB (a third of it one-time shader compiler state, not per tile), and stopping the collector leaves 3-6 spans over 100 ms instead of ~19; `collectgarbage("setpause", 300)` + `("setstepmul", 400)` brought p99 from 98 to 33 ms but the max got worse, so there is no gc policy yet. Single calls of 110-160 ms also show up (`CreateTile`, `RemoveTile`, `vkFreeMemory`), with the collector off too. The stress harness can attribute a long frame: it flags on the wall time since its own previous call (the long part is in the span before its listener), `GC_MODE=tuned|stepped`, `NOGC=1`, `BVH_LEVELS=n`, `BVH_DELAY=s`, `LEAN=1` (no wrappers) are its switches.

Layout comparison (2026-10-14, `test/harnesses/terrain/layout.sh`, alpine terrain without scatter, four fixed views, PSNR against `Levels 8 GridSize 8 Samples 65`; the noise floor between identical runs is ~43 dB). The gpu frame is flat across layouts (5.6-6.0 ms at 1080p), the layout costs tiles, triangles, memory and load time (a fully loaded view: `8/4/65` 100 tiles 0.87M triangles 1.6 s, `8/6/65` 225 tiles 1.96M 2.8 s, `8/8/65` 400 tiles 3.5M 4.1 s, `7/8/65` 352 tiles 3.1M 3.9 s, `6/8/65` 304 tiles 2.65M 3.3 s). Looks: `7/8/65` is the same picture as `8/8/65` (38-50 dB, reach +-16 km); `6/8/65` is the same near (46 dB looking over the ground) but the far ranges are gone from a high view (31 dB, reach +-8 km); `8/4/65`, `8/6/65` and `7/6/65` (26-36 dB) smooth the mid-distance mountains and `7/6/65` has no far ranges (+-12 km). More samples do not buy it back: `8/4/129` (100 tiles, 3.4M triangles) and `8/6/97` (225 tiles, 4.3M) are still smoother than `8/8/65` (29-34 dB). The reason is the ring: a level's grid is snapped to 2 chunks, so the finer level can sit anywhere in a ring GridSize / 4 chunks thick and the nearest coarse tile can be as near as the ring is thin (GridSize 4: a chunk of margin and none when the snap is against you), so spacing relative to the nearest coarse tile is set by GridSize, not by Samples. Reach is `GridSize * 64 * 2^(Levels-2)` m across, so each level adds a ring only the far views show, and one level is 12% of the tiles at GridSize 8.

Default layout (2026-10-14): `Terrain` defaults to `Levels` 7 and `GridSize` 8 (the island and alpine examples use them; Crysis keeps `GridSize` 4, it streams a 30k visual level). Build order (`goluwa/render3d/view_priority.lua`, shared with scatter's bake order, test `view_priority.lua`; `Terrain.ViewPriority.OutsidePenalty` and `.PredictSeconds`): a tile with nothing drawn under it comes before a tile that only refines, inside that nearest first, where the distance is the nearer of the camera now and where it will be in 0.5 s (from a smoothed velocity, a jump of over 1 km is not a speed), to the nearest point of the tile's box, times 1 + `OutsidePenalty` (100) times how far the tile's bearing is outside the horizontal field of view plus 20 degrees, as a share of pi (looking mostly down counts everything as in view). It is a multiplier and not an offset on purpose: with a +2e7 offset for out of view, a tile under the camera that was behind it at the last update (the camera moves 125 m between updates at 2500 m/s) starved and flying backwards left 17% of the screen uncovered, a multiplier leaves a distance of 0 at 0. `test/harnesses/terrain/fill.lua` measures it (`OLD=1` ranks without the view, `SPEED`, `BACKWARD=1`, `SIDEWAYS=1`, `OUT_K=n`, `DEBUGHOLES=1` prints what an uncovered point is waiting for): after a teleport with a fixed view the time until the points on screen are all covered by a shown tile went from 1.0 s to 0.6-0.8 s (50% from 0.4 to 0.3 s) on the debug terrain, and flying at 2500 m/s forwards, sideways or backwards keeps 100% covered. A hard in-view first order was faster after teleports (0.4-0.55 s) and not safe while moving.

`Terrain` `BVHPerFrame` (1) lets one tile a frame into the scene bvh, the nearest first (a jump made hundreds due at once and `scene_bvh` built them all in one 300-490 ms frame, see scatter.md). A tile that replaces another and has a scatter set is looked at by scatter while it is hidden (`scatter.Preload`) and the old tile stays until its vegetation is baked (`ScatterWaitFrames`, `scatter.IsSurfaceReady`, the overlay shows the tiles that wait), see scatter.md 'Vegetation vanishes where terrain tiles swap'.

`terrain_stats` (`addons/debug/lua/autorun/render_3d/terrain_stats.lua`, data from `Terrain:GetStats()`) is the TERRAIN tab of the PERF window (`perf terrain`, the command prints the rows) with the build queue, gpu jobs, build rate and latency, tiles per level and a map of the tiles around the camera by state; `terrain_stats_map <level>` sets how far the map reaches.

Measure with `test/harnesses/terrain/coverage.lua` (`SPEED=150 TURN=120 SECONDS=30 luajit glw --3d --background --validate lua "./test/harnesses/terrain/coverage.lua"`): it flies over `addons/examples/lua/examples/render3d/terrain_debug.lua` and counts, per frame, how many drawn tiles cover points ahead of the camera (0 = hole, 2+ = overlap). Before the change: ~200 hole frames and ~1000 overlap frames per 3200; after: 0 and ~90 per 1900. The build queue is worked through every frame (`BuildsPerFrame`, default 2, was `BuildsPerUpdate` per 0.05 s) and re-prioritised every update (`UpdateTiles`): a desired tile with no built tile under it first, nearest first, a tile that only refines a drawn one after all of those. The replacements of one retiring tile share the priority of their best member, so they are built together: the retiring tile only goes once all are built, and the built ones wait hidden until then (built to shown at 150 m/s: median 5 to 2-4 frames, p90 35 to 17-21). It used to be `level * 16 + offset` fixed when the tile was queued, so while flying fast a stream of new fine tiles starved the coarse ones and nothing loaded until you stopped (400 m/s: holes in every frame, now 0 over 14 s). `terrain_debug.lua` is a bare rolling terrain: each lod level has its own hue, every chunk a white border, an 8x8 checker and its own brightness (the level reaches the color bake through `SelectChunkLayers`' layer ids). A top-down view from 700 m or higher renders as grey (atmosphere), use oblique views.

## Velocity of GPU-culled instances

*the multi draw gbuffer had no previous world, moving objects ghosted under TAA*

Until 2026-10-16 `CreateMultiDrawVertexStage` used the instance world as its own previous world, so everything drawn through `gbuffer_multi_draw` (nearly all scene geometry) got camera-only velocity: TAA left stripes behind fast objects and motion blur saw them as still. The main view's world array in `gpu_culling.lua` now holds two matrices per instance (`matrix_floats` 32: world, then previous world; the shadow view stays at 16). `write_entry_world` copies the old world over the previous one the first time an entry is written in a frame, and `prepare_view` resets the previous world of entries not rewritten since (a stopped object must not keep a stale velocity). The main cull shader writes `visible_instance_prev_worlds` (binding 16, `visible_instance_prev_buffer`) next to the visible worlds, and the vertex stage reads it through `gbuffer_draw.prev_instances`. Scatter points that at its own instance buffer (static). Shadow maps have no velocity, so a moving object's shadow still ghosts a little under TAA.

Motion blur (`r_motion_blur`, `passes/motion_blur.lua`) reads the same buffer. When the cull result is reused for a frame, an instance is drawn at the same place twice but keeps the velocity of its last step.

## HiZ mips are floor sized
*big plates near the camera culled as occluded; the top mips only covered the top left of the screen*

Vulkan mip sizes are `floor(dim / 2^m)`, so for 1920x1080 mip 10 is 1x1 and the old 2x2 reduce only read the top left of mip 9 (base px 0..1023), dropping the right and bottom remainder at every level. A large AABB near the camera picks a coarse mip, sampled only the near wall on the left and got culled as occluded (gi_reflections spot_room front wall pieces next to the door vanished, `r_feature_culling` off fixed it). The reduce pass in `gpu_culling.lua` now lets the last texel of a row or column take the remainder, and both cull shaders map uv to a texel with `uv * base_size / 2^mip`, clamped, so the two agree. Repro: `tmp/cull/shot.lua` style Shot with the camera from the report, compare with `r_feature_culling` off. A constant depth bias did not fix it.

## Moving objects drew behind translucent ones

*the async main cull copied instance worlds a frame or two early, opaque movers trailed glass*

2026-10-18: a body with an opaque and a translucent child, moving at 15 m/s past a still camera, showed the opaque box 1 frame (5 px) behind the glass, with `r_aa` none. Translucent draws, fallback entries and everything else on the cpu path use `transform:GetWorldMatrix()` of the frame. Opaque entries of a dynamic visual were batched in the main view (`entry.static_matrix_index`, `write_entry_world` every frame by `RefreshDynamicSceneVisuals`), and the main cull shader copies the instance world into `visible_instance_worlds` when the cull is dispatched. The drawn result is 1-2 frames old (the sync path was removed 2026-10-18, tests set `gpu_culling.wait_for_main_view` in `test_render.Init3D`), so the world was too. Not the interpolation or the transform parent: the Lua matrices of both children were identical at `Draw3DGeometry`, `PreDraw3DTranslucent` and `Draw3DTranslucent`. Switching `gpu_culling.SetEnabled(false)` or `SetAsyncMainViewEnabled(false)` made the offset 0.0 px. Fixed: `serialize_render_entry` does not make a dynamic entry `gbuffer_instancing_eligible`, so the main view draws it as a fallback entry from the cpu with the current and previous world (shadow views still instance dynamic entries, they are culled and drawn in the same frame).

**Why:** the visibility of a moving entry may be a frame or two late (a pop at the screen edge), its position must not be.
**How to apply:** when something moves relative to what draws next to it, compare it with `gpu_culling.wait_for_main_view = true` and `SetEnabled(false)` first. Repro: a `shapes.Box` with a dynamic body (`GravityScale = 0`, velocity set in `PhysicsUpdate`) and two children, one `Translucent`, a fixed `View` at 60 m with a narrow FOV, `Screenshot` at the speed peak and measure the box edges per row. TAA still leaves about 2 px between them (history), `r_aa` none is 0. 1000 moving boxes did not measure differently with the fix (22-33 ms vs 30-43 ms, noise is larger than the effect, unrepeated). Related: [Velocity of GPU-culled instances](#velocity-of-gpu-culled-instances), [Async cull results were dropped](#async-cull-results-were-dropped)

## Reverse-Z depth

The camera projection is reverse-Z (2026-10-18): `Camera3D:BuildProjectionMatrix` applies `Matrix44:ReverseDepth()` (`z' = w - z`) to perspective and ortho alike, so near maps to 1 and far to 0 in the `d32_sfloat` depth. The gbuffer clears depth to 0 (`DepthClear = 0.0`, framebuffer `depth_clear`) and every depth-testing 3D pipeline uses `greater_or_equal`. Far terrain stopped z-fighting.

- The sky is `depth == 0`, not 1. `depth <= 0.0` means sky, `depth > 0.0` means a surface. "Further" is a smaller depth, so min and max swap (Hi-Z reduce in `gpu_culling.lua` keeps the min, the froxel tile depth keeps the min, TAA's closest neighbour is the max).
- Anything that rebuilds a ray from `inv_projection` with depth 0 and 1 as near and far has them swapped: `get_view_ray` did this and flipped the ocean's rays until it was fixed.
- Absolute depth tolerances are now relative: a reversed depth near the far plane is tiny, so `+ 4e-7` in `get_geometric_normal` is `4e-7 * depth` and the Hi-Z bias is a fraction of the sampled depth.
- Shadow maps keep their own standard-Z projections (`Matrix44:Perspective`/`Ortho` are unchanged, only the camera reverses). The forward overlay draws into the swapchain, which is still cleared to 1 (Love uses it), so it flips its matrix back.

## The frame number is not unique per recorded frame

*a blocking callback wait draws a second frame with the same `system.GetFrameNumber()`*

`callback:Get()` on an unfinished callback pumps `event.Call("Update")` while it waits (`pump_blocking_get` in callback.lua), and `render.Draw` is an Update listener, so a blocking wait inside an Update (the Sun dial's Shadows tab mounting its editor took a 300 ms frame with one) records and presents a whole extra frame inside the same main loop iteration: two frames with one `system.GetFrameNumber()`. `scene/draw.lua` rotated the main cull's descriptor set and its args buffers by that number, so the second frame updated a descriptor set the first frame's command buffer still held (a `vkUpdateDescriptorSets` validation error, and the args buffer was overwritten under the gpu). They use `render.frame_serial` now, which counts `render.BeginFrame` calls.

**How to apply:** rotate anything the gpu reads over frames (descriptor sets, ring buffers) by `render.frame_serial`, not by the frame number. The ping-pong history targets of the passes (taa, ssao temporal, ocean foam, glare, envprobe) still use `system.GetFrameNumber() % 2`, so in such a frame they read the target they write; a one frame glitch, not an error. Repro: switch the Sun dial to its Shadows tab in a `--validate` run, it failed every time before the fix.
