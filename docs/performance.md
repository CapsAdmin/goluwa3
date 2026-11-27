# Performance measurement and optimization

Re-measure before trusting any number, including numbers in commit messages or earlier sessions; run-to-run variance is large.

## Measuring correctly

- Never benchmark with `--vulkan-validate`. Always pass `--background`. A stray engine process skews GPU numbers: check `pgrep -af "[l]uajit glw"` first.
- The JIT profiler (`PROF`, see debugging-and-profiling.md) only samples Lua CPU time on the main thread. Time blocked in fence waits does not show up, so a slow frame with an idle profile means a GPU sync. It also attributes C/FFI time to the wrong line, so confirm a hotspot with direct timing before optimizing.
- Time with `system.GetTime()`, never `os.clock()` (CPU time summed over all threads).
- A non-zero swapchain acquire / frame fence wait means GPU bound. A near-zero wait with a bimodal frame-time histogram means a mid-frame CPU-GPU drain. The first `render.SubmitAndWait` of a frame blocks until the GPU finishes earlier frames.
- `goluwa/render/gpu_timing.lua` records GPU timestamps per pass plus `gpu_frame` (the time the GPU was busy with the frame, overlapping graphics and async compute counted once). `SetInfo` attaches what a pass worked on; `BeginCapture`/`EndCapture` average scopes over a window. Passes on the async compute queue overlap the frame and run slower than alone, so compare async compute on/off (`GOLUWA_ASYNC_COMPUTE=0`) by `gpu_frame` or wall time per frame, never by pass scopes. Shadow maps record into their own command buffers.
- Identical code varies between processes (scenes can land in different states, e.g. by draw count). Compare variants alternating inside one process with a throwaway first run, or take medians over several processes, and compare draws per frame to see whether runs are in the same state. Do not measure before the ray tracing scene is ready and loading has finished.
- Env vars set to `""` are truthy in Lua. Build-time pvars must be set through `GOLUWA_PVARS` (`goluwa/cli/pvars.lua`), see AGENTS.md.
- A change to shared GLSL makes the driver recompile every pipeline using it on the next run (see Caches): run twice.

## Screenshot A/B

Freeze time-driven effects (`system.SetElapsedTime` from a high priority Update listener), lock exposure with `ExposureLock`, and compare with ImageMagick `compare -metric PSNR`. Establish the noise floor first by comparing two identical runs (in one process and across processes); look at an amplified difference image when a pair falls below it. Banding in smooth gradients is often a viewer artifact; crop at full resolution before chasing it. See screenshots-and-cameras.md for `Shot` and `FrameRecorder`.

## Benchmarks

- `luajit glw bench` lists `test/benchmarks/*.lua`; `luajit glw bench <name part|all>` runs those whose first line is `-- glw: <flags>`, one process each (`goluwa/cli/bench.lua`). A benchmark must end its own process (`--cli` scripts need `os.exit(0)`).
- `goluwa/render3d/frame_benchmark.lua` `Run{...}` is the scene benchmark harness: it waits until the scene is ready and stable, measures phases (static, spin, move) and prints frame stats, allocation rate, `gpu_frame` and the top GPU scopes. New scene benchmarks should use it. It records draws per frame and warns when a run is in a different scene state than the baseline.
- `goluwa/benchmark_results.lua` writes results with their noise to `storage/logs/bench/<name>/latest.json`; `--baseline` also saves `baseline.json`, later runs print `[COMPARE]` lines for moves beyond the noise, `--no-compare` skips that.
- Micro benchmarks: `goluwa/benchmark.lua` (`Run`, `Compare` interleaved with a paired ratio, `Finish`).

## LuaJIT

