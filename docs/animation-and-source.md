# Animation and Source engine content

Notes collected from past sessions. Dated numbers are snapshots; re-measure before relying on them.

## Skeletal animation

*animator component, neutral Skeleton, Source .ani/include/pose-param pitfalls, RT excluded*

Skeletal animation is a format-neutral `animator` component (goluwa/entities/components/animator.lua) + `goluwa/render3d/skeleton.lua`. Decoders return `skeleton` via a 5th `skeleton_callback`; Visual stores it as `visual.Skeleton`. A skeleton is engine-space bind pose + inverse bind + clips with `clip:Sample(cycle, params, out)`; cry decoders only need to produce that.

Skinning is on the GPU (goluwa/render3d/skinning.lua, one dispatch for all animators, bone matrices uploaded per animator). The animator clones each skinned primitive's mesh (`Polygon3D:CloneDynamic`, one shared vertex buffer per `Skin`) and skinning rewrites it. scene_bvh follows animated blocks (compute rewrite of the soup range + in place BLAS update). Distance based update rate with per animator phase.

Source format gotchas (all verified on gmod player models):
- player models only have `reference`; animations come from `$includemodel` (m_anm/f_anm) and live in `.ani` animblocks (block 0 = in the mdl, relative to the animdesc; else relative to block datastart in the .ani)
- clip names are sequences, not the `@` animdescs; walk/run are 3x3 blends over move_x/move_y (-1..1), so default 0,0 = standing — set `SetPoseParameterByName("move_x", 1)`
- ANIMROT/ANIMPOS values decode against the *owning* file's bone pos/rot/scales; remap bone index by name to the main skeleton
- missing includes (vortigaunt m_gst etc.) are logged and skipped, not fatal
- vertices of a mesh start at `mstudiomodel.vertexindex/48 + mstudiomesh.vertexoffset` in the vvd; the old "sum of max vertex index" guess broke TF2 and zombie_classic. mdl v49 (tob_magilou) has a 33 byte vtx strip group header instead of 25
- setting a different Sequence resets time and crossfades; call SetTime after the switch has resolved (next Update)
- ground speed: an animdesc has `nummovements` (+20) and `movementindex` (+24), 44 byte `mstudiomovement_t` blocks (endframe, flags, v0, v1, angle, vector, position). The last block's `position` (floats 8..10, source units) is where the animation ends up after one cycle, `v0` and `v1` are the same number per cycle and not units per second. `clip:GetGroundSpeed(params)` is |that| over the duration, blended over the pose parameters like the pose itself (walk_all of the citizens 80 u/s, run_all 210, combine soldier 72/215, zombie 45, antlion 195/355). See [Navigation and NPCs](navigation-and-npcs.md)

Rig / Pose layering (components never touch ffi or GPU buffers):
- `Skeleton:NewPose()` gives an opaque `Pose` (Reset/Copy/Sample(clip, cycle, params)/Blend(a, b, t)); raw float arrays (CreatePose, BlendPoses, ComputeSkinMatrices) are the decoder/clip level
- `render3d/rig.lua`: `Rig.New(skeleton, parts)` made by the animator on Bind (`animator:GetRig()`). `SetPose`, `SetBone(name, Matrix44, "local"|"model")`, `ClearBone(s)`, `GetBone(name)` -> model space Matrix44, `SetFlex/GetFlex/GetFlexNames/GetFlexRange`, `Update()` (computes what changed and queues skinning). Matrix44 has the translation in the last row, rig matrices are 3x4 with it in the last column
- `skinning.lua` takes rigs (not animators); jobs are 64 bytes with optional morph addresses

