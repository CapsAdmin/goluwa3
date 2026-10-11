# Debugging

When debugging and thinking about why something happens, feel free to do print logging and changing code around temporarily to verify.

- print a table and its contents: `table.print(tbl)`
- print something once per session: `print_once(...)`
- print a traceback to see where something is called from: `debug.trace()`
- print something and force exit: `print(something) os.realexit(0)`

# Profiling

The profiler uses luajit's statistical profiler and jit.attach to observe trace recording. Options of `PROF.Start(id, opts)`: `frames` (default 300), `shutdown = false` (do not auto shut down after `frames`), `trace_recorder = false` (do not observe trace recording), `skip_frames`. Prefer `PROF.Start(id, {trace_recorder = false, shutdown = false})` and stop it yourself with `PROF.Stop()` then `PROF.Summary(path)`: trace recording distorts the numbers and has segfaulted on shutdown. The profiler only sees Lua CPU time, see `performance.md` for what it misses.

- `_G.PROF.Start("myprofilesession")` is a high level global helper that starts the JIT profiler with sane default arguments. It runs for 300 update frames, stops and prints a text summary, then calls system.ShutDown(0)

- Profile the update loop for 1000 frames, then implicitly shutdown: `luajit glw --2d --background lua "PROF.Start('profilesession1', {frames = 1000}) import('tmp/benchmark_test.lua')"`

- Profile a one-off action and shutdown manually: `luajit glw --2d --background lua "PROF.Start('profilesession2') something_expensive_and_blocking() PROF.Stop() system.ShutDown(0)"`

- The profile capture is saved to `storage/logs/jit_profile_someid.glwp` which can be read in detail, ie `PROF.Summary("storage/logs/jit_profile_someid.glwp", {top_n = 20})`

# Optimizations

- Trace abort reasons like `blacklisted` are caused by other trace abort reasons, it means that it was attempted too many times

- LuaJIT's trace compiler is non deterministic, sometimes you may get unlucky or lucky. Beware of this.

- `error thrown or hook called during recording` may happen because of the profiler itself. jit.attach and jprofile.start. There is no debug.sethook in this engine.

- Sometimes caching is prefered, but sometimes it is not. The luajit does very well with pure numeric arithmetic, so caching may sometimes interfere with that. Sometimes you may think a function needs caching, but the underlying issue might be a trace abort causing the function not to compile properly, this case might benefit from caching, but if the underlying problem was solved, the function might even be faster than the cached variant.
