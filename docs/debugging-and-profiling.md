# Debugging

Temporary print logging and code edits are fine for finding causes; remove them afterwards.

- `table.print(tbl)`, `print_once(...)`, `debug.trace()` (traceback of the caller), `print(x) os.realexit(0)` (print and force exit).
- `--validate` turns Lua errors and Vulkan validation messages into an exit instead of a hang. `GOLUWA_VALIDATE=1 VK_LAYER_VALIDATE_SYNC=1` runs the layers and the sync checks without exiting on the first message.

## Device lost

`VK_ERROR_DEVICE_LOST` carries no message, the kernel says why: `journalctl -k | grep Xid` (nvidia; `dmesg` is usually unreadable). Xid 13 is a bad compute launch descriptor, Xid 109 `CTX SWITCH TIMEOUT` is a context the gpu could not preempt (a hang). A run can hang without printing device_lost; garbage or black screenshots with no error are a hint.

- `Fence:Wait` asserts on a lost device, so the first error is the real one; later validation messages (`vkResetCommandBuffer ... is in use`) are consequences.
- `GOLUWA_CHECKPOINTS=1` (`VK_NV_device_diagnostic_checkpoints`, `goluwa/render/vulkan/internal/checkpoints.lua`) puts markers before every named gpu scope, dispatch, ray launch, acceleration structure build and instrumented command buffer methods. On loss the engine prints the markers the queue reached: the last `stage 0x2000` marker is the command that had not finished.
- On loss the engine always prints the `VK_EXT_device_fault` description and on Linux the recent `NVRM: Xid` kernel log lines (`checkpoints.Report`).
- `GOLUWA_NO_RAY_TRACING=1` disables ray tracing, useful to bisect.
- Intermittent Xid losses in the biggest `vkCmdTraceRaysKHR` launch of a frame (ddgi_shade, reflections_trace) were timing dependent and traced to the driver, not to engine objects or synchronization; do not spend long hunting it in engine code.

# Profiling

`PROF` (`goluwa/global_environment.lua`) wraps LuaJIT's statistical profiler. `PROF.Start(id, opts)`: `frames` (default 300; stops and shuts down after that many frames), `shutdown = false` (no auto shutdown), `trace_recorder = false` (do not observe trace recording), `skip_frames`, `sampling_rate`. Prefer `PROF.Start(id, {trace_recorder = false, shutdown = false})` and stop it yourself with `PROF.Stop()` then `PROF.Summary(path, {top_n = 20})`: trace recording distorts the numbers and has segfaulted on shutdown. It only sees Lua CPU time, see performance.md for what it misses.

- Profile N update frames then exit: `luajit glw --2d --background lua "PROF.Start('id', {frames = 1000}) import('tmp/script.lua')"`.
- Profile a one-off action: `luajit glw --2d --background lua "PROF.Start('id', {shutdown = false}) work() PROF.Stop() system.ShutDown(0)"`.
- Captures are saved to `storage/logs/jit_profile_<id>.glwp`.

# Desktop and the PERF window

- `goluwa/render2d/ui/desktop.lua` is the desktop (keys bound in `goluwa/main.lua`): hold `c` for program buttons and a free cursor, Escape toggles it dimmed and sticky. Add programs with `desktop.RegisterProgram{...}`, menus with `desktop.RegisterMenu`, backdrops with `desktop.RegisterBackdrop`; read the register functions for the fields. A pinned window stays on screen in HUD mode when the desktop hides.
- PERF (`h` toggles, `addons/debug/.../perf_window.lua`) is a `Tabs` window; features add tabs with `perf.RegisterTab(name, order, view)` (`addons/debug/lua/perf.lua`, `view` is a react component, see ui.md). Only the open tab of a shown window is mounted, so what a tab does on mount/unmount is its data collection (the PHYSICS tab enables `physics/stats` in an effect). Polled tabs pass `Rows = react.UsePoll(build_rows, perf.POLL_INTERVAL)` to a `StatTable` (`widgets/stat_table.lua`), keeping `build_rows` a plain function so the console dump commands (`vram_dump`, `physics_stats`, `net_stats`, `terrain_stats`, ...) print the same rows. `perf <tab>` opens the window on a tab. `render.stats` counting is only on while the PERF window is open.
- RENDER VIEWS (`addons/debug/lua/autorun/render_3d/render_views.lua`, `gbuffer_view <field|sheet|targets|off>`) shows gbuffer fields, pass debug textures and lighting term switches; the GBUFFER LAYOUT tab shows how fields are packed.
- `GOLUWA_DUMP_SHADERS=1` writes every stitched GLSL stage to `storage/shader_source/<pass name>.<stage ext>` (`.vert .frag .comp .rgen` ...). Each file compiles standalone: `glslc --target-env=vulkan1.3 file`. Pipelines without `name` fall back to the creating Lua file; same-name variants get a crc suffix.

# LuaJIT optimization notes

See performance.md "LuaJIT".
