# gm_construct_m3_401 measurement scripts

Scratch scripts from the 2026-10-13 CPU and GPU pass over the heavy metastruct map (see `docs/performance.md`). All of them load the map through `harness.lua`, wait for the scene to settle and put a camera at the lobby spawn. Run them from the repository root, always with `--background` and without `--validate` when timing:

```
M3_CULLING=0 luajit glw --3d --background lua "import('test/harnesses/m3/measure.lua')"
```

Environment shared by all of them: `M3_CULLING=0` turns off visibility culling (the worst case, `r_feature_culling`), `M3_LOD`, `M3_POS=x,y,z` and `M3_YAW`/`M3_PITCH` move the camera (engine units), `M3_MOVE=speed` flies it along its forward vector, `M3_FRAMES` is how many frames are measured. An env var set to an empty string is truthy in Lua, `unset` it.

| script | what it prints |
| --- | --- |
| `measure.lua` | average, p50 and p95 frame time, allocation rate, CPU recording time and GPU time of the top passes |
| `sweep.lua` | the same for several pvar variants in one process (`M3_SWEEP="name=key:value,key:value;name2=..."`), the first variant is run again at the end as a control |
| `time_fn.lua` | wall time of every event listener and of chosen functions per frame, to see where a frame goes |
| `block_time.lua` | where the CPU blocks: swapchain acquire, fences, submits. A big `GetNextImage` means the GPU is the bottleneck |
| `spikes.lua` | frame time histogram and what is slower in the worst frames, `M3_GC_PAUSE`/`M3_GC_STEPMUL`/`M3_NOGC` for GC experiments |
| `prof.lua` + `ptree.lua` | a JIT profile of the settled scene and an analysis of it: `PT_FILE=storage/logs/jit_profile_<tag>.glwp PT_STATE=G PT_UNDER=<text> PT_CALLERS=<text> luajit glw --cli lua "import('test/harnesses/m3/ptree.lua')"` |
| `alloc.lua`, `alloc_ev.lua` | KB allocated per frame per pass scope and per event listener, with the collector stopped |
| `bench_record.lua` | microbenchmark and profile of the batch record writer |
| `census_run.lua` | what the live Lua heap is made of |
| `verify_caches.lua` | checks the cached upload keys and every batch table record against a from-scratch computation for all materials of the map |
| `ab_shot.lua`, `ab_inproc.lua`, `psnr.sh` | screenshots of fixed views at a locked exposure and frozen time, and PSNR between two sets. Compare against a copy of an older commit made with `git archive` (symlink `storage` and `tmp` into it), across processes the noise floor is 33-44 dB depending on the view |
