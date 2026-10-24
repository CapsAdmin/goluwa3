# Performance measurement and optimization

Re-measure before trusting any number; run-to-run variance is large (see below).

## Measuring correctly

- Never benchmark with `--validate` (validation roughly triples CPU frame time). Always pass `--background`. A stray engine process doubles GPU numbers: check `pgrep -af "[l]uajit glw"` first.
- The JIT profiler (`PROF`, see debugging-and-profiling.md) only samples Lua CPU time. Time blocked in fence waits does not show up, so "slow frame but idle profile" means a GPU sync. It also pins C/FFI time on the wrong line, so confirm a hotspot with direct timing before optimizing. Never start `PROF` twice in one run.
- Time with `system.GetTime()`, never `os.clock()` (CPU time over all threads).
- Swapchain acquire / frame fence wait > 0 means GPU bound. About 0 with a bimodal frame-time histogram means a mid-frame CPU-GPU drain. The first `render.SubmitAndWait` of a frame blocks until the GPU finishes earlier frames, so its duration is about the GPU frame time.
- `render.BeginFrame` records render3d inside it (`target:BeginFrame` fires `PreRenderPass`); to time the GPU wait wrap `Wait` on the metatable `__index` of a live fence, not the imported template.
- `goluwa/render/gpu_timing.lua` records GPU timestamps per EasyPipeline pass plus `gpu_frame`. `SetInfo(scope, key, value)` lets a pass attach what it worked on (pixels, rays, ...); `BeginCapture`/`EndCapture` average scopes over the frames between. Shadow maps use their own command buffers and are not in these scopes.
- Process-to-process variance is 10-20% for identical code (ray query passes come in a fast and a slow state; big scenes land in "heavy" or "light" states by translucent draw count). Compare variants alternating inside one process (put a throwaway first run before the real ones) or take medians over several processes, and check draws per frame to tell which state a run is in. Numbers before `BVHSceneReady` are junk.
- Env vars set to `""` are truthy in Lua. Build-time pvars (`r_rt_hit_*`, `reflection_reorder`) must be set through `GOLUWA_PVARS` (`goluwa/cli/pvars.lua`), see AGENTS.md.
- A change to shared GLSL makes the driver recompile every pipeline using it on the next run (see Caches), run twice.

## Screenshot A/B

Screenshot A/B: freeze time-driven things (`system.SetElapsedTime` from a high priority Update listener), lock exposure with `ExposureLock`, compare with ImageMagick `compare -metric PSNR`. Identical runs in one process give ~43 dB, across processes ~38 dB; below ~35 dB look at an amplified difference. Banding in smooth gradients is often a viewer artifact, crop at full resolution before chasing it.

## Benchmarks

- `luajit glw bench` lists `test/benchmarks/*.lua`; `luajit glw bench <name part|all>` runs those whose first line is `-- glw: <flags>`, one process each (`goluwa/cli/bench.lua`). A benchmark must end its own process (`--cli` scripts need `os.exit(0)`).
- `goluwa/render3d/frame_benchmark.lua` `Run{...}` is the scene benchmark harness: waits for `BVHSceneReady`, nothing loading and a stable bvh version, then measures phases (static, spin, move) and prints frame stats, allocation rate, gpu_frame and top gpu scopes. New scene benchmarks should use it. Each phase records draws per frame (needs `render.stats = true`); a different count than the baseline prints "scene in a different state".
- `goluwa/benchmark_results.lua`: results with a noise value are written to `storage/logs/bench/<name>/latest.json`; `--baseline` also saves `baseline.json`; later runs print `[COMPARE]` lines for moves beyond twice the combined noise. `--no-compare` skips it. Noise floors are `RUN_TO_RUN_NOISE` in frame_benchmark.lua.
- Micro benchmarks: `goluwa/benchmark.lua` (`Run`, `Compare` interleaved with paired ratio, `Finish`).

## LuaJIT

- Trace aborts and what to do about them: jit-trace-aborts.md.
- Fewer live locals, no alias locals, direct field access in hot code. Judge by trace abort counts (`-jv`, `jit.attach` logger), not one timing: you need 6+ alternating runs to see anything under 15%.
- "NYI: register coalescing too complex" only aborts side traces. At a side exit ALL locals in scope (including params and inlined caller frames, even dead ones) are snapshot values. Fixes: wrap temporaries in `do ... end`, `param = nil` after last use, tail calls, keep long-lived scalars in a plain scratch table (not Vec3, which is float32), split fused loops, hoist loop-invariant calls, guarantee number fields so `or 0` branches vanish. Check it is the real bottleneck first.
- No nested row loops in hot solver code: LuaJIT unrolls short inner loops into the outer trace until "too many spill slots" and blacklists the loop (bimodal step times). Use one flat task list.
- `loopunroll` is set in `goluwa/jit/options.lua` (`SetOptimized`); re-sweep it on a steady-state workload if physics code changes a lot (too large makes traces huge).
- Trace aborts reported as `blacklisted` are caused by earlier abort reasons. Trace compilation is non deterministic. Caching is not always a win: a function that looks slow may just be a trace abort, fix that instead. `error thrown or hook called during recording` can come from the profiler itself.

## Lua heap and GC

