# macos

On macos, the kosmickrisp vulkan driver is used as opposed to moltenvk

# Love2D and Garrysmod wrapper

These wrappers make it possible to run lua scripts made for those engines, in this engine. They exist in `addons/love/*` and `addons/gmod/*`

- Never modify a love2d game's source code. Always fix issues in the wrapper itself. The same applies for garrysmod scripts.

- Do not add script and game specific workarounds in the wrapper for specific games and scripts.

- The glua wrapper uses garrysmod's lua source as-is and only implements functions that garrysmod defines in C. Never redefine something like Color, since it's already in garrysmod's lua source.

- If this engine lacks core functionality that the wrapper's engine assume exists, consider adding it to this engine if it's generic and useful enough, as opposed to adding functionality to the wrapper only. For example, if render2d in this engine is missing alpha blending, add alpha blending to render2d, then write wrapper code to to use the new engine functionality.

# Windows under wine
The Windows code path is mostly untested on real Windows; wine is the only check available on Linux.
- Use the real MSVC build from the `luajit-c6ffc14` release (`luajit.exe` + `lua51.dll`, extract the zip somewhere). A mingw build also runs but its CRT lacks some functions.
- Put `shaderc_shared-windows-x64.dll` in `storage/bin/libshaderc/` by hand, wine's TLS fails the downloader's handshake.
- Run it from the repo root: `WINEDEBUG=-all wine /path/to/luajit.exe glw --2d --background --validate --one-frame lua "print(1)"`.
- No Windows `crash_trace` vectored exception handler: LuaJIT raises Lua errors as SEH exceptions (0xE24C4A02) and a vectored handler is a Lua callback into the main state, so a worker thread's error called it on the wrong thread and panicked with "bad callback". Only `SetUnhandledExceptionFilter` is used now.
- A debug build of lua51.dll that prints in `lj_ccallback_enter` is how that was found: the state address in the message showed the callback belonged to the main state while the thread was a worker.
- Do not serialise worker threads with a process-wide mutex. The old Windows `worker mutex` deadlocked nested threads (the tests start threads from a worker), and blocked `threads.new` on the main thread for as long as the audio mixer thread ran. It was added against crashes that were really the vectored exception handler above, concurrent lua states are fine.
- `process.setenv` must also call `_putenv_s`, `os.getenv` reads the CRT environment and not the Win32 one.
- Child process command lines need MSVCRT quoting (spaces and quotes in arguments), tests that spawn children use `process.get_executable_path()` and not `luajit`/`sh`/`ls`.
- Vulkan `VkResult` values come back unsigned from LuaJIT, run them through `bit.tobit` before comparing with the (negative) enum values.
- `luajit.exe glw --cli --no-audio --validate test async/` and `test render2d/render2d.lua` both pass under wine.
- Paths are ANSI (`...A` apis, `fopen`, lua's `io.open`/`loadfile`, `ffi.load`), no wide variants are used. The engine mostly uses relative paths so a non-ascii install location works when its characters fit the system code page; characters from another script do not. A wide port would have to cover `fs`/`process` and about 100 `io.open`/`loadfile`/`os.*` call sites, and `ffi.load` needs a `LoadLibraryW` workaround.
