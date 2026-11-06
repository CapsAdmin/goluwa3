# Tests

`luajit glw test [path part]` (`goluwa/test.lua`) runs every file in `test/tests/` and `addons/*/tests/` (addons starting with `__` or `.` are disabled and skipped). Each file runs in its own process (`luajit glw test --worker=<path>`, which prints its result as a last line), `--jobs` at once (default half the logical cores, the physical core count on SMT machines; 4 on macOS), longest first by the durations in `storage/logs/test_durations.json`. A new file is not started while less than 4 GB of memory is free.

- Processes rather than threads in one process: 16 threads sharing one process ran each file about twice as slow, and a crash in one took the whole run down. A crash or a lua error now fails only its file, and a file still running after 120 s is killed.
- Validation layers are on in tests; `GOLUWA_VALIDATE=0 luajit glw test` turns them off (render files run up to ~45% faster, nothing checks Vulkan usage).
- `--slow` also runs tests marked slow: long convergence runs and exhaustive sweeps. Mark one with `T.Slow(T.Test3D, name, cb)` (any test definer), or widen a test with `T.IsSlowRun()`. Without `--slow` they show as skipped. Run the slow tier before committing work in the area those tests cover.
- Every run writes `storage/logs/test_report.txt`: each file's wall time split into load (process start and file body), tests and rest, then the slowest tests. The end of the output lists the ten slowest files. When the slowest file is close to the total, split or speed it up; when the average number of running files is close to `--jobs`, the run is bound by total work.
- Times inside a full run are about twice the time of the file alone (all cores busy, SMT, the shared GPU); compare with the file run alone before optimizing.

## Keeping tests fast

- `Texture:GetPixel` downloads the whole texture on every call. Read many pixels from one `texture:Download()`.
- `render3d.Initialize` rebuilds every pass. Do it once per test at most, not once to set up and again to restore; nothing after the file needs the old passes.
- Each file pays for a process, a render device and pipeline creation (about 0.3 s before its first test); tiny render files are cheaper merged into a related file, long files are faster split.
- Tests in a file share one Lua state. A test that leaves entities, pressed buttons, a theme or listeners behind breaks the next one, often only when the first one fails. `T.TestPhysics` clears the world before and after each test.
- Frames in tests go through `event.CallUpdate` (PreUpdate, Update, LateUpdate), not `event.Call("Update")`. `T.WaitUntil` counts simulated time (16 ms per tick); wait for real work (downloads, threads) with `T.WaitUntilReal`.