- `objects.CheckRemovedObjects` drains `objects.remove_these` on the next Update: a leak census in the same frame as `Remove()` reports everything removed. Wait ~10 frames and run `collectgarbage` several times. Compare heaps after full GCs only.
- `assets.GetModel(path)` caches the model forever; only use it for procedural `.lua` models (`model_loader.model_loads:Forget(path)` drops one). `Texture.New{path = ...}` pins the decoded texture in `texture_cache` by config key: give previews a unique `cache_key` and `Remove()` them, and never remove a texture whose `image` is `Texture.GetFallback().image`.
- Frame hitches of 90+ ms inside arbitrary passes are usually the collector. Fewer allocations make cycles rarer; large cpu-side copies of uploaded data (vertex tables, hulls) make them costlier. The engine sets no GC pause during play (`collectgarbage("setpause", ...)` trades memory for hitches); during scene load `r_loading_gc_pause` (`goluwa/render3d/startup_ready.lua`) is raised and restored when the scene is ready.
- Vulkan memory: mesh buffers up to 4 MiB are sub-allocated from 64 MiB blocks (`goluwa/render/vulkan/internal/buffer_pool.lua`) because one `vkAllocateMemory` per buffer dominates model loading. Meshes nothing else shares take `Polygon3D:UploadVertexArray(..., mode)` `"owned"` (no dedupe key string) or `"host"` (cpu-only, no gpu buffers).

## Where GPU/CPU time goes (general rules)

- GPU: DDGI, lighting, translucent/glass and ray traced reflections dominate; they are covered in render3d-lighting.md. Per-light and per-ray early-outs matter more than anything else in shaders: reject cheap cases (brightness, facing away, occlusion map) before the expensive ones (shadow map, screen-space march, ray queries), and march/trace last.
- Ray generation shaders with thread reordering (`ray_reorder`, `ray_generation` in `easy_pipeline_compute.lua`, see vulkan-raytrace.md) beat the same code as ray queries in compute for divergent hit shading.
- CPU draw submission: bind a pipeline once and rebind only descriptors per batch; read culling/soup data from FFI arrays, not scattered Lua tables; write batch records only when their source changed (`BatchTable` tracks material versions via `property_version`, wind via `animation_version`); cache per-material keys by `property_version`; never build strings per draw.
- Versioned properties (Material, `objects.lua`) stamp their object with a new `property_version`; call `Material:Touch()` after changing a vector or color in place.
- Big-scene CPU: key caches on a version counter that only moves when the data does (e.g. `emitter_version` (`render3d/scene/emitters.lua`)), not on a broad version like `soup_version`.
- `r_feature_culling` (gpu_culling.lua) switches off visibility culling to get the worst case: every visible-flagged visual drawn every frame. LOD selection is separate (`lod_level 0` for the most detailed case).
- Terrain/scatter streaming: bvh proxies are rays-only host copies at a coarser stride; bake height once per chunk into a field texture; share one index buffer per tile shape.

## Caches and the slow first start

1. `storage/cache/shaders/<crc32>_<length>.spv` (`shader_module.lua`): header, SPIR-V, then the GLSL it came from; a hit needs identical GLSL. Misses log `[shader] shaderc compiled ...` (GLSL to SPIR-V only; the driver step logs `[pipeline] the driver compiled ...`). shaderc is fast, this is not the slow part.
2. `storage/cache/vulkan_pipeline_cache.bin`: saved a couple of seconds after the last pipeline was made (a `--one-frame` run exits before that).
3. The NVIDIA driver cache (`~/.cache/nvidia/GLCache`, `~/.nv/ComputeCache`) is what makes a cold start take minutes: the driver compiles the huge lighting fragment shaders serially. Any edit of shared GLSL (gbuffer layout, lighting, surface features) costs a slow start once. `[pipeline] the driver compiled ...` is logged for pipelines taking 50 ms or more. Graphics pipelines are created on `thread_pool` workers and waited for at first bind (`GraphicsPipeline:Wait`), but the driver does not scale across threads; splitting big shaders is the remaining lever.

Cold start: `rm -rf ~/.cache/nvidia/GLCache ~/.nv/ComputeCache storage/cache/shaders storage/cache/vulkan_pipeline_cache.bin`. If something renders wrong only with one machine's cache state, clear the driver cache first: it is the one cache the engine cannot validate.

## Startup time

- `goluwa/startup.lua` is imported first in `main.lua`. `startup.Begin(name)`/`End(name)` record wall-clock spans; `local t = startup.Start() ... startup.Add(name, t)` accumulates totals for repeated work (`group: item` names group in the tab). `Add` is a no-op once the scene is ready. Name tasks (`task:SetName`) or they appear as `task: unknown`.
- "Ready" is decided by `goluwa/render3d/startup_ready.lua`: bvh built, nothing loading or spawning, bvh version unchanged for 1.5 s (not counted in the reported time). It does not see GI/exposure convergence. `GOLUWA_STARTUP_REPORT=1` prints the report; the STARTUP tab of PERF draws it.
- Measure by loading a map from a script, exiting when `startup.IsReady()` and printing `startup.GetReport()`. Noise is 0.3-0.5 s, compare 2-4 runs. The main thread is busy for the whole load, so only less work or more threads help; throttling frames while loading does not.
- Load levers in place: raised GC pause while loading; zip entries inflated on the worker pool (`vfs.Prefetch`, zip context only); terrain builds more tiles per frame and enters the bvh immediately while it holds the scene load; model decoders running on workers (below).
- Threaded model decoders: `model_loader.AddThreadedDecoder(id, {Gather, job, Finish})` (mdl and cgf use it). `Gather` runs on the main thread (workers have no vfs mounts) and returns the job input and size; `job` is the worker source returning a meta table plus a blob of packed vertices/indices (`packed_mesh.PackPolygon`); `Finish` runs on the main thread, makes materials/meshes and unpacks (`packed_mesh.Unpack`). A polygon made this way has empty `Vertices` until `GetVertices()`: code that reads a visual's polygon tables must unpack first.
- `goluwa/thread_pool.lua`: see animation-and-source.md "Threaded codecs".

## Device lost

See debugging-and-profiling.md.
