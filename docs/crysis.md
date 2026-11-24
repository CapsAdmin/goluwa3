# Crysis levels

Crysis content is loaded by the `addons/crysis_loader` addon: `lua/crysis_loader/` (`level.lua`, `scene.lua`, `terrain.lua`, `water.lua`, `mtl_material.lua`, `cgf.lua`, `units.lua`, `game.lua`, `compiled_terrain.lua`, `compiled_vegetation.lua`, `brush_list.lua`, `cry_pak.lua`), the physics codec in `lua/codecs/cry_physics.lua`, the `cry_level` component in `lua/components/`, and tests in `addons/crysis_loader/tests/`. Load a level with the `map` command (`map IA/Quarry`).

Where behavior must match CryEngine, read the shipped CryFX shader sources in `Game/Shaders.pak` (`Shaders/HWScripts/CryFX/*.cfx|cfi`, a zip) before guessing at an encoding or formula. For renderer behaviour not in the shaders (for example volumetric fog parameters), the renderer DLL is the reference.

## Games and level formats

- `game.lua` knows Crysis, Crysis Wars and Crysis Warhead (`GAMES`: paks to mount, patch paks first because the VFS takes the first mount that has a file). One game is mounted at a time; loading a level mounts the game that owns it. Choose explicitly with `map cry:wars:IA/Quarry` (`crysis:`, `wars:`, `warhead:`).
- Warhead's retail `level.pak` entries use an encrypted zip method; `cry_pak.lua` decrypts them through the `ZipDecrypt` event so the zip codec can read them.
- Levels with `.cry` editor data are read from it. Levels without it ("compiled" levels: Warhead's, and Crysis's Armada) read objects from `mission_mission0.xml`, brushes from `brush.lst` (`brush_list.lua`), terrain from `terrain/heightmap.dat` (`compiled_terrain.lua`) and vegetation from the same file (`compiled_vegetation.lua`). Read those modules for the binary layouts.
- In compiled heightmaps the low 4 bits of every height sample are the surface type index of that sample; the loader masks them out of the height and builds the surface index map from them.
- Warhead stores the terrain colour as plain RGB where Crysis and Wars store chromaticity plus brightness (`plain_terrain_color` in `game.lua`).
- Textures and materials fall back to the merged mounted tree, because a model in one pak can reference a material in another.
- `HIDDEN_MODELS` in `level.lua` drops specific models that break lighting.

## Units and placement

- A Cry unit is a meter; the loader does not scale content. Players in Crysis levels are scaled to the levels' person size instead (`sv_cry_player_scale`).
- The world is curved (see [render3d-lighting.md](render3d-lighting.md), Planet) but Cry levels are authored flat. Every Cry world position goes through `units.PositionToEngine`, which lowers it by `planet.GetDrop`; `units.ToEngine` is for directions and model local data only. Using `ToEngine` for a position floats it above the terrain.
- Cry heightmap sample `i` sits at `i * HeightmapUnitSize` (the last sample is one unit short of the world size). The sampler and the rendered terrain use that convention; a `(width - 1) / world_size` scale misplaces things on large maps.

## Materials and textures

- `_ddn.dds` normal maps are ATI2 (3Dc), which stores Y in the first half of each block and X in the second, the reverse of BC5. `dds.lua` swaps the halves for ATI2, after which Cry normals follow the engine's TBN convention with no extra flips. If normals look wrong, correlate normal XY with the diffuse brightness gradient before adding flips.
- `mtl_material.lua` converts Cry MTLs to roughness/metallic at load time, like `vmt_material.lua` does for Source. Cry specular is a Phong lobe; roughness comes from the lobe and gloss masks. The `Metal` shader does not mean metallic: it still lights the diffuse fully and Crysis uses it for painted and rusty sheet metal, so metallic is derived from the specular strength and `FresnelBias`, not from the shader name. A zero Cry specular colour only means no Phong highlight; materials keep a dielectric F0.
- Cry materials request material baking for roughness only (see [material-baking.md](material-baking.md)).
- Terrain colour (`level.ParseCoverData` of `terrain/cover.ctc`) is decoded as in CryEngine's `tex2DTerrain`. The detail layers are added in gamma space (`TerrainLayerAdditiveDetail`), fade out with distance as in `Terrain.cfx` (`fade_distance`, plus `fade_distance_xy` for triplanar cliff materials), and are composited as successive passes in surface type order (`layer_blend = "passes"`), as CryEngine draws them; a plain weighted blend of the per-vertex weights averages the cells into flat ground.
- UseTerrainColor grass blends its albedo toward the terrain colour (`GroundColorTexture`, `terrain.ApplyVegetationMaterialState`), as `Vegetation.cfx` does for grass. CryEngine's distance-only terrain colour fade for other vegetation is a far-LOD trick and is not reproduced.

