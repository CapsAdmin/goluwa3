# Tests

`luajit glw test [path part]` (`goluwa/test.lua`) runs every file in `test/tests/` and `addons/*/tests/` (addons starting with `__` or `.` are disabled and skipped). Each file runs in its own process (`luajit glw test --worker=<path>`, which prints its result as a last line), `--jobs` at once, longest first by the durations in `storage/logs/test_durations.json`. New files are not started while free memory is low.

- Files run in separate processes so a crash or Lua error fails only its file. A file that runs past the kill limit (`GOLUWA_TEST_KILL_SECONDS`) is killed; `GOLUWA_TEST_TIMEOUT` is the per test limit.
- Validation layers are on in tests; `GOLUWA_VALIDATE=0 luajit glw test` turns them off (faster, but nothing checks Vulkan usage).
- `--slow` also runs tests marked slow (long convergence runs, exhaustive sweeps). Mark one with `T.Slow(T.Test3D, name, cb)` (any test definer), or widen a test with `T.IsSlowRun()`. Without `--slow` they show as skipped. Run the slow tier before committing work in the area those tests cover.
- Every run writes `storage/logs/test_report.txt`: each file's wall time split into load, tests and rest, then the slowest tests; the output ends with the slowest files. When the slowest file is close to the total, split or speed it up; when the average number of running files is close to `--jobs`, the run is bound by total work.
- Times inside a full run are inflated by contention (all cores, the shared GPU); compare with the file run alone before optimizing.

## Keeping tests fast

- A cold pipeline cache (new machine, new driver, or `GOLUWA_VULKAN`/`VK_DRIVER_FILES` changed) makes the first run much slower and can push files past the kill limit. Run twice before judging times or failures, and use the same driver as for the engine. More `--jobs` than the default is not necessarily faster.
- Tests that need game content (gmod) start with `T.HasGmod()` and return `T.Unavailable(...)` / `T.Skip(...)` without it.
- `Texture:GetPixel` downloads the whole texture on every call. Read many pixels from one `texture:Download()`.
- `render3d.Initialize` rebuilds every pass. Do it at most once per test; nothing after the file needs the old passes.
- Each file pays for a process, a render device and pipeline creation before its first test; tiny render files are cheaper merged into a related file, long files are faster split.
- Tests in a file share one Lua state. A test that leaves entities, pressed buttons, a theme or listeners behind breaks the next one, often only when the first one fails. `T.TestPhysics` clears the world before and after each test.
- Frames in tests go through `event.CallUpdate` (PreUpdate, Update, LateUpdate), not `event.Call("Update")`. `T.WaitUntil` counts simulated time; wait for real work (downloads, threads) with `T.WaitUntilReal`.
