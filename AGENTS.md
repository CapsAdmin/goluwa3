# Goluwa
Goluwa is a game engine written entirely in LuaJIT and ffi, without any third party dependencies except for Vulkan and OS. There is no C code, everything is LuaJIT.

`goluwa/*` is the engine's source code

`addons/*` is the place for examples, experimental scripts, and sub projects that don't fit in the core engine. For example the love2d wrapper, garrysmod wrapper, ui gallery and more exist there. Addons are implicitly loaded once the engine starts from autorun directories. It works similar to how garrysmod addons work.

`storage/*` is for logs, caches, settings and other dynamic data.

`test/*` is the test suite.

# Running
Use luajit installed on the system. `glw` is a lua script without a .lua extension that simply calls into `goluwa/main.lua` with the remaining arguments. Optional engine flags come first, then a command, followed by the command's arguments. `main.lua` sets up a default global environment globals, but scripts mostly uses import statements, ie `local Vec3 = import("goluwa/structs/vec3.lua")`

- If you need to write a temporary script to run, write it in `./tmp/`

- Run a single lua script: `luajit glw --2d --one-frame lua "./tmp/path/to/file.lua"`

- Take a screenshot: `luajit glw --2d --screenshot --one-frame lua "./tmp/path/to/some/render/script.lua"`

- The `Screenshot(cb, opt)` global captures the screen. `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:Save(path, without_alpha)`, `:ToPNG(without_alpha)`, `:GetPixel(x, y)`). `opt.update_events = n` runs n Update events first — use this for UI so layout resolves before the capture. `opt.midframe = true` captures immediately mid-frame via `render.Capture()` — call it from inside a Draw/Draw2D listener. `opt.camera = {position, rotation, fov}` (3d only) captures from a specific camera — it beats per-frame camera controllers (e.g. the player camera component) and restores the original camera after the capture. Example:
  ```lua
  Screenshot(function(texture)
      print(texture:Save(nil, true)) -- auto path under storage/logs/screenshots/
  end, {update_events = 3})

  Screenshot(function(texture)
      texture:Save("tmp/from_here.png")
  end, {camera = {position = Vec3(0, 5, 0), rotation = QuatDeg3(45, 0, 0)}})
  ```

- Run a single test file with name pattern: `luajit glw test render2d/render2d.lua --name-pattern="Graphics render2d blend modes visual"`

- Run all test files in a directory: `luajit glw test render2d/`

- Run inline lua: `luajit glw --2d --one-frame lua "print('hello')"`. For scripts that span multiple lines, prefer the cycle of writing the script in ./tmp/, run, edit, run again, etc

- When running the engine without the `--one-frame` flag, it will run forever. In which case you must use the timeout command or call `system.ShutDown()` manually at some point

# Debugging

When debugging and thinking about why somnething happens, feel free to do print logging and changing code around temporarily to verify.

- print a table and its contents: `table.print(tbl)`
- print something once per session: `print_once(...)`
- print a traceback to see where something is called from: `debug.trace()`
- print something and force exit: `print(something) os.realexit(0)`

# Profiling

The profiler uses luajit's statistical profiler and jit.attach to observe trace recording.

- `_G.PROF.Start("myprofilesession")` is a high level global helper that starts the JIT profiler with sane default arguments. It runs for 300 update frames, stops and prints a text summary, then calls system.ShutDown(0)

- Profile the update loop for 1000 frames, then implicitly shutdown: `luajit glw --2d lua "PROF.Start('profilesession1', {frames = 1000}) import('tmp/benchmark_test.lua')"`

- Profile a one-off action and shutdown manually: `luajit glw --2d lua "PROF.Start('profilesession2') something_expensive_and_blocking() PROF.Stop() system.ShutDown(0)"`

- The profile capture is saved to `storage/logs/jit_profile_someid.glwp` which can be read in detail, ie `PROF.Summary("storage/logs/jit_profile_someid.glwp", {top_n = 20})`

# Optimizations

