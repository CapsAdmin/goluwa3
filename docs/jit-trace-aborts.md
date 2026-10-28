# JIT trace aborts

Seeing aborts needs the `jit.log` fork (see debugging-and-profiling.md "jit.log"). Every abort there carries the reason, the C source site that threw it, the Lua location, and an argument (trace number, closure line, local name, limit). The stock `-jv`/`jit.attach` loggers only give the generic reason.

## Side trace head register failures

"NYI: side trace head: no free register to reload spilled slot (...)" means a side trace could not take over its parent's values. A side trace starts at an exit of its parent and must get every slot it reads into a register. On x86-64 that is 16 xmm registers for numbers (FPR) and 14 for tables, strings and pointers (GPR). The compiler has no fallback, so the Lua code has to change. The message lists the values: `name` is a local of the function where the side trace starts, `name^N` a local N inlined call frames up, `slotN` an unnamed temporary, `*` the one that failed, followed by how many sit in registers vs spilled in the parent.

What counts as live at an exit:

- Every local still in scope at the next jump, whether or not it is used afterwards. Only slots above the active locals of that jump are dropped (`snap_usedef` stops at the first jump, call or return). Ending the scope is what kills a local.
- All inlined frames of the trace, so locals of callers count, and recursion is inlined several levels deep.
- Loop control slots of enclosing loops, and any number as an FPR value.

Fixes, in order of preference:

- Move computation into a module-level local function that returns only what the caller still needs. The callee's temporaries die at return. Keep the callee branch-free so it has no exits of its own. This is the one case where extracting a helper is right even though nothing else uses it: put it with its single caller in a `do ... end` block.
- A tail call (`return f(...)`) replaces the caller's frame, so the caller's locals are not inherited by exits inside `f`. Chain stages of a long function with tail calls and pass only what the next stage needs.
- A table that never leaves the trace is removed by allocation sinking and every one of its fields becomes a separate input of every side trace (the `pval:OP` entries). Storing it into a longer lived table (`self.last_result = t`) keeps the allocation, and its fields stay in memory.
- Locals that stay in scope are inherited, but a value that is only read back from a table or a nil-ed local is not. Moving the long lived inputs of a multi step computation into a scratch table (and nil-ing the locals) keeps them out of the side traces of the steps.
- Split a recursive function into a decision part (small frame) and the work part, so the recursive call holds few locals.
- Call getters and other polymorphic calls before creating locals that are only needed later.
- Read a table field from `self` where it is used instead of aliasing it in a local at the top of a long function, when the alias is only needed in one phase.
- A data-dependent branch that flips often (a sign test on a hash, a nil-or-table result) makes a hot exit. Prefer branch-free arithmetic (`x % 2^32` for an unsigned wrap) where the result is identical.
- Vec3 operators allocate and run through generated operator functions that get blacklisted after repeated aborts; scalar math in hot loops avoids both.
- `do ... end` around a local and its only use is the minimal fix when no helper fits.
- A `trace_break()` (see below) placed before a block or at the start of a function cuts the inherited locals without restructuring: slots the segment after the cut never touches are not in its snapshots, so exits inside it do not inherit them. Put it in front of the code whose exits fail, on a rarely taken branch when the branch is rare, and note that a hot call site pays the stitch on every call.
- Allocations that the compiler sinks (Vec3 temporaries, `GetSegmentWorld` results) turn into `pval:` inputs of every side trace after them. Pass a module level scratch vector as the `out` argument where the API has one, or put a `trace_break()` right after the values are computed: at the cut the vectors are materialized and the later exits read them from memory. Check that an `out` parameter is honored; a helper that ignores it still allocates.
- Put the break at the entry of a function that is called from a loop and that contains data dependent exits (a nested table lookup, an AABB test, a pair handler). Exits inside it then inherit the callee's own locals instead of the whole caller chain. A break on every call of a very hot tiny function costs more than it saves, so prefer one break per query or per pair.
- Do not unroll data dependent branches into a chain of helper calls to avoid a loop with early returns: it turned a few exits into hundreds of thousands and made the scene slower. Judge by the exit count.
- A dispatch loop over task kinds (`if kind == A ... elseif kind == B`) chains side traces: the side trace of one kind keeps recording into the next iteration and can exceed the snapshot limit. Move kinds that are order independent (a final max or commit) out into their own loop after the sweep.

