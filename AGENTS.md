# general coding rules

- If you see code that does the below, consider refactoring if relevant to the task at hand.

- Do not worry about whitespace as the formatter will take care of it.

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

- If you are using a library like render2d, and it's missing functionality, add it to render2d rather than patching IF the the functionality is generally useful. The same can be applied for standard lua libraries like string and table functions. See goluwa/helpers/*

- Consider using functions like table.merge, math.clamp, etc, over creating local functions that duplicate existing functionality

# line and gine wrapper
- Never modify for example a love game's source code. Always fix issues in the wrapper layer.

- In the glua wrapper, always prefer the standard glua code. For example, do not create a new Color object when glua already has a Color object. Only override C functions in glua.

- If render functionality is missing in for example the love2d grpahics api, consider extending the existing engine code rather than patching the wrapper. For example, if render2d is missing alpha testing, add it to render2d.