- Trace aborts and how to fix them: jit-trace-aborts.md. Judge hot code changes by abort and exit counts and steady-state step time over several alternating runs, not one timing.
- Objects of one class must share one hash layout. A compiled field read guards on the hash node the key was found in (`HREFK`); instances whose keys were inserted in a different order or set fail the guard and get their own side traces at every read site, which can overflow the trace table and flush the whole JIT cache. `META.FieldLayout = {...}` on an `objects` template lists every field an instance may get beyond its `GetSet` properties, and `CreateObject` inserts them all in one order first. Add new instance fields to that list.
- Avoid short nested inner loops in hot solver code: LuaJIT unrolls them into the outer trace until it runs out of spill slots and blacklists the loop. Prefer one flat task list.
- JIT options (`loopunroll`, `tryside`, ...) live in `goluwa/jit/options.lua`.
- Type punning through cdata is not safe under the JIT: alias analysis treats accesses of different types as independent, so writing through `uint8_t *` and reading the same memory as `int16_t` or `float` in one trace can return stale values (the interpreter is correct, so it only shows once compiled). Assemble numbers with arithmetic instead.
- `array[i]` on an ffi struct array creates a reference cdata. The compiler sinks it inside one trace, but passing it to a function that is not inlined allocates it every time. Hot loops that pass struct array elements to helpers can keep a Lua table of the references instead.
- A function that looks slow may just be a trace abort; fix that before adding caches.

## Lua heap and GC

- `objects.CheckRemovedObjects` drains removed objects on the next Update, so a leak census in the same frame as `Remove()` reports everything removed. Wait some frames and run `collectgarbage` several times; compare heaps after full collections only.
- `Remove()` what you create. Objects dropped without it are finalized in bulk by the collector, and Vulkan buffers keep their memory until then.
- `assets.GetModel(path)` caches the model forever. `Texture.New{path = ...}` pins the decoded texture in `texture_cache` by config key: give previews a unique `cache_key` and `Remove()` them, and never remove a texture whose `image` is the fallback's.
- Long hitches inside arbitrary passes are usually the collector. Its cost follows the number of live and dead objects (small tables, Vec3s, cdata), not their bytes. Read `log.gc()` from the jit.log fork per frame to tell a collector hitch from a slow frame, and `log.heap()` to see what is live and who holds it. The `alloc` sampler of jit.log lists the allocating lines.
- During scene load `r_loading_gc_pause` (`goluwa/render3d/startup_ready.lua`) raises the GC pause. A new pause only applies when a cycle ends, so restoring it must be followed by `collectgarbage("restart")`.
- Memory the collector cannot see piles up: `malloc`ed blobs wrapped in `ffi.gc` count as one pointer, and worker states allocate through big ffi buffers that do not trigger collector steps. Free decoded images once uploaded (`codec.ReleaseBlob(img)`). Check with `mallinfo2` and `/proc/self/smaps_rollup`.
- `Polygon3D:GetVertices()` unpacks a packed (threaded decoder) mesh permanently; code that only needs positions uses `GetVertexCount`/`GetVertexPosition`.

## GPU syncs during play

- `Texture:Upload` and any `render.SubmitAndWait` wait for everything queued on the GPU. Creating an empty sampled texture or `Texture:Shade` does one unless given a `cmd` to record into.
- Work a frame needs first goes into its own command buffer submitted with `render.SubmitDetached(cmd, keep)` (no wait). Data that changes at runtime goes through `Texture:UploadAsync` into a texture no in-flight frame samples (double buffer, swap once `IsUploadDone`).
- Spread big Lua jobs over frames as a coroutine resumed once per frame, and keep using the previous result until the new one is done.

## General rules for GPU and CPU cost

- Shaders: reject cheap cases (brightness, facing away, occlusion) before expensive ones (shadow maps, screen-space marches, ray queries).
- The driver inlines every GLSL function at every call site. A heavy function called from several sites multiplies compile time and instruction cache pressure: call it from one loop marked `[[dont_unroll]]` (`GL_EXT_control_flow_attributes`; inside a Lua long string splice it as `"[[dont_unroll]]"`), or compute it once into a global in `main`. Duplicated code also makes the feature that owns it look more expensive when toggled.
- CPU: rewrite batch records and caches only when their source changed (version counters such as `property_version`, not a broad scene version), never build strings per draw. Call `Material:Touch()` after changing a vector or color in place.
- Setting `r_feature_culling` to false (gpu_culling.lua) disables visibility culling for the worst case; LOD selection is separate.

