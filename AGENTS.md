# Goluwa
Goluwa is a game engine written entirely in LuaJIT and ffi, without any third party dependencies except for Vulkan and OS. There is no C code, everything is LuaJIT.

`goluwa/*` is the engine's source code

`addons/*` is the place for examples, experimental scripts, and sub projects that don't fit in the core engine. For example the love2d wrapper, garrysmod wrapper, ui gallery and more exist there. Addons are implicitly loaded once the engine starts from autorun directories. It works similar to how garrysmod addons work.

`storage/*` is for logs, caches, settings and other dynamic data.

`test/*` is the test suite.

# Running
Use luajit installed on the system. `glw` is a lua script without a .lua extension that simply calls into `goluwa/main.lua` with the remaining arguments. Optional engine flags come first, then a command, followed by the command's arguments. `main.lua` sets up a default global environment globals, but scripts mostly uses import statements, ie `local Vec3 = import("goluwa/structs/vec3.lua")`

- The file watcher is off by default, pass --hot-reload to reload lua files on change while developing
- Use the --validate flag to prevent the engine from running forever after a lua error. It also enables the Vulkan validation layers (off by default) and exits on the first validation error, which roughly triples CPU frame time, so never benchmark with it

- Always pass `--background` and `--validate` when launching the engine with a window (`--2d`, `--3d`, `shot`, `test`, screenshots, ad hoc scripts). `--background` opens the window minimized so it does not steal the user's focus (Wayland), and `--validate` makes errors and validation messages exit instead of hanging. Example: `luajit glw --2d --background --validate --screenshot lua "./tmp/script.lua"`. The only exception is performance measurement, where `--validate` must be left off (it triples CPU frame time) but `--background` should still be used.

- The engine in --3d mode starts in about 2 seconds, --2d is less than one second, and --cli/--headless is instant. Therefore, using `timeout` for more than 20 seconds is most likely not needed.

- If you need to write a temporary script to run, write it in `./tmp/`

- Run a single lua script: `luajit glw --2d --one-frame lua "./tmp/path/to/file.lua"`

- Run a single test file with name pattern: `luajit glw test render2d/render2d.lua --name-pattern="Graphics render2d blend modes visual"`

- Run all test files in a directory: `luajit glw test render2d/`

- Running the whole test suite is expensive and may cause vram errors due to the constrained environment. Prefer not to run the whole test suite.

- Run inline lua: `luajit glw --2d --one-frame lua "print('hello')"`. For scripts that span multiple lines, prefer the cycle of writing the script in ./tmp/, run, edit, run again, etc

- When running the engine without the `--one-frame` or `--screenshot` flag, it will run forever. In which case you must use the timeout command or call `system.ShutDown()` manually at some point

- `--cli` scripts keep the engine running after the script finishes (`--validate` only ends it on a Lua error). End scratch scripts run with `--cli` with `os.exit(0)`, or use `--one-frame` in 2d/3d mode. A hung run blocks the call until its timeout.

- Scratch scripts that flip a pvar must use `pvars.SetSession`; `pvars.Set` writes the user's `pvars.txt` for good. Pvars that shaders and passes are built from ("build time" ones like `r_rt_hit_*`, `reflection_reorder`) are read when the passes are made, before a script runs, so a script's `SetSession` comes too late for them: put `GOLUWA_PVARS="key=value key=value"` in the environment instead.


# Git and testing

- Never commit, stage, stash, reset, checkout, branch or push unless the user explicitly asks for it in their latest message, and don't ask whether to. Permission is per request and never carries over: being asked to commit earlier in the conversation, or having committed before, is not a reason to commit again after new work. Finish the work, leave it uncommitted in the working tree, and list what changed. Do not undo or rewrite commits that already exist unless told to. Read-only inspection (`git status`, `git diff`, `git log`) is fine. Never `git stash` for a baseline, use a copy or worktree.
- When asked to commit: no git identity is configured, use `git -c user.name=CapsAdmin -c user.email=eliashogstvedt@gmail.com commit`. To split mixed files, stage hunks with `git diff -U0` and `git apply --cached --unidiff-zero`, and `luajit -bl` each staged file first.
- Commit as several single-purpose, independent commits, never one commit for everything. Each commit covers one concern (a fix, a feature, a theme, a test change) with the tests that go with it, and must stand on its own: no commit may rely on a hunk from a later one. Order them so dependencies come first. When one file carries changes for several commits (a shared theme or base file), split it by hunk, or rebuild each intermediate file state from the final version, so every commit contains only its own lines. Afterwards check that the working tree is clean, that it equals the final state from before the split, and that the suite still passes. Write a short lowercase imperative message per commit and no attribution lines.
- By default, verify changes: run the relevant tests, and for visual or in-game work take a screenshot or run the real scene. Report failures with their output and say what was skipped.
- If told not to test, that only means no harnesses, screenshots or in-game checks. Still run the relevant existing tests and make sure the changed scripts compile (`luajit -bl file.lua`).

