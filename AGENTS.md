# How to run

- Do not run the engine with "luajit glw" only unless asked to. Prefix with "timeout 10 luajit glw" if you must

- Run a single lua script with "luajit glw --2d --one-frame lua './tmp/path/to/file.lua'" 

- If you need to write a temporary script, write it in ./tmp/ 

- Take a screenshot with "luajit glw --2d --screenshot --one-frame lua './tmp/path/to/some/render/script.lua'"

- Run a single test with "luajit glw test --filter=render2d --subfilter='Graphics render2d blend modes visual'"

- Run inline lua with "luajit glw --2d --one-frame lua 'print("hello")'" . For scripts that span multiple lines, prefer writing in tmp, run, adjust/edit, run again, etc.

# Profiling

- The global `PROF` starts the JIT profiler. 

- The profiler uses luajit's statistical profiler internally, and also uses jit.attach to observe trace recording

- By default it runs for 300 frames, stops and prints a text summary, then calls system.ShutDown(0)

```
luajit glw --2d lua "PROF('render', {frames = 1000}) import('tmp/benchmark_test.lua')" -- profille the update loop for 1000 frames, then implicitly shutdown
luajit glw --2d lua "PROF('editor') something_expensive_and_blocking() PROF.stop() system.ShutDown(0)" -- profile a one-off action and shutdown manually
```
- The profile capture is saved to `storage/logs/jit_profile_<id>.glwp` which can be read in detail, ie `PROF.summary("path.glwp", {top_n = 20})`
# General coding rules

- Only use :IsValid when nesseceary, never use it if you are not sure. I'd rather have errors than silent failures.

- If you see code that does the below, consider refactoring if relevant to the task at hand.

- Do not worry about whitespace as the formatter will take care of it.

- never use camelCase. use snake_case for locals and private fields, PascalCase for methods and globals 

- Do not write backwards compatible code unless explicitly asked to.

- Do not normalize arguments. If a function takes a texture, then you must assume that the caller will always pass a texture.

- Favor errors over silent failures, but beware of complex error handling in hot functions. There it might be favorable to just let lua error normally in case of the wrong type.

- Do not worry about breaking compatibility, as this codebase is the only consumer of the APIs you are writing. If you change an API, change it for all code.

- Prefer inling functions over creating very small ones.

- Move local helper functions close to the code that uses them, rather than putting them at the top of the file. Preferably in a do end block that encapsulates its scope to its usage.

- Never create inline functions in hot code. this causes a new closure to be made over and over

- Do not write defensive code like "if obj.SetFoo then obj:SetFoo() end". assume the function exist, and if not, create it at source

- Favor fixing underlying issues rather than patching symptoms

- Do not call import() and require() inline. favor using import at the top. In case of circular dependency, see how import.loaded is used

- If you are using a library like render2d, and it's missing functionality, add it to render2d rather than patching IF the the functionality is generally useful. The same can be applied for standard lua libraries like string and table functions. See goluwa/*

- Consider using functions like table.merge, math.clamp, etc, over creating local functions that duplicate existing functionality

- Always call ffi.cdef and ffi.typeof at the module level, never adhoc inside of a function.

# line and gine wrapper
- Never modify for example a love game's source code. Always fix issues in the wrapper layer.

- In the glua wrapper, always prefer the standard glua code. For example, do not create a new Color object when glua already has a Color object. Only override C functions in glua.

- If render functionality is missing in for example the love2d grpahics api, consider extending the existing engine code rather than patching the wrapper. For example, if render2d is missing alpha testing, add it to render2d.
