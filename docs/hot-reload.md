# Hot reload

`--hot-reload` watches `goluwa/` and `addons/`. A saved file that was loaded through `import` is reloaded as a module, anything else (addon scripts, tests) is just run again as before. A `--[[HOTRELOAD ...]]` block in the file or a `hotreload.lua` next to it still takes over and runs its own code instead.

## How a module reloads (`import:Reload`, `watcher.ReloadModule`)

- The file is compiled first, a syntax error leaves everything as it was. A runtime error restores the functions that were removed.
- The module's own functions (the ones whose source is that file, not ones other files added to a shared table) are removed from its table, then the file runs again. Stale functions disappear and the table stays.
- The file returns a fresh table (`local x = {}`), so its closures are pointed at the old table and the new contents are copied over, so everyone holding the table sees the new code. There is no `library()`, every module is a plain table. Object classes (`Type` set) are left to `objects.Register`.
- State survives automatically. A snapshot is taken right after each load. A field of the module table, or a file local (upvalue) that is a table/cdata/userdata, that changed since the snapshot is kept, unless the file now sets a different value. Strings, numbers and booleans in locals are not kept on purpose: they are usually caches of what the edited code makes, or a size that belongs to a buffer that was just made again. Fields keep those too. A `state` table in the module is covered by the same rule.
- Locals are matched by the function they are reached from and their position, never by name alone. Matching by name swapped unrelated locals and segfaulted ddgi.

## The import graph

`import.imports`, `import.importers` record who imported what **while loading** (imports made later from inside functions fetch the module again every call, so they cannot go stale). `import.strong[importer][dep]` is set when the importer read from `dep` while loading, by calling it (a glsl builder) or taking a value out of it. `goluwa/load_time_uses.lua` finds that from the bytecode (`jit.util`) of the module's main chunk: a table read from the register an `import()` result went into, also inside local functions the main chunk calls while loading (`local function common_glsl()` called at the top level). Local function and alias names are read from the source text. No debug hook is involved.

After a module reloads, importers load again if
- the module was replaced by a new value (not a namespace table), or
- the importer used it while loading (`strong`).

They are ordered so dependencies go first, then `ModulesReloaded` is called with the list. More than 100 modules and it reloads only the changed module, warning that importers which took values from it while loading keep the old ones (`render3d/math3d.lua`). If the module is replaced by a new value instead of updated in place it refuses, since importers can't be updated.

Limits: reads that only happen inside functions that are exported and called by something else during load (`mod.Build()` at the top level of a file) are not followed, only local functions are. Caches that are tables are kept, so a table cache filled by code you then edited stays stale until restart.

## Renderer

`ModulesReloaded` in `render3d.lua` rebuilds every live pipeline bundle when a default pass module reloaded. The new pipelines are built first and swapped into the same `pipelines`/`pipelines_i` tables, so contexts holding them stay valid, and a shader that fails to compile logs the error and keeps the old pipelines running. Editing a glsl helper therefore reloads the helper, the passes that import it, and rebuilds the pipelines.

luajit never frees anonymous struct types (about 65k in total, `table overflow`), so every pipeline build used to burn some. `glsl_metadata.typeof` caches them by declaration text, use it for any per pipeline struct. Do not cache `ffi.typeof` globally, vk.lua declares the same text twice and gives each a metatype.

## Known gaps

- `render/easy_pipeline.lua` cannot reload alone (it calls `:Register()` on a meta made in another file).
- Modules with a lot of dependents (`math3d.lua`, core libraries) only get their own functions updated, values other modules baked in need a restart.
- render2d, entity components and the other `if HOTRELOAD` blocks (atmosphere, clouds, envprobe, render2d) still do their own cleanup; only render3d pipeline bundles are rebuilt by the graph.
- Tests: `luajit glw test other/hotreload.lua`. Scratch harnesses that reload every render file in a live scene are easy to write: call `import("goluwa/filesystem/watcher.lua").Reload(path)` from an Update listener under `--3d --hot-reload`.
