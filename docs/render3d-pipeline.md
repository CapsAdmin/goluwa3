# Render3D pipeline, Vulkan, culling, LOD and test scenes

Notes collected from past sessions. Dated numbers are snapshots; re-measure before relying on them.

## Running the suite on lavapipe in a cloud container

*Ubuntu + Mesa 25.2.8 lavapipe; limits, memory and the ddgi crash*

The cloud container has no GPU. Lavapipe reports one 15.7 GiB device-local heap that is just host RAM, and it cannot see the container's cgroup cap (13.4 GiB on a 16 GiB machine), so lavapipe memory is real process memory. Setup that worked: apt `mesa-vulkan-drivers vulkan-tools libvulkan-dev libshaderc-dev libwayland-dev libxkbcommon-dev`, LuaJIT built from the commit in `flake.nix`, libwayland 1.24 (the engine calls `wl_proxy_get_interface`), the LunarG SDK validation layers (Ubuntu's are too old for Vulkan 1.4), `libshaderc.so.1` symlinked as `libshaderc_shared.so`, and headless `weston --backend=headless` for `WAYLAND_DISPLAY`.

- **Memory:** one worker costs about 70 MB idle and a `render3d` file about 1.3 GB just to initialize (8 gbuffer pipeline variants at about 83 MB each plus the compute pipelines; only 174 MB of it is device memory, the rest is lavapipe's compile memory). Validation layers add about 25%. The runner starts another file only while `system.GetMemoryInfo()` shows 4 GiB of headroom. Finished worker Lua states are closed with `lua_close` now; before that every file leaked its whole engine (22 MB CPU-only, 32 MB with a device).
- **Limits lavapipe enforces that GPUs hide:** `maxStorageBufferRange` is 128 MiB (spec minimum). `scene_bvh` BLAS staging is capped to it.
- **Ray tracing:** lavapipe 25.2 advertises ray tracing. `GOLUWA_NO_RAY_TRACING=1` selects the fallback paths, which is probably what CI's older Mesa takes.
- **Open: `test/tests/render3d/ddgi.lua` "produces a screen gi texture" segfaults** in JIT-compiled shader code with or without ray tracing, even with one job. The faulting code is a waterfall loop (`tzcnt` over the active lane mask) that loads a buffer descriptor through a per-lane set pointer that is NULL, so heap corruption can then show up in unrelated tests. What is known: skipping the `ddgi_trace` or the `ddgi_shade` dispatch stops it, but each of them alone is fine; it needs real hits flowing from trace to shade. It is not the `scene_bvh_soup` descriptor array (constant-index chunk selection and `SOUP_CHUNKS = 1` both still crash), not the UV soup (`ddgi.ALBEDO_UVS = false` still crashes), and not the albedo/triangle read in `ddgi_hit_albedo` (reduced to a constant still crashes). Next steps: find which descriptor array the shade pass still indexes dynamically (`textures[nonuniformEXT]` through `ddgi_albedo`, light grid, materials), and test whether a newer Mesa fixes it.

**How to apply:** when a lavapipe run dies with `bad callback` PANICs or `free(): corrupted ...`, suspect shader memory corruption, not the Lua side; bisect by skipping pipeline dispatches (`pipeline:Draw()` in the render3d PreRenderPass loop), and use `LP_NUM_THREADS=0` under gdb to get the faulting JIT address.

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
- pvars (group lod): `lod_level` (-1 auto, N forces, past the last clamps to the last, billboard counts as last), `lod_scale`, `lod_fade` (band half width as fraction of the switch distance). `LODSettingsChanged` bumps shadow_visible_list_version.
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
- `light_occlusion.Draw` iterates `render3d.GetLights()`: with overridden lights it wiped the world's occlusion maps, so lighting skips it when `AreLightsOverridden()`. `glass_tint.WriteCascadeBlock` indexed pipelines the bundle lacks (guarded by `IsPassEnabled`).
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

Also, DDGI's sealed test rooms pick up a noisy sky baseline (16–35 in `gi_mean` sums) that varies per `ResetHistory`. Leak tests need a light bright enough to dwarf it, see [DDGI software trace](render3d-lighting.md#ddgi-software-trace).

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

*`property_version`, `Material:Touch()`, upload keys, the uniform offset memo, batch records, glass tint maps*

A property declared with `versioned = true` (all of Material's, `Material:StartStorable({versioned = true})`) stamps its object with a new `property_version` when it is set to a different value, and the object goes into the ring `objects.version_log` (65536 slots, `objects.version_counter` is the newest stamp, a consumer that is more than `VERSION_LOG_SIZE` stamps behind has to check everything). Changing a vector or color of a material in place, or writing a field directly, is invisible to it: call `material:Touch()` afterwards (material proxies do, and only when a proxy changed something, a `Touch` every frame rewrites that material's batch records every frame).

Everything that is derived from a material follows the version instead of being worked out per draw:

- `model_pipeline.GetPBRFactorUploadKey`/`GetPBRAuxUploadKey` and the feature block keys keep their answer on the material for one version.
- Pipelines whose uniform buffers are all per frame or declare `memo_key` (`model_pipeline.GetMaterialMemoKey`: the material and its version, nothing for a material with vertex animation) keep the dynamic offsets of the last upload per key and frame (`uniform_memo` in `easy_pipeline_graphics.lua`), the same as what each block's own frame cache would return, just one lookup. A new uniform buffer on such a pipeline that depends on more than the material must not declare `memo_key`, which turns the memo off for the pipeline.
- `BatchTable` (multi draw batch records of the gbuffer and the shadow passes) writes a record when its batch is new, when the material of the batch was stamped, for the moving part of an animated batch every update (`write_animated`), and 4 records per update as a safety net. Each frame's buffer is kept mapped and gets the records it is behind on. Tests: `test/tests/render3d/batch_table.lua`, and `test/harnesses/m3/verify_caches.lua` compares every record against a from-scratch write on the real map.
- `Visual`'s translucent and glass collection keep per component what is true of its entries until the entries, the material override or a material version changes, and per entry what is true of its world matrix until the matrix changes (compared by content).
- The glass tint maps are drawn again only when `glass_tint.IsSlotCurrent` says what they were drawn from changed.

Per draw paths that have a bound pipeline use `pipeline:UploadConstantsBound()`, which skips `GraphicsPipeline:Bind` (every dynamic state setter) when the pipeline is already bound and only pushes constants and rebinds descriptor sets; the draw sets the dynamic state it needs itself (cull mode, blend).

## Visual CullDistance is 20 km

*very far test geometry vanishes but still casts shadows*

`goluwa/entities/components/visual.lua`: `Visual:GetSet("CullDistance", 20000)`. Anything whose AABB is more than 20 km from the camera is not drawn, though it still renders into shadow maps. For distant test geometry (mountains), call `ent.visual:SetCullDistance(0)` (0 = unlimited). The default was 2000 when this was found (2026-09-27), it is 20000 now. Related: [Test scene material defaults](#test-scene-material-defaults)

## Mirror test scene

*BVHSceneReady-driven capture, CreatePlane normal flip, colored-box control*

Traced reflections (ssr misses -> scene_reflection ray queries on the ddgi TLAS) only work once the BVH is built, which waits several seconds. Drive captures from the `BVHSceneReady` event plus `Shot.Capture(..., {settle = 4})`, not from wall-clock time. test/harnesses/mirror_shot.lua does this; test/harnesses/mirror_scene.lua is the scene (mirror wall, alyx and red/green control boxes behind the camera, `Visual.Library.noculling = true`).

`Polygon3D:CreatePlane(pos, normal, ...)` produced a face pointing opposite to `normal` (fixed 2026-10-03: plane/cube/sphere/heightmap builders moved to `shapes.BuildPlane(poly, pos, normal, ...)` etc. in render3d/shapes.lua, which derives right/up from the normal). A mirror built with the intended normal rendered only sky/ground plus a sky-pole circle and never showed scene geometry (traced rays started behind the plane and hit its back face). Pass the flipped normal, and always add a plain colored box as a control before blaming the animated BVH.

Frozen-BVH control: `scene_bvh.ANIMATION_DISTANCE = 0` leaves characters as their baked bind pose in reflections (Source bind pose is side-on). Traced hits shade from the soup material colour, so characters look grey in reflections, that is expected.

Related: [Skeletal animation](animation-and-source.md#skeletal-animation)

## shaderc is located by render.Initialize
`goluwa/bindings/shaderc.lua` no longer searches for the library, `render.Initialize` calls `render/shaderc_locator.lua` which fills `storage/bin/libshaderc/` (copies from the Vulkan SDK/system, or prompts: Steam, download, manual) and hands the loaded lib to `shaderc.Initialize(lib)` after a smoke compile. Without a TTY it errors instead of prompting. The download comes from this repo's `shaderc-<ref>` release and is verified against the sha256 in `goluwa/bin_manifest.lua`; the release is built by `.github/workflows/build-binaries.yml` (manual dispatch), then paste the hashes from its job summary into the manifest. Google's own CI download links returned 404 for their artifacts on 2026-10-11, which is why we build it ourselves.

## Surface features and the gbuffer layout

*one file per lobe, the layout packs itself*

`goluwa/render3d/features/*.lua` holds the surface features: core (base color, normal, metallic, roughness, AO, emission), specular, transmission, clearcoat, secondary_specular, sheen, specular_tint, weather_response (what a material asks of the rain and snow), and the ones that are only params: displacement (the height map), refraction, terrain (the weight texture and eight layers), vegetation, grass and detail (second albedo and normal, detail texture, ground color, uv transforms). The vertex animation block is not one: it holds the wind and the time next to the material params, so only vegetation's params moved out of `material.lua`. The base blocks (`model`, `color_model`, `factor_model`, `aux_model`) are the core material and stay in `model_pipeline.lua`. They are listed in `surface_features.lua`, whose header comment documents every key and the scope of every GLSL snippet (`surface_features.New(list)` makes a registry of any list, which is how the tests use it). A feature is one table:

- **`params`**: material parameters. They become the `Material` GetSets (listed under the feature's `category`), fields of the factor block, and the check that skips the upload for a material with every param at its default. A param with `getter` (and optionally `getter_expression` of `v`) gets its GLSL getter generated. A feature with `block = "own"` and an `active(material)` function gets a uniform block `<name>_model` that is only uploaded for materials it is active for, and can have texture and color params; transmission (`DiffuseTransmission > 0`), displacement (`HasHeightMap`), terrain (has a weight texture) and detail (has any of its textures or a uv transform) do. A param with `block = false` stays out of the block and is read through the material, and a param can set its own `category` from there on. `block = "none"` is for params the Lua side reads through the material, like refraction's, and gives them no block.
- **`fields`**: what the gbuffer stores. A field with a `member` (its own name unless it says another, `false` for none) also gets its `Surface` member, default, decode and gbuffer write generated, and `material` is the GLSL expression that fills the member from the material. A plain scalar feature like sheen needs no snippet for building a `Surface`, only its lobes.
- **Building a `Surface`**: `surface_members`, `surface_default`, `material_init`, `weather`, `surface_decode`, `surface_finish`, `gbuffer_write`, besides the generated parts. The same `Surface` is built by the gbuffer pass and grass (`init_` or `default_surface_features`, `apply_surface_weather`, `weather_surface_features`, `write_surface_features`), the forward translucent pass (`init_surface_features`, then it overrides what it computes itself) and the lighting pass (`decode_surface_features`).
- **Lobes**: `direct_peak`, `direct_shadow`, `direct_layer`, `direct`, `indirect`, `indirect_layer`, spliced into `get_direct_light` and `get_indirect_light`.
- **Other passes**: `reflection` (the ssr pass traces off the smoothest lobe, a feature sets `N` and `roughness`) and `thin` (becomes `gbuffer_is_thin`, which ambient occlusion uses).

Geometry that is not a scene model (grass) is a gbuffer extra, listed in `gbuffer_extras.lua` in draw order. An extra has `name`, `BuildPass(gbuffer_pass)`, `PreDraw(cmd)` (before the render pass, for compute) and `Draw(pipeline, cmd)` (inside it, after the models are flushed), and `gbuffer.lua` loops over them, skipping a bundle that has no pipeline of that name. `geometry_block.New(name, fields, write_extra)` is the per frame uniform block they share: camera, previous camera, weather and their own fields.

The translucent passes have the same kind of list, `translucent_extras.lua` (precipitation is the one entry). An extra has `name`, `IsActive()`, `BuildPasses()` (its `<name>_moments` and `<name>_accumulate` configs) and `Draw(pipeline, cmd)`, which run inside the translucent moments and accumulate passes after the models. What those passes share (the moments glsl, the blend states, the depth warp) is in `translucent_moments.lua`.

Weather first asks the surface what it wants (`prepare_surface_weather`, the `weather_input` snippets: core derives the porosity from roughness and metal, transmission makes thin surfaces waxy, weather_response scales porosity, wetness and snow by the material's params) and then runs (`apply_surface_weather(inout Surface, inout SurfaceWeather)`) changes the base color, roughness, metallic and normal itself, and leaves snow, the rain film and its exposure in a `SurfaceWeather` that the `weather` snippets react to: core takes snow out of AO and emission, specular goes to ice, clearcoat takes the rain film, transmission thins.

`gbuffer_layout.lua` packs `fields` into targets: `unorm8` is a channel of an rgba8, `unorm4` half of one (16 steps, two fields per channel, set through `gbuffer_flush_packed()` which every writer ends with, read unfiltered), `unorm16` a channel and `octa` two channels of an rg16 or rgba16. Fields are ordered by their `readers` so the ones one pass reads sit next to each other; it errors past 8 targets (8 now, with 2 of the 16 rgba8 channels free). `gbuffer_layout.Pack(fields)` is the packer on its own. Decoders (`gbuffer_<name>`), encoders (`gbuffer_encode_<name>`, from `encode`) and `gbuffer_set_defaults()` are generated, and both gbuffer writers call it first.

**Stage order matters:** features run in list order within a stage. `direct_layer` runs before the base lobe is added (clearcoat attenuates `radiance`, transmission lowers `diffuse_weight`), `direct` after it, with what the layers left. `indirect_layer` (clearcoat) runs over everything `indirect` made, so list a feature that adds ambient light before one that layers over it. Core must stay first: it decodes the members the others read.

**Reflections:** the ssr pass launches the ray traced reflection from the same place as the screen space one, after the `reflection` snippets, so a feature's coat or smooth lobe moves both. What a reflection ray hits (and what a DDGI probe ray hits) is shaded as lambert from the BVH's material (`ddgi_material`), so no feature's lobe or transmission shows in a reflection or in GI; giving the hit a feature's params would mean putting them in that buffer.

**Adding a feature:** write `features/<name>.lua`, add it to `default_list` in `surface_features.lua`. Not covered yet: the sheen and secondary lobes don't take energy from the base lobe, and nothing sets the new params from the Source or glTF importers.