- Trace abort reasons like `blacklisted` are caused by other trace abort reasons, it means that it was attempted too many times

- LuaJIT's trace compiler is non deterministic, sometimes you may get unlucky or lucky. Beware of this.

- `error thrown or hook called during recording` may happen because of the profiler itself. jit.attach and jprofile.start. There is no debug.sethook in this engine.



# Coding rules

"Hot code" is anything called every frame in the update/render loop, or any function invoked in a tight loop.
If you see code that does the below, consider refactoring if relevant to the task at hand.

- Do not worry about whitespace as the formatter will take care of it.

- Never use camelCase. use snake_case for locals and private fields, PascalCase for methods and globals.

- Favor fixing underlying issues rather than patching symptoms.

- Don't add unnesseceary comments that just repeat what the code obviously does.
```lua
-- ShutDown function
local function ShutDown(code)
    -- call os.exit
    os.exit(code)
end
```
do this instead
```lua
local function ShutDown(code)
    os.exit(code)
end
```

- Do not write backwards-compatible code unless asked to. This repository is the only consumer of the APIs you write, so if you change an API, update every consumer in this repository, don't preserve the old signature or add shims.

- Do not normalize arguments. If a function takes in a texture object, then you must assume that the caller will always pass a valid texture object.

- Favor errors over silent failures, but beware of complex error handling in hot functions. In hot functions it is favorable to just let luajit error naturally in case of the wrong type passed.

- Don't call `obj:IsValid()` defensively/speculatively, only call it when you already know that the object's validity can genuinely be in question

- Do not write defensive code like "if obj.SetFoo then obj:SetFoo() end". assume the function exist. If obj is an object that you feel is missing a helper function, add the function at the object's source.

- Never create functions (closures) inside hot code. This allocates a new closure per call and causes jit to abort tracing. Hoist them to module level or an outer scope that is evaluated once. 

- Prefer long functions. Do not extract code into a local function unless the same logic is used elsewhere.

- If you do need a local helper function or a cache variable that's only consumed by one function, place it as close to the caller as possible and limit its scope with a `do...end` block:

```lua
do
    local function compute(str) return #str * #str end
    local cache = {}

    function mylib.Hash(str)
        if cache[str] then return cache[str] end
        local x = compute(str) + compute(str)
        cache[str] = x
        return x
    end
end

function mylib.SomethingElse() end
```
- Avoid creating local variables that are just used in one place.
```lua
local this_is_a_variable = x + y
compute(this_is_a_variable)

```
do this instead
```lua
compute(x + y)
```

- Prefer using `import` at the top of the script. In case of circular dependency, see how import.loaded is used

- If you are using a library like render2d, and it's missing functionality, AND the functionality is generally useful, add it to render2d. The same can be applied for standard lua libraries like string, table, math, etc functions. see for example goluwa/string/* for string library extensions.

- Use functions like table.merge, math.clamp, math.lerp, etc, over creating local functions that duplicate existing functionality

- Prefer using ffi.cdef and ffi.typeof at the module level, never adhoc inside of a hot function.

- When declaring ffi types, prefer using ffi.typeof to create anonymous localized types rather than ffi.cdef, as ffi.cdef creates global type definitions. 

# Love2D and Garrysmod wrapper

These wrappers make it possible to run lua scripts made for those engines, in this engine. They exist in `addons/love/*` and `addons/gmod/*`

- Never modify a love2d game's source code. Always fix issues in the wrapper itself. The same applies for garrysmod scripts.

- Do not add script and game specific workarounds in the wrapper for specific games and scripts.

- The glua wrapper uses garrysmod's lua source as-is and only implements functions that garrysmod defines in C. Never redefine something like Color, since it's already in garrysmod's lua source.

- If this engine lacks core functionality that the wrapper's engine assume exists, consider adding it to this engine if it's generic and useful enough, as opposed to adding functionality to the wrapper only. For example, if render2d in this engine is missing alpha blending, add alpha blending to render2d, then write wrapper code to to use the new engine functionality.
