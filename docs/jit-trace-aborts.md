# JIT trace aborts

Seeing aborts in detail needs the `jit.log` fork (see debugging-and-profiling.md "jit.log"): every abort carries the reason, the C source site that threw it, the Lua location and an argument (trace number, closure line, local name, limit). The stock `-jv`/`jit.attach` loggers only give the generic reason. JIT options live in `goluwa/jit/options.lua`.

## Side trace head register failures

"NYI: side trace head: no free register to reload spilled slot (...)" means a side trace could not take over its parent's values. A side trace starts at an exit of its parent and must load every slot it reads into a register (on x86-64: 16 xmm registers for numbers, 14 general registers for tables, strings and pointers). There is no fallback, so the Lua code has to change. The message lists the values: `name` is a local where the side trace starts, `name^N` a local N inlined frames up, `slotN` an unnamed temporary, `pval:OP` a field of an allocation the compiler sank, `*` the one that failed.

What is live at an exit:

- Every local still in scope, used afterwards or not. Ending the scope is what kills a local.
- All inlined frames, so callers' locals count, and recursion is inlined several levels deep.
- Loop control slots of enclosing loops.
- Fields of sunk allocations (Vec3 temporaries, tables built and returned in a hot path).

Fixes, roughly in order of preference:

- Move computation into a module-level function that returns only what the caller still needs; its temporaries die at return. Keep it branch-free. This is the one case where a single-use helper is right: put it with its caller in a `do ... end` block.
- Chain stages of a long function with tail calls (`return f(...)`), which replace the caller's frame, passing only what the next stage needs.
- Keep long-lived inputs of a multi-step computation in a scratch table (and nil the locals) so they are read from memory instead of inherited. Storing a temporary table into a longer lived one keeps the allocation, so its fields stop being side trace inputs.
- Use a module level scratch vector as the `out` argument where an API has one (and check that the helper honours it).
- Split a recursive function into a small decision part and the work part.
- Make polymorphic calls before creating locals needed only later; read `self.field` where it is used instead of aliasing it at the top of a long function.
- Prefer branch-free arithmetic over data-dependent branches that flip often (`x % 2^32` for an unsigned wrap).
- Use scalar math instead of Vec3 operators in hot loops: they allocate and run through generated functions that can get blacklisted.
- `do ... end` around a local and its only use when nothing else fits.
- `trace_break()` (`local trace_break = import("goluwa/jit/tracebreak.lua")`, which is `coroutine.running`) cuts the inherited locals: slots the segment after the cut never touches are not in its snapshots, and sunk values are materialized at the cut. Put it at the entry of a function called from a loop that has data dependent exits, or before the block whose exits fail. A break on every call of a very hot tiny function costs more than it saves. `LUAJIT_NO_TRACEBREAK=true` turns every break into a no-op to measure what they are worth.
- A dispatch loop over task kinds (`if kind == A ... elseif kind == B`) chains side traces from one kind into the next iteration. Move order independent kinds into their own loop.
- Unrolling data dependent branches into chains of helper calls multiplies exits; judge such rewrites by the exit count.

## Other reasons