## Other reasons

- Spill slots are allocated per spilled value and never reused inside a trace, so what counts is how many distinct numbers a trace ever spills, not how many are live at once. One inlined function with five long arithmetic tests can exceed it. Calling a builtin LuaJIT does not record ends the trace there (`coroutine.running()` costs about 10 ns and has no effects; `jit.status()` builds strings and costs over 100 ns) and starts a new one after the call (trace stitching), so a long function can be cut into pieces that each fit. The locals live across the cut are written to and read from the Lua stack.
- "Too many spill slots (...)" lists how many values were spilled (the limit is 256 slots, so 128 numbers), their types, the Lua lines nearest where they were defined (found through the nearest snapshot, so only approximate) and the IR ops that produced most of them. A trace with many guards keeps every in-scope local alive in its snapshots; large inlined bodies (several triangle tests, Vec3 copies) hit this limit.
- "Closure creation (FNEW)" and "closing captured locals (UCLO)": a closure is created in hot code (the log gives the closure's first line and the captured local). Hoist it out of the loop. Both abort the trace.
- "Loop unroll limit reached by tail calls", "too many spill slots", "NYI: return to lower frame", "root trace hit compiled inner loop (trace N)": the trace includes more than it should; the abort site and Lua location show which call chain. Long inlined chains and short inner loops that get unrolled into an outer trace are the usual cause.
- "Too many exit stubs for N snapshots" is a hard assembler limit of 512 snapshots on x86-64 (32 stubs per group, 16 groups). Do not lower `maxsnap` to 512: the recorder counts more snapshots than many traces end up with, and at 512 several times more traces aborted and compile time went up.
- A long generated straight-line function (a block writer with dozens of fields, each a getter, a method call or a tail call) exceeds the snapshot limit or the tail call counter as one trace and then always runs interpreted, where every ffi struct field access allocates. Emit a `trace_break()` every few statements in the generated code.
- "Blacklisted": the function aborted repeatedly. A root trace started by a hot call of a tiny function (the generated Vec3 operators, getters) fails with "NYI: return to lower frame" when the caller is a metamethod continuation frame, and after a few failures the function header is patched to its interpreter-only form. In stock LuaJIT every trace that then inlines that function aborts with "blacklisted", so whether such a function gets blacklisted early in a run decides between a fast run and one that is two to three times slower (the interpreter and C shares jump). The fork records the interpreter-only function header like a normal one (`BC_IFUNCF`), which removes the effect for functions; blacklisted loops (`trace.lua` inner loops) still poison their callers. Code that stays on stock LuaJIT should keep the generated operators out of hot code.
- `select(1, f(...))` is a builtin LuaJIT cannot always record and stitches the trace. `(f(...))` truncates to the first value without a call, and a plain `local x = f(...)` already does.
- "Loop unroll limit reached by tail calls": the counter is the number of `return f(...)` executed anywhere in the trace (builtins included, returns do not reset it) and shares the `loopunroll` limit. It is a proxy for a trace that records too far, typically a stitched continuation that follows returns up through its callers. Rewriting the getters does not help, the trace needs a boundary or a smaller scope.

## Exits and what runs interpreted

- The log counts exits that leave compiled code without a side trace (per trace and exit, with the Lua location and the guard that exits, e.g. `GE.NUM` a float comparison, `SLOAD.INT` a type guard). The reader prints them as "top exits out of compiled code", with how many side traces for that exit compiled or aborted.
- Fewer exits is not the goal. Exits are short, and a restructuring that removes them can make a surrounding loop trace exceed the spill limit or get blacklisted, which leaves much more code interpreted. Judge a change by the interpreter share (`I`), the compiled share, and step time on a steady-state run (thousands of steps), together with the exit and abort counts; warm-up compile time dominates short runs.
- `pval:OP` entries in a register failure are values of the parent trace that are not Lua locals (the fields of allocations the compiler removed, held in registers) and `OP` is the instruction that produced each. A table built in a hot path and returned or passed on is the usual source.

## Root traces, stitching and links to the interpreter

- A root trace starts at a hot loop head, a hot function entry, or right after a stitched builtin call (a continuation). Only a root that starts at its own loop head can loop back to itself. A continuation in the middle of a body cannot link into a loop that is already compiled ("root trace hit compiled inner loop") and aborts at the back edge of one that is not ("hit an inner loop that is not compiled yet", "ran past the end of the loop body"). A `trace_break()` inside a loop body therefore does not make the loop a root. Code after a loop is compiled as a side trace of the loop's exit, which is where the inherited locals come from.
- There is no way to start a trace at a chosen place. `hotloop` and `hotexit` did not change which traces form; leave them at the defaults.
- A side trace that links to the interpreter with a few instructions is a stub. It is created when `tryside` attempts are used up, when the root already has `maxside` side traces, or after a failed recording of that exit. Every execution of such a branch leaves compiled code, which shows as C state samples (exit handling) on the line plus interpreter samples. Count side traces per root against `maxside`; stubs count as side traces, and a root at the limit gets stubs for every new hot exit. Keep `maxside` above the largest root.
- The side trace limits that matter in `goluwa/jit/options.lua`: `tryside` needs to be at least 1 (at 0 every side trace becomes a stub immediately), `loopunroll` limits both loop unrolling and the tail call counter and lower values cost more tail call aborts than they save in stub aborts, `minstitch` has to stay 0 or the small traces between `trace_break()` calls are discarded, `maxsnap` has to stay well above 512 (see above), and `maxrecord` only bounds recording work of traces that fail anyway.

## Retries and compile time

- A failing side exit gets `tryside` real attempts, then a stub trace that links to the interpreter ends the retries. Deterministic failures (spill slots, unroll limits, NYI) repeat identically, so the repeats are wasted compile time. Lower `tryside` in `goluwa/jit/options.lua` trades that against abandoning exits whose failure depends on the recorded path. Judge it by frame times on a steady workload, not only by load time.
- If the stub itself cannot assemble (head register failures), the exit is never marked done and retries until its 8-bit counter runs out. Those need the code fixes above.
- Compile time is the time between a trace's start and stop/abort records. The share of samples in the compiler is the `R` vm state. The profile hook is not set while the compiler runs because it replaces instruction dispatch and would make the recorder miss one.

## Measuring

- Which exits become hot depends on timing, so the set of failing sites changes between runs. Compare several runs of each variant and judge by named sites and compile time, not by one total. Startup runs have 0.3-0.5 s of noise.
- A fix is verified by the site no longer appearing and by the output being identical to the old function on random inputs (compare with `==`).
- JIT state does not change numerical results, so a hash of the final simulation state is identical across runs and across fixes; use it to prove a restructuring is neutral.
- A speed-up that is too good usually means the code stopped doing work (a scratch buffer that is never filled, a pooled object that is never written). Run the test suite before trusting a number.
- One body on terrain exercises a small part of the engine. Run the zones of `test/benchmarks/physics_stress.lua` (stacks, mixed shapes, chains, projectiles) and scenes with many capsules, a triangle mesh world, ray and sweep queries and water under the log as well: most head failures sit in pair handlers, manifold code and shape traces that a single capsule never reaches. Keep a hash of the final state per scene to prove a restructuring neutral.
- Judge a change from several runs of the same seeded scene (`LUAJIT_SEED`), looking at the abort reasons by site, the interpreter share and the step time together.
