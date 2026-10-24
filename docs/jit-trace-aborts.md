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
- Split a recursive function into a decision part (small frame) and the work part, so the recursive call holds few locals.
- Call getters and other polymorphic calls before creating locals that are only needed later.
- Read a table field from `self` where it is used instead of aliasing it in a local at the top of a long function, when the alias is only needed in one phase.
- A data-dependent branch that flips often (a sign test on a hash, a nil-or-table result) makes a hot exit. Prefer branch-free arithmetic (`x % 2^32` for an unsigned wrap) where the result is identical.
- Vec3 operators allocate and run through generated operator functions that get blacklisted after repeated aborts; scalar math in hot loops avoids both.
- `do ... end` around a local and its only use is the minimal fix when no helper fits.

## Other reasons

- "Closure creation (FNEW)" and "closing captured locals (UCLO)": a closure is created in hot code (the log gives the closure's first line and the captured local). Hoist it out of the loop. Both abort the trace.
- "Loop unroll limit reached by tail calls", "too many spill slots", "NYI: return to lower frame", "root trace hit compiled inner loop (trace N)": the trace includes more than it should; the abort site and Lua location show which call chain. Long inlined chains and short inner loops that get unrolled into an outer trace are the usual cause.
- "Too many exit stubs for N snapshots" is a hard assembler limit of 512 snapshots on x86-64 (32 stubs per group, 16 groups). `maxsnap` above 512 only makes such traces fail later, after full recording and assembly.
- "Blacklisted": the function aborted repeatedly and is interpreted from then on. Fix the aborts that came before it.

## Retries and compile time

- A failing side exit gets `tryside` real attempts, then a stub trace that links to the interpreter ends the retries. Deterministic failures (spill slots, unroll limits, NYI) repeat identically, so the repeats are wasted compile time. Lower `tryside` in `goluwa/jit/options.lua` trades that against abandoning exits whose failure depends on the recorded path. Judge it by frame times on a steady workload, not only by load time.
- If the stub itself cannot assemble (head register failures), the exit is never marked done and retries until its 8-bit counter runs out. Those need the code fixes above.
- Compile time is the time between a trace's start and stop/abort records. The share of samples in the compiler is the `R` vm state. The profile hook is not set while the compiler runs because it replaces instruction dispatch and would make the recorder miss one.

## Measuring

- Which exits become hot depends on timing, so the set of failing sites changes between runs. Compare several runs of each variant and judge by named sites and compile time, not by one total. Startup runs have 0.3-0.5 s of noise.
- A fix is verified by the site no longer appearing and by the output being identical to the old function on random inputs (compare with `==`).