- "Too many spill slots": spill slots are allocated per spilled value and never reused within a trace (limit 256 slots), so what counts is how many distinct numbers a trace ever spills. Large inlined bodies and guards keeping many locals alive hit it. The fork lists the spilled values, nearby Lua lines and producing IR ops.
- Calling a builtin LuaJIT does not record ends the trace and starts a new one after it (stitching), so `trace_break()` can cut a long function into pieces that fit. Locals live across the cut go through the Lua stack.
- "Closure creation (FNEW)" and "closing captured locals (UCLO)": a closure is created in hot code. Hoist it.
- "Loop unroll limit reached by tail calls", "NYI: return to lower frame", "root trace hit compiled inner loop": the trace records more than it should, usually long inlined chains or short inner loops unrolled into an outer trace. The tail call counter counts every `return f(...)` executed in the trace and shares the `loopunroll` limit; the fix is a boundary or smaller scope, not rewriting getters.
- "Too many exit stubs for N snapshots" is a hard x86-64 assembler limit of 512 snapshots. Do not set `maxsnap` to 512 to avoid it: the recorder counts more snapshots than many finished traces keep, so that aborts traces that would have fit.
- A long generated straight-line function (block writers with dozens of fields) can exceed snapshot or tail call limits as one trace and then always runs interpreted, where every ffi field access allocates. Emit a `trace_break()` every few statements in the generated code.
- "Blacklisted" is caused by earlier aborts of that function or loop. In stock LuaJIT, tiny functions called from metamethod continuation frames (generated Vec3 operators, getters) fail with "return to lower frame" and get blacklisted, after which every trace that inlines them aborts; whether that happens early in a run decides between a fast and a slow run. The fork records blacklisted function headers normally, which removes the effect for functions but not for blacklisted loops. Code that must stay fast on stock LuaJIT keeps generated operators out of hot code.
- `select(1, f(...))` may stitch; `(f(...))` or `local x = f(...)` truncates without a call.
- Trace compilation is non deterministic, and "error thrown or hook called during recording" can come from the profiler itself.

## Exits and what runs interpreted

- The log counts exits that leave compiled code without a side trace (with the Lua location and the guard, e.g. `GE.NUM`, `SLOAD.INT`); the reader prints them as "top exits out of compiled code".
- Fewer exits is not the goal: removing them can push a loop trace over the spill limit or get it blacklisted, leaving more code interpreted. Judge by the interpreter share (`I`), compiled share and step time on a steady-state run together with exit and abort counts.
- A side trace that links straight back to the interpreter is a stub. Stubs appear when `tryside` attempts are used up, when the root already has `maxside` side traces (stubs count), or after a failed recording. Every execution of a stub branch leaves compiled code. Keep `maxside` above the largest root's side trace count.

## Root traces and stitching

- A root trace starts at a hot loop head, a hot function entry, or after a stitched builtin call. Only a root that starts at its own loop head can loop back to itself; a continuation in the middle of a loop body cannot, so a `trace_break()` inside a loop body does not make the loop a root. Code after a loop is a side trace of the loop exit, which is where its inherited locals come from.
- There is no way to start a trace at a chosen place.
- Option constraints for `jit_options.SetOptimized` in `goluwa/jit/options.lua`: `tryside` must be at least 1 (0 turns every side trace into a stub), `minstitch` must stay 0 or the small traces between `trace_break()` calls are discarded, `maxsnap` must stay well above 512.

## Retries and compile time

- A failing exit gets `tryside` attempts, then a stub ends the retries. Deterministic failures repeat identically, so retries are wasted compile time; judge `tryside` changes by steady-state frame times as well as load time.
- If the stub itself cannot assemble (head register failures), the exit retries until its counter runs out; those need code fixes.
- Compile time is the span between a trace's start and stop/abort records; samples in the compiler are the `R` vm state.

## Measuring

- Which exits become hot depends on timing, so failing sites change between runs. Compare several runs per variant (`LUAJIT_SEED` for a fixed seed) by named sites, interpreter share and step time, not by one total.
- Many trace starts at one Lua line with different parents are the function inlined into every caller's trace, not a retry loop: the fix is a boundary (a non inlined stage with `trace_break()` at its entry). Group `trace_start` records by function and parent to tell them apart.
- Verify a fix by the site no longer appearing and by identical output on random inputs. JIT state does not change numerical results, so a hash of the final simulation state proves a restructuring neutral.
- A speed-up that is too good usually means the code stopped doing work. Run the tests before trusting it.
- For physics, a single body exercises little: run the zones of `test/benchmarks/physics_stress.lua` and scenes with many shapes, mesh worlds, queries and water under the log.
