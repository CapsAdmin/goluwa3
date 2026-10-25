# macOS

The kosmickrisp vulkan driver is used rather than MoltenVK (`goluwa/bin_manifest.lua`).

- MoltenVK cannot build the gbuffer (`gl_DrawID` has no MSL equivalent there).
- KosmicKrisp builds older than mid 2026 can deadlock the queue (a fence never signals while the GPU is idle) once a frame records many indirect shadow draws; the bundled 26.2.4 and Mesa main do not. When several KosmicKrisp ICDs are installed the loader lists one device per ICD; pick one with `VK_DRIVER_FILES=<icd json>`.
- Apple GPUs have no ray tracing in Vulkan: DDGI is not built (lighting falls back to the sky irradiance), reflections are screen space, and `r_quality` `auto` resolves to `medium`.
- Only render pass GPU timestamps are meaningful; compute scopes read 0 or garbage. Measure passes by interleaved frame time A/B, the Air throttles within a minute.
- Running many test files at once on the integrated GPU can trip the Metal command queue timeout (device lost); lower `--jobs`.

# Love2D and Garrysmod wrappers

They let scripts written for those engines run here, in `addons/love/*` and `addons/gmod/*`.

- Never modify a love2d game's or garrysmod script's source. Fix issues in the wrapper itself, and do not add script- or game-specific workarounds.
- The glua wrapper uses garrysmod's lua source as-is and only implements what garrysmod defines in C. Never redefine something like `Color` that garrysmod's lua already defines.
- If the engine lacks core functionality the wrapper's engine assumes (alpha blending in render2d, say), add it to the engine if it is generally useful, then write the wrapper on top of it.

# Windows under wine

The Windows code path is mostly untested on real Windows; wine is the only check available on Linux.

- Use the real MSVC build from the `luajit-c6ffc14` release (`luajit.exe` + `lua51.dll`); a mingw build lacks some CRT functions. Put `shaderc_shared-windows-x64.dll` in `storage/bin/libshaderc/` by hand (wine's TLS fails the downloader). Run from the repo root: `WINEDEBUG=-all wine /path/to/luajit.exe glw --2d --background --validate --one-frame lua "print(1)"`.
- LuaJIT raises Lua errors as SEH exceptions, and a vectored handler is a Lua callback into the main state, so there is no vectored `crash_trace` handler on Windows; only `SetUnhandledExceptionFilter` is used.
- Do not serialise worker threads with a process-wide mutex (nested threads deadlock); concurrent lua states are fine.
- `process.setenv` must also call `_putenv_s` (`os.getenv` reads the CRT environment). Child process command lines need MSVCRT quoting; tests that spawn children use `process.get_executable_path()`, not `luajit`/`sh`/`ls`.
- Vulkan `VkResult` values come back unsigned from LuaJIT: run them through `bit.tobit` before comparing with the negative enum values.
- Paths are ANSI (`...A` apis, `fopen`, `io.open`, `ffi.load`), no wide variants; the engine mostly uses relative paths, so a non-ascii install path works only if its characters fit the system code page.
- `luajit.exe glw --cli --no-audio --validate test async/` and `test render2d/render2d.lua` pass under wine.