## Lights

`Light`, `SimpleLight` and `SimpleIndirectLight` entities (`level.ExtractLight`) become `light_point`, or `light_spot` with a projector texture (`scene.lua`); inactive ones are skipped. A Cry light's multiplier and radius are converted to lumens through `CRY_LIGHT_LUX_PER_UNIT`; this calibration is by eye, not measured against CryEngine. Some multiplayer maps have no lights and rely on emissive materials.

## Sun, fog, water

- Sun and fog come from the mission data (TimeOfDay and Lighting, under the current mission; `ParseMissionEnvironment` is shared by editor and compiled levels). The sun uses CryEngine's time of day formula; the `Lighting.SunVector` attribute is stale and ignored.
- Fog follows CryEngine's renderer: a plain exponential height fog anchored at the water level, with a scale height derived from the level's atmosphere height. `scene.lua` maps it onto the `atmosphere_controller`'s ground fog. A `WaterLevel` of -1000000 means no ocean (anchor at 0). The extinction is a deliberate fraction of CryEngine's value, matched against reference screenshots; see `scene.lua`.
- Not mapped on purpose: sun/sky colour multipliers, fog colour, sky model knobs and the skybox (artistic; the engine's sky and exposure are physical).
- Ocean settings come from the mission's Environment > Ocean/OceanAnimation. CryEngine's waves travel against `OceanAnimation.WindDirection`, the engine's `WindDirection` is where waves go, so the loader negates it; at runtime the ocean follows the level wind (`EnvState.WindVector`, the climate wind). The ocean medium is built in `water.lua` (`GetOceanMedium`, `media.MediumFromColor`); water volumes and rivers use `media.MediumFromFog`.
- Judge water colour only after matching exposure on a bright reference (sand) in the same shot; at grazing angles the colour is mostly reflection.
- Cry's water shaders use non physical caustics and normal-map waves; the engine's ocean has its own (see [render3d-lighting.md](render3d-lighting.md)).

## Ice

Warhead's ice shaders map to the engine's `medium` feature (the `ice` preset, see [render3d-pipeline.md](render3d-pipeline.md)). Only the shader name is used; colours come from the medium preset. The ice terrain layer gets its medium through `cry_medium_density`.

## Vegetation

- Leaf back lighting follows `Vegetation.cfx`/`shadeLib.cfi`: the loader turns `BackDiffuse * BackDiffuseMultiplier / Diffuse` and the opacity map into `DiffuseTransmission`, its tint and `TransmissionTexture`.
- Vertex colours (CGF stream 3) are R edge flutter, G branch phase, B stiffness (1 rigid), A ambient occlusion. A cgf without a colour stream is given "held still" values, since zeros read as fully flexible. `BendHeight` is shared by all submeshes of a cgf so trunk and leaves bend together.
- Bending (`deformation.lua`) is based on CE2's `_DetailBending` with deliberate differences; see [foliage.md](foliage.md) for the shared wind rules. Tune `BEND_PER_HEIGHT` before touching the shader.
- Painted vegetation is drawn by scatter as placed instances, one `scatter_placements` entity per prototype, never one entity per instance (see [scatter.md](scatter.md)). "Fit to Terrain" is scatter `conform`. Procedural scatter is off on Cry terrain layers.

## Characters

- `.chr` files are skinned cgf chunk files (`chr.lua`, decoder `model_decoders/chr.lua`): `CompiledBones` (0xACDC0000) holds the skeleton (bone to world 3x4, relative parent offsets, controller id = CRC32 of the case sensitive bone name), `CompiledIntSkinVertices` plus `CompiledExt2IntMap` give four global bone ids and float weights per mesh vertex. The mesh's bone mapping stream uses per subset bone lists; it is not read.
- The stored world to bone matrix is stale in some models (turtle); the inverse bind is derived from bone to world.
- `.cdf` character definitions (`chr.DecodeDefinition`, decoder `model_decoders/cdf.lua`) name a `.chr` and optionally a material for all of it; attachments are not loaded.
- Animations are `.caf` files listed in the model's `.cal` (`name = file`, relative to `#filepath`, which is game root relative); each becomes a clip of that name. Controllers 0x827 store centimeters and the log of the inverse local rotation; `caf.lua` bakes them to frames at the timing chunk's rate. `.lmg`, `.dba` (the shark) and `Animations.pak` are not supported.

## Sounds

- `Sounds.pak` (`Warhead_Sounds.pak`) holds FSB banks (see [audio.md](audio.md), Decoding) and the FMOD Designer projects (`.fdp`, XML) that name the sounds. `fmod_events.Get("Sounds/environment:random_oneshots_natural:chicken_cluck")` (project dir, then event groups and the event) parses the project once and returns the event's bank sample paths, volume and pitch (octaves). The binary `.fev` is not read.
- An event's layers name sound definitions, whose waveforms name a bank and a file; only the file's base name is in the bank. Dialog events mostly do not resolve (localized and programmer sounds).

## Ambience

- `AmbientVolume` (a loop) and `RandomSoundVolume` (one-shots every `MinWaitTime` to `MaxWaitTime` seconds, `DiscRadius` from the listener or at the entity) become `cry_ambience` entities under the level's `Ambience` folder (`ambience.lua`). Gameplay triggered sounds, music and reverb volumes are not loaded.
- A volume plays from the areas that link to it (`AreaShape` prism, `AreaBox`, `AreaSphere`; `level.ExtractEntity` reads them from editor layers and compiled missions). An area shape of height 0 is unbounded vertically. Loops play non-spatially at full level inside and fade over `OuterRadius` outside; one-shots only fire inside. Areas of one group are exclusive: of those containing the listener, only the highest priority ones count, so an indoor ambience silences the outdoor one around it.
- Sound layers are usually hidden in the editor but still play in game, so the loader keeps these classes from hidden layers.
- Events are evaluated with `fmod_events.Evaluate`: a layer plays the sounds whose range on its control parameter contains the value, scaled by its volume envelopes. `battle` is 0 and `daylight` follows the sun; `distance` envelopes are left to the engine's attenuation.
- Levels: an event at 0 dB is `cry_ambience.LoopLevel` dB SPL (loudness normalized), one-shots `OneShotLevel` at 1 m. Crysis mixes ambience events 25 to 40 dB down.

## Entities

Entities without geometry that the loader does not handle itself (`level.ExtractEntity`, with archetype properties merged under the instance's) are offered to addons through `event.Call("CryEntity", {class, name, world_matrix, properties})`; a listener returns a component table and the entity is added under the level's `Entities` folder (the `boids` addon claims the boid classes: `Chickens`, `Turtles`, `Crabs`, `Plover`, `Frogs`, `Birds`, `Fish`).

## Collision

- Collision comes from the cgf physics chunk of slot 0 (`cry_physics.lua`); slots 1 and 2 are not solid. Models with no slot 0 have no collision in Cry either.
- Brushes are static bodies; entities and archetypes are static or dynamic from their `Physics` properties. Painted vegetation with physics (`cgf.HasPhysics`) gets one static body per instance under `Vegetation Physics`.

## Big levels

Big levels have tens of thousands of visuals while terrain streams, so a visual is added, removed or hidden nearly every frame:

- Scene updates must be incremental; terrain chunk bakes are batched into one command buffer with one fence; removals scan from the back, because streamed objects are recent.
- `system.GetTimeNS()` returns `uint64`: `tonumber` it before dividing, or the result is whole seconds and budgets never run out.
- Queue model-load callbacks through `utility.CreateLoadCache(cache, budget)` so many instances do not build their primitives in one frame.
- Measure with `glw bench crysis_beach` (`test/benchmarks/crysis_beach.lua`); let vegetation settle after the load and capture twice before calling something a regression. See [performance.md](performance.md).

On Quarry the objects sit around (1414, 178, -1158), far from the default camera at the origin; check the scene's saved views (see [screenshots-and-cameras.md](screenshots-and-cameras.md)).
