# Hot reload

`--hot-reload` watches `goluwa/` and `addons/`. A saved file that was loaded through `import` is reloaded as a module; anything else (addon scripts, tests) is just run again. A `--[[HOTRELOAD ...]]` block in the file or a `hotreload.lua` next to it takes over and runs its own code instead. Never edit `goluwa/` or `addons/` files while a benchmark or scene run is going with `--hot-reload` on: the reload resets state and crashes the run.

## How a module reloads (`import:Reload`, `watcher.ReloadModule`)

- The file is compiled first; a syntax error leaves everything as it was. A runtime error restores the removed functions.
- The module's own functions (those whose source is that file, not ones other files added to a shared table) are removed from its table, then the file runs again: stale functions disappear and the table stays. A file that returns a fresh table has its closures pointed at the old table and the new contents copied over, so everyone holding the table sees new code. Object classes (`Type` set) are left to `objects.Register`.
- State survives automatically: a snapshot is taken after each load; a module table field or file local (upvalue) that is a table/cdata/userdata and changed since the snapshot is kept, unless the file now sets a different value. Strings, numbers and booleans in locals are not kept on purpose (usually caches of what the edited code makes). Locals are matched by the function they are reached from plus position, never by name alone.

## The import graph

`import.imports`, `import.importers` record who imported what while loading (imports inside functions fetch the module each call, so they cannot go stale). `import.strong[importer][dep]` is set when the importer read from `dep` while loading (called it, or took a value out of it); `goluwa/load_time_uses.lua` finds that from the bytecode (`jit.util`) of the main chunk, including local functions the main chunk calls while loading.

After a module reloads, importers load again if the module was replaced by a new value (not a namespace table) or the importer used it while loading. They are ordered dependencies first, then `ModulesReloaded` is called with the list. Beyond `MAX_MODULES` (100, `watcher.lua`) only the changed module reloads, with a warning that importers which took values from it keep the old ones. A module replaced by a new value instead of updated in place is refused.

Limits: reads that happen only inside exported functions called by something else during load are not followed (only local functions are); table caches are kept, so a cache filled by code you then edited stays stale until restart; modules with many dependents (core libraries) only get their own functions updated.

## Renderer

`ModulesReloaded` in `render3d.lua` rebuilds every live pipeline bundle when a default pass module reloaded: new pipelines are built first and swapped into the same `pipelines`/`pipelines_i` tables, and a shader that fails to compile logs the error and keeps the old pipelines. Editing a glsl helper reloads the helper, the passes importing it, and rebuilds pipelines. LuaJIT never frees anonymous struct types (about 65k, then `table overflow`), so per-pipeline structs go through `glsl_metadata.typeof` (cached by declaration text); do not cache `ffi.typeof` globally.

## Known gaps

- `render/easy_pipeline.lua` cannot reload alone (it calls `:Register()` on a meta made in another file).
- render2d, entity components and other `if HOTRELOAD` blocks (atmosphere, clouds, envprobe) do their own cleanup; only render3d pipeline bundles are rebuilt by the graph.
- Tests: `luajit glw test other/hotreload.lua`. For scratch checks call `import("goluwa/filesystem/watcher.lua").Reload(path)` from an Update listener under `--3d --hot-reload`.