## Ray traced GI cost

Screen GI traces from every pixel, but what a ray costs depends on the scene it leaves into, not on what is on screen or on triangle counts (traversal is logarithmic; tens of millions of instanced or unique triangles cost about the same). Per ray cost grows with: how many instance boxes its origin sits in (a mesh spread around an empty middle, like one material of a skybox ring, puts its box over everything inside), non opaque instances along it (alpha tests without a built micromap, media, glass), the local lights in its hit's light grid cell, the size of the emitter tree, and whether it hits anything at all (enclosed scenes shade every ray, open ones lose many to the sky). Probe grids are capped by their reach. Compare scenes by these numbers before blaming geometry.

## Texture memory

Measure with `vulkan_memory.Instances` grouped by `debug_name` (`vram_dump`) and compare with `nvidia-smi` for the process.

- `r_max_texture_size` drops mips above that size at upload, for `path` textures only.
- Streaming (`Texture.New{stream = true}`, `r_texture_streaming`, `r_texture_stream_budget`) is driven by `goluwa/render3d/texture_streaming.lua`; decoding runs on workers and the main thread never waits on a stream. Test it by teleporting a `View` around and printing frame times, with `r_texture_streaming=0` as the control.

## Caches and the slow first start

1. `storage/cache/shaders/` (`goluwa/render/vulkan/internal/shader_module.lua`): GLSL to SPIR-V, keyed by the exact GLSL. Misses log `[shader] glslang compiled ...`. This step is cheap.
2. `storage/cache/vulkan_pipeline_cache.bin` (`pipeline_cache.lua`): the driver pipeline cache, saved as pipeline jobs finish. It only grows; deleting it costs one cold start. Tests use their own file (`pipeline_cache_name` in `test/test_render.lua`).
3. The NVIDIA driver cache (`~/.cache/nvidia/GLCache`, `~/.nv/ComputeCache`) is what makes a cold start slow: the driver compiles the big lighting shaders and does not scale across threads. `[pipeline] the driver compiled ...` logs slow pipeline creations. Pipelines are created on `thread_pool` workers and waited for at first use.

Cold start: `rm -rf ~/.cache/nvidia/GLCache ~/.nv/ComputeCache storage/cache/shaders storage/cache/vulkan_pipeline_cache.bin`. If something renders wrong only with one machine's cache state, clear the driver cache first: it is the one cache the engine cannot validate.

## Startup time

- `goluwa/startup.lua` is imported first. `startup.Begin(name)`/`End(name)` record spans; `local t = startup.Start() ... startup.Add(name, t)` accumulates repeated work (`group: item` names group in the tab). Name tasks (`task:SetName`) or they show as `task: unknown`.
- Readiness is decided by `goluwa/render3d/startup_ready.lua` (ray tracing scene built, nothing loading or spawning, the instance set unchanged for a quiet period). It does not wait for GI or exposure convergence. `GOLUWA_STARTUP_REPORT=1` prints the report; the STARTUP tab of PERF shows it.
- Measure by loading a map from a script, exiting when `startup.IsReady()` and printing `startup.GetReport()`; compare several runs.
- Threaded model decoders: `model_loader.AddThreadedDecoder(id, {Gather, job, Finish})`. `Gather` and `Finish` run on the main thread (workers have no vfs mounts), `job` on a worker. Meshes made this way are packed until `GetVertices()`. `model_loader.Preload(paths)` starts jobs ahead of the loads that consume them. See animation-and-source.md "Threaded codecs" for `thread_pool`.

## Device lost

See debugging-and-profiling.md.
