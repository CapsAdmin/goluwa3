# Animation and Source engine content

## Skeletal animation

Format-neutral: an `animator` component (`goluwa/entities/components/animator.lua`) plus `goluwa/render3d/skeleton.lua`. Model decoders return a skeleton through the 5th `skeleton_callback`; Visual stores it as `visual.Skeleton`. A skeleton is an engine-space bind pose, inverse bind and clips with `clip:Sample(cycle, params, out)`; a new format only has to produce that.

- Skinning runs on the GPU (`render3d/skinning.lua`, one dispatch for all rigs, takes rigs, not animators). The animator clones each skinned primitive's mesh (`Polygon3D:CloneDynamic`) and skinning rewrites it, keeping the previous positions for motion vectors.
- Components never touch ffi or GPU buffers: `Skeleton:NewPose()` gives an opaque pose (`Reset/Copy/Sample/Blend`); `render3d/rig.lua` (`animator:GetRig()`) has `SetPose`, `SetBone(name, Matrix44, "local"|"model")`, `ClearBone(s)`, `GetBone`, flex accessors and `Update()`. Matrix44 has the translation in the last row, rig matrices are 3x4 with it in the last column.
- Animators update less often with camera distance (LOD in `animator.lua`), each with a random phase so updates spread across frames.
- Flexes: `skeleton.Flex` (a port of Valve's `RunFlexRules`) and per-model vertex deltas from the mdl; morphs run in the skinning shader. The `flex` and `bone_pose` components expose controller and bone values to the editor through `META:GetDynamicProperties()`; fire `objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})` when that list changes.
- Mix clips: `skeleton:AddMixClip{Name, Layers = {{Clip}, {Clip, Bones = {...}, Weight}, ...}}` registers a clip whose later layers replace the subtrees under `Bones`. All layers sample the same normalized cycle and pose parameters, and timing comes from the first layer, so layers should share the base's rhythm. It plays like any other clip. Building blocks: `CreateBoneMask`, `BlendPosesMasked`.
- Raycasts against animated meshes pose vertices on the CPU (`skinning.PosePositions` from the rig's skin matrices), since the skinned GPU buffer is not read back; morphs and posed normals are ignored there.
- Test3D files share a limited descriptor set budget, so flex and rig tests live in their own files (`test/tests/render3d/flex.lua`, `rig.lua`). Benchmark: `luajit glw bench gm_construct_animation` (`test/benchmarks/`). Overhead camera views need pitch -89, not exactly -90.
- Unsupported Source features include additive sequences, IK, root motion, events and per-sequence weightlists (use mix clips); check `animator.lua` and the decoders before assuming something exists.

### Source 1 models (`addons/source_loader/lua/model_decoders/mdl.lua`)

- Player models only contain `reference`; their animations come from `$includemodel` files and `.ani` animblocks. Missing includes are logged and skipped, leaving the model in bind pose.
- `mdl_decoder.AddAnimations(skeleton, donor_path, filter, check_bones)` registers a donor model's sequences on an existing skeleton by bone name, never overriding names, and refuses when the donor's bind pose differs on `check_bones`. `source_pose` (`addons/game/lua/components/source_pose.lua`) uses it to give gmod player models extra HL2 citizen sequences. Import the decoder lazily (it imports `model_loader`).
- Clip names are sequences, not the `@` animdescs. walk/run are blends over `move_x`/`move_y`; 0,0 is standing, so set `SetPoseParameterByName("move_x", 1)`.
- Setting a different Sequence resets time and crossfades; call `SetTime` after the switch resolved (next Update).
- `clip:GetGroundSpeed(params)` comes from the animdesc movement blocks, blended over pose parameters (see navigation-and-npcs.md).
- `vmt.Load` applies `">=dx90"`-style conditional blocks as on a modern card (`apply_dx_blocks` in `source_loader/vmt.lua`).
- Eyes: Source draws eyes as a flat quad ray cast onto a virtual sphere by its `Eyes` shader. The decoder instead replaces each eyeball mesh with skinned sclera and iris spheres on a virtual `eye_N` bone (`skeleton.Eyes`). Match eyeball meshes by position, not by the eyeball's texture field (always 0). The `eyes` component (`goluwa/entities/components/eyes.lua`) drives gaze (`LookTarget`, `LookYaw`/`LookPitch`, `AutoLook` with `eyes.AddTargetSource`, `eyes.GetTargetPosition`), blinking and eyelid flexes through `rig:SetEyeAngles`. Example: `addons/examples/lua/examples/render3d/source_eyes.lua`.
- Generated VTFs need flag 0x2000 (EIGHTBITALPHA) or Source ignores alpha masks. The png and bmp decoders write the bottom row first, jpg/dds/vtf the top row (see ui.md).

### Source 2 characters (`model_decoders/vmdl_c.lua`, `source_loader/source2/animation.lua`)

- The skeleton keeps the bones the skin needs plus their ancestors (`animation.GetKeptBones`). The skinning shader reads three weights per vertex, so the packer writes at most three influences. Source axes (`x, y, z` inches) map to engine `-y, z, -x` meters, as in Source 1.
- Cloth: `$`-prefixed bones are driven by the vphys finite element model (`animation.ReadCloth` into `skeleton.Cloth`), reparented to the bone they follow so they move rigidly without simulation. `render3d/cloth.lua` simulates them per rig (`Rig:SimulateCloth`, fixed step verlet with body capsule collision, run late so it sees the final entity matrix). Interpolate animated targets and colliders to each substep's time, or the cloth jitters with frame time. Nodes collide only with the body capsules.
- Clips are sequences with one non delta animation. Frames are decoded lazily from the `ANIM` block (`animation.NewDecoder`, `sample_clip` in `vmdl_c.lua`) with a small cache, since expanding them all costs hundreds of MB per character.

### Clip banks (glTF animation packs on Source rigs)

- The skinned glTF decoder (`addons/gltf_loader/lua/model_decoders/gltf.lua`) loads a skinned `.glb`/`.gltf` with its animations as clips under their original names (`animation_bank.AddNativeClips`), kept in glTF space.
- `animation_bank.FromGltf(path, fps, prefix)` (`goluwa/render3d/animation_bank.lua`) samples every clip to local position + quaternion per joint; `animation_bank.Convert` writes a `.clips` file next to the glb (`goluwa/codecs/clip_bank.lua`: a `string.buffer` meta plus raw float32 poses read in place). Rebake when the glb changes.
- `animation_bank.GetBanks()` finds every `animations/*.clips` in the vfs; `animation_retarget.AddBanks(skeleton)` (`goluwa/render3d/animation_retarget.lua`) registers them on a ValveBiped skeleton as `<prefix><lowercase name>`, baked lazily. The bone map is data (`animation_retarget.ValveBiped`); another rig only needs another map.
- Retargeting first aligns each target bone's rest direction to the source's rest pose (T-pose vs Source's arms-down reference), then applies each bone's model space rotation change. Forward is taken from the toe directions, never from the bind pose, because the Source reference pose does not face engine forward. Root translation is dropped, so root motion clips play in place.
- Clip redirects (`addons/game/lua/clip_redirect.lua`): `source_pose` and the air/land animations never name a pack. They call `clip_redirect.Resolve(kind, sequence, clips, context)`, which asks the `RedirectSourceClip` event for a redirect table (`Sequence`, `SpeedScale`, `MaxRate`, `Loop`, `StartTime`, `Hold`, ...; see the file). Listeners run every frame, so return existing tables. The animation pack addon that answers it (`addons/assets`) is local only and not in the repository.

## Source materials (`addons/source_loader/lua/source_loader/vmt_material.lua`)

- Texture overrides: `Material.RegisterTextureOverride(name, find)` lets an addon replace a vmt material's textures; `find(vmt_path, vmt)` returns nil or `{textures = {Albedo = path, ...}, properties = {...}}`. An override skips all Source texture convention conversion (envmap/phong to roughness, parallax, derived roughness) but keeps material semantics (alphatest, translucency, `$color`, surfaceprop, acoustics), so it must supply roughness itself. `vmt_material.ReloadAll()` re-queries overrides.
- Metal from `$surfaceprop`: a surfaceprop is a class vote (what the prop is made of), not its finish. With `$envmap` or `$phong` the vote counts as full metal; without them it is capped (`SURFACEPROP_METAL_VOTE`), since grey paint and grey steel cannot be told apart from albedo. `DerivedMetalAlbedo` gates metal per texel from albedo saturation and darkness at runtime (rust and paint are dielectric), and `DerivedSpecularRoughness` damps dielectric specular as roughness rises. Neither applies to authored PBR materials.
- Generated parallax height: bump maps listed in `NORMAL_PARALLAX` get a height map solved from the normals (`height_from_normals.Solve`) and low passed, since stepped parallax smears narrow grooves; fine cracks stay in the normal map. A bump map is a candidate when its solved relief is large relative to the tile (the artist drew height in the normal map). Judge candidates at a grazing view with parallax on and off. Do not weaken low frequencies of a normal map instead: that is an inverse unsharp mask and darkens both sides of every crevice.
- Self illumination: `$selfillummask` or the base alpha (`AlbedoAlphaIsEmissive`) becomes the emissive input, and `EmissiveMean` from the smallest mip (`vtf.GetMeanColor`) weights GI emitter sampling (see render3d-pipeline.md).

## Threaded codecs

`goluwa/thread_pool.lua` runs a Lua source string as a job on persistent worker states (pvar `r_codec_threads`, 0 = inline). `thread_pool.Run(source, input, size)` returns a job; `job:Await()` gives `meta, blob` (a plain table plus an optional string or `uint8_t[?]`). Small inputs run inline (`thread_pool.inline_threshold`), and nested `Run` inside a job stays inline. Codecs export `thread_job` and `ThreadCost(str)` for `codec.DecodeFileAsync`; model decoders use `model_loader.AddThreadedDecoder` (see performance.md).

- `string.buffer` serializes only strings, numbers, plain tables and int64, not cdata (Vec3, Color). Worker-side decoders (`addons/source_loader/lua/codecs/`) return plain tables plus offsets into one blob, and loaders convert at the boundary.
- `structs/buffer.lua` reads are not bounds checked: truncated data segfaults. Codecs read through `ffi.cast` with checked offsets.
- Workers have no vfs mounts: do vfs reads on the main thread.
- Test files run inside worker threads and tests in one file can run concurrently, so tests that change `r_codec_threads` run their scenarios sequentially in one `T.Test`.

## Mounting games, listing maps, thumbnails

`ENGINE > load` (`goluwa/render2d/ui/load_window.lua`) only talks to `goluwa/loaders.lua`. A loader registers `Find`, `Load` and optionally `GetGames`, `MountGame`, `UnmountGame`, `GetMaps` and `GetMapThumbnail`; `loaders.*` aggregates them.

- Source games (`addons/source_loader/lua/source_loader/game.lua`): `game.GetMountableGames()` comes from `steam.GetSourceGames()` (needs a steam `appmanifest_*.acf` and a `SteamAppId`). Mounting is synchronous. Unmounted games list only loose maps (`game.ListLooseMaps`); `game.EnsureMounted` mounts a map's game first. `game.GetMapThumbnail` and `steam.GetGameImage(appid, kind)` give art.

## Source 2 (Half-Life: Alyx)

Code lives in `addons/source_loader/lua/source_loader/source2/` plus the `vmdl_c`, `vmesh_c`, `vphys_c` model decoders and the `vtex_c`, `vsnd_c` codecs. `gameinfo.gi` games get `info.source2`. Maps are single `maps/<name>.vpk` files with embedded data (listed by `source2/world.lua`); `source_loader.Load` mounts the map vpk and `world.Translate` builds the scene. Sample: `luajit glw --3d --background --exit-on-error map a2_pistol`.

- Files are resources (`resource.lua`): a block table with binary or text KV3 (`kv3.lua`). Older resources use NTRO struct blocks, which only materials decode (`legacy_material.lua`).
- Meshes are meshopt compressed (`goluwa/codecs/meshopt.lua`); `vbib.lua` reads vertex buffers including the compressed normal formats. Index buffers must have their winding flipped or meshes render inside out. Occluder-only draw calls are skipped.
- Textures: `vtex_c.lua` (mips stored smallest first, optional LZ4). `g_tNormal` is hemi-octahedron encoded with roughness in blue, so `texture_convert.lua` converts once per texture on the GPU (`texture_compress.Recompress`) to a standard normal with roughness in alpha, cached in `storage/cache/source2_textures/` (keyed by path and the conversion shader). The first load of a map converts many textures; decoding is prefetched on `thread_pool` workers. Map loads run with tasks disabled because a task yield renders whole frames between conversions.
- Materials (`source2/material.lua`) follow the Alyx shaders; read them in the ValveResourceFormat renderer (`Renderer/Shaders/hlvr/`, `surface_generic_material.slang`, `surface_blend_2way.slang`) when mapping a parameter. Covered: metalness, tint masks (`BlendTintByBaseAlpha`, entity `rendercolor` as `Visual.Tint`), two way blends, uv transforms, detail textures, glass and liquid as refractive media, xen foliage as a translucent solid (`ApplyXenFoliage`), alpha test coverage from `g_flAntiAliasedEdgeStrength`, self illumination (an sRGB colour map, with `EmissiveMean`), and `F_SPECULAR`. Read `material.lua` for what each maps to and what is ignored.
- Colour textures are streamed (`render3d/texture_streaming.lua`, see performance.md).
- World: `world.vwrld_c` lists world nodes whose scene objects are models with 3x4 transforms. `_blocklight` objects (tools blocklight materials, hidden meshes plugging cracks where props pierce single sided walls) load `ViewHidden` so they still block shadows and GI rays; other `materials/tools/` materials are `NoDraw`.
- Collision is the map's `world_physics.vphys_c` (`vphys.lua`), chunked into several mesh shapes; its triangle winding is already outward, unlike the render meshes. Props get collision from their model's `PHYS` data. `prop_physics` and `func_physbox` are dynamic, `prop_dynamic` is static. Surface properties (`source2/surface_properties.lua`) give friction, elasticity and density; the engine has one material per body, so `vphys.GetBodyProperties` averages them.
- Entities come from `.vents_c` lumps with murmur2 hashed keys (`entity_lump.lua` knows a short key list; add names there). Translated: lights, `info_player_start`, hinge/slide/weld constraints as `map_constraint` entities (`goluwa/entities/components/map_constraint.lua`), and the 3D skybox (`world.FindSkybox`, placed like the Source 1 skybox). There is no entity logic (doors, triggers, relays), baked lighting or authored sky; problem models are skipped via `BLACKLISTED_MODELS` in `world.lua`.