Flexes (faces):
- `skeleton.Flex` (ControllerNames/Min/Max, DescCount, `Compute(flex, src, dest)` = port of Valve's `RunFlexRules`, studio.cpp in source-sdk-2013) and `skin.Flexes` (per model, vertex deltas in engine space, absolute vertex indices) come from the mdl. Targets are a trapezoid (0,1,10,11 typical); `Pair` + per vertex `Sides` (0..255) blend two descriptors across the face
- morphs run on the GPU: `skinning.GetMorphData(skin)` packs the entries per vertex once per skin (shared by all rigs); the rig uploads two weights per flex entry each frame with the bone matrices and the skinning shader adds `delta * (w1 + (w2 - w1) * side / 255)` to the bind position and normal before skinning. Flex rules run at rig creation, so the default neutral shapes apply
- `flex` component = controller values by name + editor sliders + save/load, pushes into the rig when the animator makes a new one. `bone_pose` component = position/angles per bone in the bone's local space, same pattern
- editor: `META:GetDynamicProperties()` (per instance property infos with `get`/`set`/`min`/`max`/`slider`); fire `objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})` when the list changes and the property editor rebuilds
- gmod face presets (`garrysmod/settings/presets/face/*.txt`) are `faceposer_flexN` = value of controller N (0-based) in raw controller units

Test3D files share one descriptor set budget (16 compute passes per process, frame number does not advance), so flex and rig tests live in their own files (test/tests/render3d/flex.lua, rig.lua). Long WaitUntil loops in Test3D also use up that budget through other compute passes, so check real models on the CPU there.

Not done: delta/additive sequences, FRAMEANIM anims, IK, root motion, events, per-sequence bone weights, autolayers, eye look/jaw/bone flex drivers, wrinkle maps, tangent morphs, bone attachments, a world space bone override. Editor sequence dropdown is built when the entity is selected, so select after the model loaded.

## Animation stress on gm_construct

*harness, -89 pitch, scaling numbers*

The maintained version is `luajit glw bench gm_construct_animation` (test/benchmarks/gm_construct_animation.lua, see [Frame benchmark + glw bench](performance.md#benchmarks)), which loads `gm_construct` through `commands.RunString("map gm_construct")`, waits for `BVHSceneReady` (about 12 s), then spawns centered NxN grids (STRESS_LEVELS="0,5,10,15,20,25", STRESS_SECONDS, STRESS_SPACING, STRESS_CAM="x,y,z,pitch,yaw" relative to the floor) of the 83 player models, measures frame time, GPU scopes and animation CPU per level and saves a birds-eye shot per level.

Overhead views must use pitch -89, not -90: at exactly -90 the characters did not render at all (only their shadows).

Numbers (2026-10-03, run2): 0 models 16.7 ms, 25: 19.6, 100: 21.4, 225: 24.4, 400: 27.4, 625: 32.0 ms; always GPU-bound. At 625 (413 actually animating): skinning 2.75 ms GPU, ddgi_resolve +5.5, gbuffer +2.1, ddgi_trace +1.7, rt_build +0.7. CPU: pose sampling about 17 ms/frame, EnsureRTBuilt 4.2 (rewrite 2.4), skinning dispatch 0.3. Frame times varied 32-39 ms between runs of the same level.

About a third of the player models have no usable animation (missing m_* includes) and stay in bind pose, so the animating count is about 2/3 of the grid.

The stress run found a real bug: skinning.Dispatch indexed a removed animator's nil skeleton (fixed by checking IsValid first). Also raised skinning/scene_bvh animation caps; the original 4096 bone matrices only fit about 70 characters.

Related: [Skeletal animation](#skeletal-animation), [gm_construct_m3 profiling](performance.md#what-cost-what)

### 2026-10-03 later: LOD, flat dispatch and the unresolved GPU hang

Animator LOD (animator.lua): update interval grows with camera distance from 0 (<= LOD_NEAR 15 m) to 1/LOD_MIN_RATE (5 fps) at LOD_FAR 80 m; each animator updates when `floor(time / interval + phase)` changes (random fixed phase, self-healing after hitches; a one-time or jittered offset did not survive model-load hitches). Settle pass only for gaps > 0.04 s. Far camera (110 m, 25x25): frame 17.8 vs 24.0 ms without LOD, skinning 0.47 vs 2.7 ms GPU, pose sampling 2.8 vs 11.4 ms CPU.

Static 25x25 control is 23.0 ms; animated is about 29 ms.

**Open problem:** animated crowds spawning on gm_construct with ray tracing intermittently hang the GPU (kernel Xid 109 CTX SWITCH TIMEOUT -> error_device_lost, or garbage/black screenshots with no error). Check `journalctl -k | grep Xid`, a run can hang without printing device_lost. Not seen with static models (0/2), with GOLUWA_NO_RAY_TRACING=1 (0/3), or without LOD (0/3, small samples); seen at about 1/3 to 2/3 of runs otherwise, also with BVH animation off (1/3), refit vs rebuild makes no difference, 2D vs 1D dispatch no difference. Ruled out: NaN or far skinned vertices (checked at level ends), corrupt model data (all 83 player models decode clean, only tob_magilou fails to load), shared BLAS groups, double builds per frame, burst size (budget), update scratch size (fixed anyway). Not ruled out: something in the spawn frames when hundreds of private BLASes appear.

Fixed along the way: skinning.Dispatch nil skeleton for removed animators, TLAS slot exhaustion, update scratch size, group dedupe, `Dynamic` flag so unbound skinned models stay static in the BVH, 2D dispatch left at ROW 65535.

With `--hot-reload` on, never edit goluwa/ files while a stress run is going: the reload resets scene_bvh state and crashes it.

## Source spec grid vs GMod

*test/harnesses/specgrid harness, VTF alpha flag, envmap/phong semantics, known gaps*

test/harnesses/specgrid/gen.lua writes flat-colour VTFs + VMTs into GarrysMod/garrysmod/materials/specgrid/ (rows: envbase, envnormal, envtint, phongnormal, phongbase, phongexp). GMod side: garrysmod/lua/specgrid.lua via `lua_openscript_cl` (needs `developer 1` for debugoverlay, `fov_desired 90` by hand). Engine side: test/harnesses/specgrid/engine.lua with SPECGRID_EYE=x,y,z (printed by gmod), SPECGRID_LIVE=1 to stay running.

- Generated VTFs need flag 0x2000 (EIGHTBITALPHA) or source ignores alpha masks.
- Source: envmap mask only scales intensity (fixed sharpness, no direct specular without phong); phong exponent sets size, mask*boost saturates early. Engine: RoughnessMaskOnlyScalesSpecular flag, ENVMAP_F0 = 1.0 scaled by envmaptint.
- Known gaps: envmap fade steeper than source (LDR vs HDR cubemap?), phong and envmap share one lobe (clearcoat idea).

**Why:** user wanted to compare perceived shininess against real source rather than guess.
**How to apply:** rerun the grid after touching material.lua specular mapping; ignore what the reflection shows, compare strength/sharpness.

## Threaded codecs

*thread_pool job contract, unsafe cdata Buffer, where map load time went (144.8 -> 37.1 s)*

`goluwa/thread_pool.lua` runs a multiline Lua source string as a job on up to 8 persistent worker states (`r_codec_threads` pvar, 0 = inline, default min(8, cores-1)). `thread_pool.Run(source, input, size)` returns a job, `job:Await()` gives `meta, blob`. Jobs return `meta` (plain table) plus an optional blob (string or `uint8_t[?]`) carried as raw bytes after the encoded table. Inputs under `thread_pool.inline_threshold` (16384) run inline. `_G.thread_pool_job` is set inside jobs so nested Run stays inline. Codecs export `thread_job`, `ThreadCost(str)`; `codec.DecodeFileAsync` uses them (texture.lua, audio/sound.lua).

**Why:** string.buffer serializes strings/numbers/plain tables/int64 only, not cdata arrays/structs (Vec3 and Color are cdata). The model and map decoders (`codecs/mdl,vvd,vtx,phy,bsp`) therefore return plain tables + offsets into one blob, and the loaders (`mdl.lua`, `bsp.lua`) convert at the boundary (`convert_bsp_types` in `source_engine/bsp.lua`, `convex_hull.FromPlain`, lazy `Polygon3D:GetVertices` for `keep_packed` meshes).

**How to apply:**
- `structs/buffer.lua` Buffer reads are not bounds checked (truncated data segfaults) and PushPosition/PopPosition do not work on it (bool stack). Codecs read strings through `ffi.cast` with checked offsets instead. ReadStructure only exists on vfs file objects.
- Test files run inside worker threads (`_WORKER_THREAD`), tests in one file can run as concurrent tasks, so tests that change `r_codec_threads` run their scenarios sequentially in one T.Test.
- Load profile (gm_construct_m3_401, 144.8 s -> 37.1 s): convex hull build for .phy was 42% (now in the mdl job), vpk `ReadBytes` per-byte loop for preloaded entries ~40% (fixed in generic_archive.lua), bsp parse was only 2.7 s of LoadMap's 18.7 s. What is left on the main thread is vfs path resolution (`vfs.TranslatePath` across ~20 mounts, `fs.get_attributes`) and `Material.FromVMT`.
- Old mdl tangents for meshes 2..N were derived from mesh 1's triangles (shared vertex tables + BuildTangents skipping vertices that have a tangent); the job now computes each mesh's own.
- Windows: `main_protected` in bindings/threads.lua holds a process wide mutex for the whole worker loop, so pool workers 2..N probably block. Not addressed (Linux only).

Related: [Perf measurement pitfalls](performance.md#measuring-correctly), [gm_construct_m3 profiling](performance.md#what-cost-what)

## Mounting games, listing maps, thumbnails

The `ENGINE > load` window (`goluwa/render2d/ui/load_window.lua`, program `Load` in `desktop.lua`, 3d only) mounts and unmounts games and loads maps. It only talks to `goluwa/engines.lua`: an engine registers `Find`, `Load` and optionally `GetGames` (`{id, name, image, mounted, mountable}`), `MountGame(id)`, `UnmountGame(id)`, `GetMaps` (`{name, game = id, mounted}`) and `GetMapThumbnail(map)` (a vfs path or nil). `engines.GetGames/GetMaps/GetMapThumbnail/MountGame/UnmountGame/LoadMap` aggregate them and the `map` command with no argument prints `engine:name` for `GetMaps`. It replaced `List`.

- **Which games mount:** `game.GetMountableGames()` is `steam.GetSourceGames()` minus Source 2 (`gameinfo.gi`: CS2, Alyx, Dota 2 mount fine but ship `.vpk` worlds, there is no loader) and minus anything without a `SteamAppId` (sourcemods, `FindSourceGame` and the mounted cache are keyed by it). A game is only found if steam has an `appmanifest_*.acf` for it, a leftover folder (the `Counter-Strike Global Offensive` folder on this machine has no manifest) is not. Several gameinfos with the same `SteamAppId` collapse to the first (L4D2's `left4dead2_dlc*` folders). Verified here: Garry's Mod (4000) and Dear Esther (203810), and Crysis (17300, no mounting, `cry_engine`). Every other Source 1 game goes through the same `gameinfo.txt` searchpath code but has never been run.
- **Mount cost here:** gmod with workshop and cache gmas 0.33 s, gmod with `skip_addons` 0.12 s, Dear Esther 2 ms. A mount is synchronous. Unmounted games are not free to list either: the compromise is `game.ListLooseMaps`, a `maps/*.bsp` scan of the game's non vpk, non wildcard searchpaths (gmod: 3 maps, Dear Esther: 4). Maps packed in vpks, addons and workshop gmas only show up once mounted (`game.GetMaps` merges `vfs.Find("maps/%.bsp$")` and assigns an owner by path prefix of `vdf_directory`, then the searchpaths and the workshop content folder).
- **Loading a map of an unmounted game:** `game.EnsureMounted` still uses the `map_games` name patterns, and falls back to the loose map index (`get_map_owner`) so any listed map mounts its own game first.
- **Thumbnails:** `game.GetMapThumbnail` looks for `maps/thumb/<map>.png` (gmod) and `materials/vgui/maps/menu_thumb_<map>.vtf` (hl2, css, tf2). An unmounted game is searched in its loose folders only, so gmod shows none until it is mounted (they sit in `garrysmod_dir.vpk`), the window then draws the dimmed game art instead. Crysis uses `LevelStart.bmp` of the level (256x144, hence `codecs/bmp.lua`) or the `*_Loading.dds`. Game art is `steam.GetGameImage(appid, "header" | "portrait" | "hero" | "logo")`, the steam client's `appcache/librarycache/<appid>/` (newer clients use a hash named subfolder, both are searched, nil when the client never downloaded it).
- **Orientation:** the png and bmp decoders write the bottom row first, jpg, dds and vtf the top row, `render2d.DrawTextureCover(..., flip_y)` takes that as a parameter and `load_window.lua` keys it on the file extension.