# Coding rules

"Hot code" is anything called every frame in the update/render loop, or any function invoked in a tight loop.
If you see code that does the below, consider refactoring if relevant to the task at hand.

- Do not worry about whitespace as the formatter will take care of it.

- Never use camelCase. use snake_case for locals and private fields, PascalCase for methods and globals.

- Favor fixing underlying issues rather than patching symptoms.

- Do not write comments by default. The code is the source of truth; name things so it reads on its own. A comment is allowed only for a hack or workaround (driver/GLSL/Vulkan quirk, ordering constraint, a non-obvious invariant that looks wrong but is required), kept to a line or two, right where the hack is. Never write comments that restate code, narrate a change, record history or measurements, or explain how a system works. If it is generally useful to know about a system, put it in `docs/` instead.

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

# Docs
System specific notes live in `docs/`. Read the relevant file before working in that area.

- [docs/screenshots-and-cameras.md](docs/screenshots-and-cameras.md): `Screenshot`, `Shot`, moving the camera
- [docs/debugging-and-profiling.md](docs/debugging-and-profiling.md): print helpers, the JIT profiler, optimization notes
- [docs/performance.md](docs/performance.md): measuring CPU/GPU time correctly, benchmarks, JIT pitfalls, startup time (the STARTUP tab and the `startup` timers)
- [docs/render3d-lighting.md](docs/render3d-lighting.md): DDGI/GI, fog, sky, clouds, water, shadows, exposure, material and shading pitfalls
- [docs/render3d-pipeline.md](docs/render3d-pipeline.md): surface features and the auto packed gbuffer, Vulkan/GLSL pitfalls, GPU culling, instancing, LOD, scene view, Test3D
- [docs/particles.md](docs/particles.md): the particle system (gpu pools, one compute pass, lit by the sun, local lights and DDGI or the sky), the particle_emitter_gpu and particle_emitter_cpu (gbuffer instancing) components, rain, snow, collision, measuring
- [docs/scatter.md](docs/scatter.md): scatter sets, models (grass, rocks, trees) grown on surfaces on the gpu: set rules, passes, pitfalls
- [docs/foliage.md](docs/foliage.md): procedural trees, grass, rocks and plants (addons/foliage), their textures, model assets and scatter sets
- [docs/terrain-streaming.md](docs/terrain-streaming.md): the Limcore Terrain project (heightmap clipmap, tessellation) and what was taken from it for tiles
- [docs/crysis.md](docs/crysis.md): Crysis level loading, terrain, vegetation, water, performance
- [docs/navigation-and-npcs.md](docs/navigation-and-npcs.md): Source `.nav` meshes, pathfinding, NPC prefabs that walk with Source animations, simulation LOD
- [docs/physics.md](docs/physics.md): solver, stress testing, buoyancy, Source props
- [docs/animation-and-source.md](docs/animation-and-source.md): skeletal animation, Source content, threaded codecs
- [docs/networking.md](docs/networking.md): server/client, replication, players, visibility, ownership and permissions
- [docs/hot-reload.md](docs/hot-reload.md): how `--hot-reload` reloads modules, the import graph, state that survives, pipeline rebuilds, limits
- [docs/prefabs-and-scripts.md](docs/prefabs-and-scripts.md): prefabs, the script component, the use system
- [docs/ui.md](docs/ui.md): render2d/ui widgets, entity construction, input history, autocomplete, undo, icons, asset browser
- [docs/wrappers.md](docs/wrappers.md): macos notes, Love2D and Garrysmod wrappers
- [docs/vulkan-raytrace.md](docs/vulkan-raytrace.md): hardware ray tracing facts and gotchas

Harnesses, benchmarks and repro scripts for one specific purpose go in `./tmp/` (git-ignored), never in the repo. Promote only generic, reusable parts into the engine or `test/`.

Docs in `docs/` are for LLMs: keep them short, general and timeless (concepts, durable pitfalls as rules, how to measure). No diary entries, dated findings, session measurements or per-function summaries; the source is the source of truth.

Only rules that apply to everything belong in this file. System specific lessons (what broke, why, how to measure it) go in the matching doc, not in the assistant's memory. Add new notes to the matching file in `docs/` (or a new one) and add at most a one-line entry here.
