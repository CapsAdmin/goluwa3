# Debugging

Temporary print logging and code edits are fine for finding causes; remove them afterwards.

- `table.print(tbl)`, `print_once(...)`, `debug.trace()` (traceback of the caller), `print(x) os.realexit(0)` (print and force exit).
- `--exit-on-error` turns Lua errors (and Vulkan validation messages, when the layers are on) into an exit instead of a hang. `--vulkan-validate` enables the validation layers. `GOLUWA_VALIDATE=1 VK_LAYER_VALIDATE_SYNC=1` runs the layers with sync checks.

## Device lost

`VK_ERROR_DEVICE_LOST` carries no message; the kernel says why: `journalctl -k | grep Xid` (NVIDIA). Xid 13 is a bad compute launch, Xid 109 `CTX SWITCH TIMEOUT` a GPU hang. A run can also hang or produce black/garbage screenshots without reporting device lost.

- On loss the engine prints the `VK_EXT_device_fault` description and recent `NVRM: Xid` lines (`checkpoints.Report`) and writes `storage/logs/device_lost_<time>.txt`. Add state to that report by appending to `checkpoints.state_reporters`; `checkpoints.address_describers` name what a faulting address belongs to (`meshes.DescribeAddress`).
- `Fence:Wait` asserts on a lost device, so the first error is the real one; later validation messages are consequences.
- `GOLUWA_CHECKPOINTS=1` (`goluwa/render/vulkan/internal/checkpoints.lua`, `VK_NV_device_diagnostic_checkpoints`) places markers before named GPU scopes, dispatches, ray launches and acceleration structure builds; on loss the last unfinished marker is printed. Checkpoints change timing and can hide a loss.
- With `GOLUWA_VALIDATE=1` the device enables `robustBufferAccess2` when supported, so out of bounds reads of descriptor bound buffers return zero. A fault that survives it comes from a raw buffer address, a bindless texture or an acceleration structure.
- Bindless slot 0 is the pink/black error texture and negative indices clamp to it; pink where it should not be means a nil or stale texture index. Virtual render textures (`textures/render/*.lua`) must be registered by `assets.RegisterRenderTextures()`; headless tests show a missing registration first.
- Vulkan objects are destroyed through `Device:DeferRelease`, which waits for submissions that may use them. Releases requested between `render.BeginFrame` and `render.EndFrame` are held until that frame is submitted; a release ordered against an older submission shows as a page fault on a destroyed resource, typically right after a setting changes.
- `GOLUWA_NO_RAY_TRACING=1` disables ray tracing, `GOLUWA_ASYNC_COMPUTE=0` uses one queue.
- Losses inside the biggest traces of a frame that come and go with timing are not evidence of a driver bug; get an Aftermath dump before blaming the driver.
- Nsight Aftermath names the resource a lost device read and the faulting shader: `nv-aftermath-control --mode Global --debuginfo=1 --resource-tracking=1 --callstacks=0 --shader-error-reporting=1` (every call rewrites all options in `~/.nvidia-aftermath-rc`, so pass them all; `--mode Disabled` afterwards), run `nv-aftermath-monitor --crashdump-dir DIR --debuginfo-dir DIR --prompt-on-crash=0`, reproduce, then `nv-aftermath-format -d DIR -g DIR DIR/*.nv-gpudmp`. If the shader's `Ray Tracing Internal Function Type` is `AS Build or Refit` or `Ray Tracing`, driver code walked a bad acceleration structure: look at what writes BLAS memory. Summarize every dump before trusting one. `--callstacks=1` makes the driver call `backtrace()` through LuaJIT frames, which panics. Pipelines compile much slower with Aftermath on.
- GPU assisted validation: `VK_LAYER_GPUAV_ENABLE=true VK_LAYER_VALIDATE_CORE=false GOLUWA_VALIDATE=1 GOLUWA_VALIDATE_NO_TRACEBACK=1` (the message callback must not traceback the Lua state from the layer's threads). It instruments every shader, so uber shaders compile very slowly; `GOLUWA_TEST_KILL_SECONDS` and `GOLUWA_TEST_TIMEOUT` raise the test runner's limits.

### Chasing one

1. Make a repro that loads the scene from a script and exits after a fixed time, so each run answers yes or no, and see whether it fails every run or only some.
2. Switch features off to find what is needed: build-time pvars through `GOLUWA_PVARS` (`r_pass_<name>=0`, ...), `GOLUWA_ASYNC_COMPUTE=0`, `GOLUWA_NO_RAY_TRACING=1`. When every subset of the content survives but the whole crashes, suspect timing or counts rather than one bad asset.
3. `GOLUWA_CHECKPOINTS=1` with one queue names the command that did not finish. Repeat runs that survive.
4. Rule out lifetimes and inputs with experiments that cannot be wrong: hold every deferred release forever, give a buffer its own memory, read GPU written address tables back and validate them against live buffers.
5. Take an Aftermath dump; for a page fault on a destroyed resource, find every place that stores that resource's address and when it is refreshed.

# Native crashes (PANIC, bad callback, SIGSEGV)

- `PANIC: unprotected error in call to Lua API (bad callback)` is usually a masked crash: `crash_trace`'s signal handler is an FFI callback, so a SIGSEGV on a worker thread or in JIT code re-enters a busy Lua state. Look for the first fault.
- Run the same command under `luajit-debug` (assertions on). It is a shell wrapper: run gdb on the `.luajit-debug-wrapped` binary it execs with the wrapper's `LD_LIBRARY_PATH`. Symbol names work without DWARF (`break lj_assert_fail`, `break luaL_openlibs` to collect worker states). Do not call `luaL_traceback` on a state mid-run or mid-GC; add `-joff` when inspecting running states.
- Memory errors look different every run. Bisect by switching subsystems off (`r_codec_threads=0`, `--no-audio`, `-joff`) and count failures over several runs each.
- `lj_cconv_tv_ct: non-canonical NaN passed` means an FFI double read returned an unrepresentable NaN: almost always an out of bounds or freed read (FFI arrays have no bounds checks). Negative indices from `or -1` sentinels are the usual source.

# Profiling

`PROF` (`goluwa/global_environment.lua`) wraps LuaJIT's statistical profiler. `PROF.Start(id, opts)` takes `frames` (stop and shut down after that many frames), `shutdown = false`, `trace_recorder = false`, `skip_frames`, `sampling_rate`. Prefer `PROF.Start(id, {trace_recorder = false, shutdown = false})`, then `PROF.Stop()` and `PROF.Summary(path, {top_n = 20})`: the trace recorder distorts the numbers. It only sees Lua CPU time (see performance.md). Never start it twice in one run.

- Profile N frames then exit: `luajit glw --2d --background lua "PROF.Start('id', {frames = 1000}) import('tmp/script.lua')"`.
- Profile a one-off action: `luajit glw --2d --background lua "PROF.Start('id', {shutdown = false}) work() PROF.Stop() system.ShutDown(0)"`.
- Captures go to `storage/logs/jit_profile_<id>.glwp`. With the trace recorder on, the summary ends with the top aborts by source. "error thrown or hook called during recording" can come from the profiler itself.
- Headless runs: `--cli` and `--server` sleep every Update (`--fps=N`), so wall frame time is meaningless there. For physics use `--headless --fps=60`, call `physics.Initialize()` and time `physics.instance.UpdateFixed`.

# jit.log (streaming trace and profile log)

A LuaJIT fork in `local_stuff/LuaJIT-Profiler` adds `require("jit.log")`, which writes trace start/stop/abort/flush, exits and profiler samples as binary records from C. Run the engine with `local_stuff/LuaJIT-Profiler/src/luajit glw ...`. Build with `nix-shell -p gcc gnumake --run 'make amalg XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT" BUILDMODE=static'` (`make clean` when switching between amalg and non-amalg).

- API: `log.start(path, {traces, profile, interval, mode, depth, alloc})`, `log.stop()`, `log.flush()`, `log.status()`, `log.string(s)`, `log.section_ptr()` (set the section id through ffi so traced code does not call C), `log.gc()` (time per collector state), `log.heap(limit)` (full collection, then the live heap by type, ctype and metatable, plus what holds what).
- `alloc = bytes` samples allocations with the Lua stack; it needs `profile = true` (use a long `interval` to keep time samples rare).
- Starting or stopping a line/function mode profile flushes every trace, so short logs are dominated by recompilation. Log long windows.
- Samples only interrupt the main thread, unlike stock `jit.profile` (`PROF`), whose process-wide `SIGPROF` also lands on worker threads and can leave the profile hook stuck on.
- Read logs with `local_stuff/LuaJIT-Profiler/tools/log_reader.lua` (run it on a `.gljl` for a summary, or `dofile` it for `Reader.New(path)`, `:Poll()`, `:GetLiveTraces()`, `:Summary()`).
- The log follows only the Lua state that started it. To profile `thread_pool` jobs, set `GOLUWA_PVARS="r_codec_threads=0"` so they run inline.

# Desktop and the PERF window

- `goluwa/render2d/ui/desktop.lua` is the desktop (keys bound in `goluwa/main.lua`; hold `c` for program buttons and a free cursor). Extend it with `desktop.RegisterProgram`, `RegisterMenu`, `RegisterBackdrop`.
- PERF (`h` toggles, `perf <tab>` opens a tab; `addons/debug/lua/autorun/render_2d/perf_window.lua`) is a tabbed window; features add tabs with `perf.RegisterTab(name, order, view)` (`addons/debug/lua/perf.lua`). Only the open tab is mounted, so a tab collects its data on mount. Polled tabs build rows with a plain function passed to `react.UsePoll` and a `StatTable`, so console dump commands (`vram_dump`, `physics_stats`, ...) print the same rows. `render.stats` counting is only on while PERF is open.
- GPU tab: pass groups come from `timing_group` on a pipeline config, `group` on a `default_passes` entry or `gpu_timing.BeginScope(cmd, name, group)`. Async compute passes overlap the frame, so slices can add up to more than the frame. The TIMELINE tab draws every scope from its timestamps (`gpu_timing.GetTimeline()`).
- CPU tab: `goluwa/cpu_timing.lua` times event listeners, timers, thinkers and delays exclusively while enabled (`cpu_timing.Enable/Disable`).
- RENDER VIEWS (`addons/debug/lua/autorun/render_3d/render_views.lua`, `gbuffer_view <field|sheet|targets|off>`) shows gbuffer fields and pass debug textures.

# Shaders and GPU traces

- `GOLUWA_DUMP_SHADERS=1` writes every stitched GLSL stage to `storage/shader_source/<pass name>.<stage ext>`; each compiles standalone with `glslang -V --target-env vulkan1.3 file`.
- `GOLUWA_SHADER_DEBUG=1` compiles shaders with `NonSemantic.Shader.DebugInfo` for source-level profiling in Nsight Graphics. Do not combine it with `--vulkan-validate` (spirv-val rejects some of the debug info).
- `luajit glw ngfx [trace]` (`goluwa/cli/ngfx.lua`) reports a Nsight Graphics `.ngfx-gputrace` (default: newest in `storage/ngfx_traces/`): GPU time per frame and call group, hardware counters, warp samples per pipeline with stall reasons, and the hottest GLSL lines. `--capture="--3d map ..."` takes the trace itself through the `ngfx` CLI (`NGFX_CLI`) and the Nsight SDK (`goluwa/bindings/ngfx.lua`), `--capture-after=<seconds|event:name>` picks when; `ngfx_capture` triggers one by hand in a game launched that way. The architecture is detected from `nvidia-smi` (`NGFX_ARCHITECTURE` overrides); without it the tool silently drops the shader profiler. Pipeline names need `GOLUWA_DUMP_SHADERS=1` and source lines need `GOLUWA_SHADER_DEBUG=1` in the traced run; `--calibrate` extends the blob keystream (`storage/ngfx_keystream.bin`). The parsers are `goluwa/codecs/ngfx_gputrace.lua` and `ngfx_perfworks.lua`. Warp samples explain why a pipeline is slow; they are not its time. Stall reason ordering (`STALL_REASONS`) was verified on one architecture and may differ on others.
- Register pressure: on GPUs listed in `pipeline_statistics.GPUS` (`goluwa/render/vulkan/internal/pipeline_statistics.lua`) pipelines that spill log `[pipeline] ... uses n registers ... and spills b bytes`; `GOLUWA_PIPELINE_STATS=1` logs every statistic on any GPU. Code that never runs still costs registers. Ray tracing pipeline register counts are only in `ngfx` traces.

# Game speed

- The `time_scale` pvar (`system.SetTimeScale`) scales the game clock: `Update` `dt`, `system.GetFrameTime()` and `system.GetElapsedTime()` follow it. 0 freezes the world (`dt` is 0, so dividing by it is a bug).
- `system.GetUnscaledFrameTime()` / `GetUnscaledElapsedTime()` ignore the scale; use them for anything the person at the keyboard sees rather than the simulated world (UI animation, debounces, stats, profiling).
- `system.SetElapsedTime` moves both clocks.

# LuaJIT optimization notes

See performance.md "LuaJIT" and jit-trace-aborts.md.
