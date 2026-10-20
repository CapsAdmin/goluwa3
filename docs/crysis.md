# Crysis levels

Notes collected from past sessions. Dated numbers are snapshots; re-measure before relying on them.

## Crysis ATI2 normal channels

*ATI2 halves swapped in dds.lua; Cry normals no longer negate XY*

Crysis `_ddn.dds` normal maps use FourCC `ATI2` (3Dc), which stores Y in the first 8 bytes of each block and X in the second, the reverse of BC5. As of 2026-09-26, `goluwa/codecs/dds.lua` swaps the halves for ATI2 (not DX10/BC5U). After that, Crysis maps follow our TBN convention exactly (X→+u, Y→+v, V pointing down), so `ReverseXZNormalMap` is no longer set for Cry MTLs.

**Why:** a correlation between the normal XY and the diffuse brightness gradient showed R following the v slope and G following u. The old "negate XY" was a guess that covered for the swap.

**How to apply:** if Crysis or other ATI2 normals look wrong, rerun that correlation (decode a `_ddn.dds` and correlate normal XY with the diffuse brightness gradient) before adding flips. 

## Crysis materials map to roughness and metallic

*Shininess is a phong lobe, Specular color x gloss mask is its strength; no spec/gloss path in the pipeline*

As of 2026-10-12 `mtl_material.lua` converts Cry MTLs the way `vmt_material.lua` converts Source, at load time. The pipeline no longer has a specular texture, `GlossIsShininess` or `SpecularSolvesMetallic` (the old per-pixel spec/gloss solve looked bad and is gone).
- **Cry shading** (Shaders.pak fragLib.cfi/Illum.cfx): `specular = lights * phong(Shininess) * glossMap.rgb * MatSpecColor`. The gloss map is the diffuse alpha (GLOSS_DIFFUSEALPHA, wins) or the `Specular` texture (GLOSS_MAP); it scales strength, not power.
- **Roughness:** lobe = `(2/(n+2))^0.25` (min 0.12), blended toward 1 for a weak specular color (`smoothstep(0, 0.3, lum)`). A gloss mask becomes `RoughnessMin = 1`, `RoughnessMax = lobe` (diffuse alpha through `AlbedoTextureAlphaIsRoughness`, the Specular map as a linear `RoughnessTexture`). Black Specular color sets `SpecularMultiplier = 0`.
- **Metallic:** only the Metal shader or a `metal` SurfaceType, and only where specular color x map is above ~0.4 (full at 0.7), via `MetallicFromRoughnessMask` plus `MetallicMaskMin/Max` (`0.4/lum`, `0.7/lum`; default 0..1 is the identity so Source is unaffected). Dielectric spec maps sit at 0.25-0.3 even with a Specular color of 1 (a painted locker's map is flat 0.29), so a linear mask or the color alone made painted metal look bare.
- Not handled: SPECULARPOW_GLOSSALPHA (spec map alpha scales power, 25 materials), colored (gold, copper) specular tints, Illum/Metal environment maps.

**How to apply:** `luajit glw --3d --background --validate lua test/harnesses/cry_pbr/models.lua` renders one model per run (`ONLY=n TAG=x`); `test/harnesses/cry_pbr/models.sh TAG [indices]` runs the list with `[i/N]` progress and prints each material's roughness/metallic. A worktree of HEAD gives the before image.

## Crysis fog and sun

*mission TimeOfDay/Lighting, CE sun formula, fog *0.01 scale; SunVector is stale*

- Sun and fog live in level.editor_xml under Missions > Mission[Name=Current]: TimeOfDay (Time, Variable "Volumetric fog: Global density" Value) and Lighting (SunRotation = latitude, Longitude).
- Sun: CryEngine's CTimeOfDay formula, (0,1,0) * RotZ((t+12)/24*2pi) * RotX(pi/2 - lon) * RotY(-lat), then y/z swapped. Lighting.SunVector does NOT match it (stale editor lightmap value), ignore it.
- Fog: CE3+ renderer does globalDensity *= 0.01 → extinction per meter at water level. Only CE3+ sources confirm that scale; for Quarry (0.2) it gives fog_density ~5.9, which looks right facing away from the sun but washes out toward it (our fog uses a forward-peaked HG phase, cry uses a flat fog color).
- `cry_engine/level.lua` computes `sun_direction`/`fog_density` from the mission; `cry_engine/scene.lua` hands them to the `atmosphere_controller` as `SunRotation` (quaternion from the direction) and `GroundFogVisibility = -ln(0.02) / (fog_density * 0.0025)` (Koschmieder at sea level). The shipped scale is 0.0025 (four times less fog than the CE3 0.01 factor above), changed in commit f802e26f 2026-09-27 ("fix some issues with atmospheric fog"); the CE3 factor is the reference, not what we use. Cry's lat/lon are not Earth coordinates, so the weather latitude/date system is bypassed.
- Rayleigh/Mie air now lives in the froxel volume with the fog (see [Air and fog share the froxel volume](render3d-lighting.md#air-and-fog-share-the-froxel-volume)); without it distant fog looked white.

**Why:** found by reading CryEngine source via gh api (MergHQ/CRYENGINE D3DHWShader.cpp sGetVolumetricFogParams, TimeOfDay.cpp) and Shaders.pak VolumetricFog.cfi.
**How to apply:** don't re-derive these; if fog looks wrong in Crysis levels, suspect the density scale first. Related: [Crysis vegetation painting](#crysis-vegetation-painting).

## Crysis terrain colour encoding

*cover.ctc is chromaticity+brightness, detail additive; read Shaders.pak CryFX first*

As of 2026-09-26, `goluwa/cry_engine/level.lua` builds the terrain colour atlas from `level.pak/terrain/cover.ctc`, a quadtree of DXT5 256² sectors (see `level.ParseCoverData`).
- **Colour encoding (layer 0):** decoded as in CryEngine's `tex2DTerrain` (Common.cfi): R and G are chromaticity, B is brightness; `r = (R + 0.001012) * 31/30`, `b = 1 - r - G`, and the result is multiplied by `3 * B`. Alpha is baked sun shadow.
- **Layer 1** is the terrain normal map, stored in its B and R channels.
- **Detail blend** (Terrain.cfx): `max(0, base + (detail - 0.5) * DetailTextureStrength) * material Diffuse`, using the raw (UNORM) detail texels, added in gamma space (pow 1/2.2 on the base, 2.2 after). Adding in linear space leaves saturated red and purple specks where the result nears black. In our engine this is `TerrainLayerAdditiveDetail`.
- **Unused:** the header float (0.68) isn't used by the shader.

**Why:** reading the channels as RGB gave yellow cliffs, grey dry grass and oversaturated grass. Every earlier guess (sRGB vs linear, ×2 detail) was wrong. The shipped shader sources in `Game/Shaders.pak/Shaders/HWScripts/CryFX/*.cfx|cfi` settled it.

**How to apply:** for any Crysis rendering question, read the CryFX shaders first. The remaining look difference is lighting: Plantation's sun is (0.90,0.75,0.49)×2 and its ambient (0.96,0.87,0.72)×1.56, both warm, while our skylight is blue. Related: [Crysis ATI2 normal channels](#crysis-ati2-normal-channels)

## Crysis vegetation bending

*CE2 _DetailBending port, vertex color RGBA meaning, what's calibrated not sourced*

Vegetation vertex animation (model_pipeline.BuildVertexAnimationGlsl) is a port of CE2's `_DetailBending` from Shaders.pak ModificatorVT.cfi (extracted to tmp/cryshaders/).
- Vertex colors (CGF stream 3, RGBA bytes, verified on palms): R = leaf edge flutter, G = branch phase, B = branch stiffness (1 = rigid, bend = 1-B), A = ambient occlusion. The old code read R/A as masks and animated trunks.
- Detail bending only when Vegetation GenMask DETAIL_BENDING (0x10000) and LEAVES (0x100) or GRASS (0x2000). Main bending applies to every object whose level vegetation group Bending != 0 (a float, applied to its materials in `cry_engine/terrain.lua`). It rotates vertices around the origin keeping length, which is what stops palm trunks from stretching.
- The CPU side is Lumberyard's (`tmp/cryshaders/3dEngine.cpp` around `fBEND_RESPONSE`, `LY_D3DHWShader.cpp` `SBending::GetShaderConstants`): the bend vector is wind (m/s) * 0.25 softly clamped to 2 (`v * 2 / (2 + |v|)`), and the detail bending's `fSpeed` (`BendInfo.w`) is 0.3 of its length, so 0.21 in a gentle breeze and never 0.6. The engine passed `wind * 0.25` straight in as the detail speed (3-4 times too strong in a breeze, unbounded in a storm), and the shader multiplies the wave's input by speed * frequency, which past 0.5 makes the wave faster instead of wider: crysis' fronds and leaves bobbed and buzzed (2026-10-16). Now `BendSpeed` is the 0.3 of a soft clamp of 6 (near Lumberyard's in a breeze, still growing in a storm), the detail waves are a fixed shape whose amplitude is that strength (crysis' below 0.5, the square root above it) and the detail clock (`atmosphere.GetWindDetailTime`) runs faster in a strong wind instead. The main bending's soft clamp is a curve of the speed in m/s instead (`MAX_BENDING` 7, `BENDING_SPEED` 22, less clamped at the user's ask). BEND_PER_HEIGHT = 0.25 and bend z = 1/model height are my calibration. Gusts are applied along/across the wind instead of CE2's object axes.
- Deliberate differences from the shipped `_DetailBending`: it uses `TriangleWave` (not smoothed, despite GPU Gems 3 chapter 16 showing `SmoothTriangleWave`), which looked linear, the engine smooths it. The edge flutter goes along `vNormal.xy` with a wave that is never negative, so every card was pushed towards whichever side its normal was on (the user saw it as moving in local space); here the wave is centered and the part of the normal that faces the wind adds a push downwind. Flutter along the wind instead (tried 2026-10-16) slid cards within themselves and, with `bendDetailPhase` 100 (vertices a centimeter apart in unrelated phases), tore crysis' leaf cards. Branches are also pushed downwind, crysis only moves them up and down.
- A cgf without a color stream (the twisted trees) was given 0 for every channel, which reads as flexible everywhere: the whole canopy bobbed up and down off its branches. `cgf.lua` gives it r 0, g 0, b 1, a 1 now (held still, only the main bending).
- `test/harnesses/wind/cry_colors.lua` prints the color channels of crysis models per part (min, max, mean, correlation with height and reach), `test/harnesses/wind/cry_mtl.lua` their bending params, `test/harnesses/wind/cry_stretch.lua` the stretch of their leaf cards under the old and new detail bending, `test/harnesses/wind/calibrate.lua` (`M=2` for lumberyard's clamp) what each beaufort force does to them and to the foliage.
- Polygon3D.BendHeight is the whole cgf's max height, shared by all submeshes so trunk and leaves bend together.

**Why:** user reported wrong trunks animating and palm trunks scaling; asked for a CE2-based rewrite (2026-09-27).
**How to apply:** tune BEND_PER_HEIGHT for main sway strength before touching the shader. Related: [Crysis vegetation painting](#crysis-vegetation-painting).

## Crysis vegetation painting

*19-byte instances, fit-to-terrain shear, grass blends to terrain color*

Crysis grass is painted vegetation (cgf grass patches), scatter is off on cry terrain (layers get scatter = 0).

- Painted vegetation is drawn by the scatter system as placed instances (one `scatter_placements` entity for each prototype, see [Placed instances](scatter.md#placed-instances)), not an entity for each instance (113k on Beach, 80% of its load: tasks went idle at 63 s, now 16 s, the frame from 25 ms to 14 ms on `glw` bench, the gbuffer from 6.4 to 0.7 ms and the shadow maps from 6.2 to 1 ms). The fit-to-terrain shear below is `Conform` now, a ray measurement of the ground under the base of each instance, and an `AlignToTerrain` prototype stands on the terrain normal (the up axis in its record). Only LOD 0 of a model is drawn, with the billboard from 42 radii (`BillboardRadii` 56 at the default `r_scatter_billboard_distance` of 0.75).
- `vegetationinstancesarray.editor_data` is packed 19 byte records: f32 x,y,z, f32 scale, u8 prototype id, u8 brightness, u8 angle (0-255 around cry +z). An old 76 byte stride loaded 1/4 of instances with garbage yaw.
- Grass sits on slopes through the Vegetation shader's "Fit to Terrain" GenMask 0x4000 (TERRAINHEIGHTADAPTION), not AlignToTerrain: vertices get z += quadratic fit of terrain height, blades stay upright. We do it with scatter `Conform` (the base follows the ground measured under four points of the footprint, see scatter.md), the CPU shear of the instance matrix is gone.
- UseTerrainColor + GRASS material: final = lerp(terrain color, grass, 1 - blendWithTerrainAmount) (default 0.5, often 0.7). Implemented as Material GroundColorTexture/Blend/UV sampling the cover.ctc atlas; not applied in GI/RT hit shading. Other UseTerrainColor vegetation (trees) gets the same blend at a fixed 0.5 (`terrain.ApplyVegetationMaterialState`); cry's Vegetation.cfx fades it with distance (`0.5 + renderQuality * 0.5` weight on the object's own color) but in practice it looked the same near and far, so there is no distance term. Cry blends the final lit colors, we blend albedo. Without it our trees were about twice as bright as the terrain next to them (cry: terrain ~1.8x the trees), it made a big difference.

**Why:** these were found by reading Shaders.pak (Vegetation.cfx, ModificatorVT.cfi) and the binary data, not obvious from the editor xml.

**Comparing terrain color with cry:** the RENDER VIEWS window with "Terrain base only" on and the albedo sheet (albedo with the terrain layers left out) and cry's `e_sketch_mode` agree on the albedo. Sketch mode is albedo times the time of day's `Sky color` (sRGB-encoded, decode it) times `Sky color multiplier` times ~0.885, checked on a white surface in IA/Quarry at 15.5 h: (0.366, 0.556, 0.676) x 0.885 against a measured (0.328, 0.491, 0.597), the ratio being the same on all three channels. That is why the sketch view is blue and why changing the time of day changes it. The grading variables (`Color: saturation/contrast/brightness`, `Levels`) are neutral in Quarry, there is no hidden tonemap. `level.lua` only reads the sun direction and the fog density from the time of day, never the ambient or sun color, so our lit scene is lit by our own sky.
**How to apply:** check CryFX shader flags before guessing at vegetation behaviour. Related: [Crysis terrain colour encoding](#crysis-terrain-colour-encoding).

## Crysis water shaders

*what Shaders.pak CryFX water does; our caustics now Newton-inverted*

Shaders.pak (python zipfile, no unzip on this box) holds CryFX/CommonCausticsPass.cfi, Water.cfx, WaterOcean.cfx, WaterVolume.cfx; textures Defaults/caustics_sampler.dds (128², analytic diamond lattice 1-(|a|+|b|)/2), oceanwaves_ddn.dds (ATI2), water_foam*.dds, water_gloss.dds are in Textures.pak.

- **Caustics:** sun refracted through two scrolling normal-map layers, looked up in the lattice, ^16, with dispersion by offsetting R/G/B refraction vectors. Crisp web lines, not physical.
- **Waves:** 4 sine vertex waves + 4 normal-map layers (two counter-scrolling pairs, low and high frequency), bump clamped to 0.15; optional FFT displacement (Phillips). Screen-space refraction with 1.15/1/0.85 offset chromatic dispersion; foam from two foam textures + gloss mask.
- **What we did:** get_caustic in passes/ocean.lua inverts the landing map x + s*slope(x) with Newton steps, and sums 1/|jacobian| there, giving crisp filaments physically. Waves not changed yet.

Related: [Water rendering](render3d-lighting.md#water-rendering), [Crysis terrain colour encoding](#crysis-terrain-colour-encoding)

## Crysis performance

*terrain bakes async, removal scans from the back, multi-draw gbuffer; capture 30 s after settle or vegetation looks missing*

The Beach level has ~30.9k visuals and flying streams terrain tiles, so a visual is added/removed/hidden nearly every frame. What made it workable (2026-09-26): gpu_culling and the visual scene acceleration are incremental; scene_bvh builds are incremental with a 4 ms per-frame budget (one terrain tile of ~8.7k triangles costs ~5 ms of SAH); terrain chunk bakes are batched into one command buffer with one fence (they used to do ~9 `SubmitAndWait` each, every one waiting behind the frame in flight); removing an object scans `Instances`/`Children` from the back, because streamed objects are recent (a front scan over 30-60k entries cost ~5 ms per tile). The gbuffer draws all GPU-culled batches with two `vkCmdDrawIndirect` calls (`gbuffer_multi_draw`, per-batch PBR records, vertex pulling), which took batch CPU from 10 to 1.3 ms and made the level GPU bound at ~40 fps (ddgi_shade ~6.5 ms); `gbuffer_instanced` stays as the CPU fallback. Remaining: the Lua heap sits at 8-10 GB and grows 50 MB/s idle and 150 MB/s flying, so GC is a suspect. See performance.md for the measurement pitfalls.

**Measuring:** the "settled" heuristic (60 frames < 100 ms) fires before vegetation finishes spawning, and a faster build settles earlier, so bushes look "missing". Wait ~30 s after settle before comparing. Mountain tree density and vegetation LOD also vary per run, capture twice before calling a diff a regression. `glw bench crysis_beach` is the maintained benchmark.

**Beach load stalls (2026-10-19):** the map used to hang for tens of seconds with 3-25 s frames after most of it had appeared. Causes, biggest first:
- `timer.lua` measured the thinker budget with `system.GetTimeNS() / 1e9`, a `uint64` division that returns whole seconds, so no task thinker ever used up its 1/30 s budget and every running task got a full pass per frame (`tonumber` first). Check any `GetTimeNS()` arithmetic the same way. The fps thinkers also share one budget per frame now, and `tasks.Update` shares one for the first slices of the tasks it starts.
- `BatchTable` threw all records away whenever its capacity grew (1.5x steps, ~230k-390k rows on Beach, one row per vegetation instance), and wrote a record per row for 4-5 scene tables. Growth keeps the records, and `shared_records` (the gbuffer/translucent tables) copies the record of an earlier row with the same mesh, material and first polygon. Scene rows keep a change log (`draw.lua`), so a table only looks at the rows that changed unless a buffer with an address was freed, and that scan asks each mesh for its addresses once.
- `utility.CreateLoadCache(cache, budget)` queues the callbacks of everything waiting on a model and runs them within `budget` seconds per frame (model_loader uses 4 ms): the coral rocks (`underwater_plants`) had hundreds of instances that all built their primitive entities in one 1-1.8 s slice.
Measure with a script that prints frames over 150 ms; the load now stays at 150-300 ms frames (real work) with an occasional 0.5 s hit when the row tables grow, instead of multi-second frames that never settled.

## Quarry test camera

*objects at ~(1414,178,-1158); default camera is at origin far away*

`map IA/Quarry` (the `map` command picks the engine, prefix with `cry:` if a name exists in both) spawns the camera at (0,0,0), near the edge. The objects sit around (1414, 178, -1158). The median of 4400 objects is x 1226..1686, y 154..240, z -1292..-1034.

- Overview: `--pos 1380,215,-1080 --ang -20,-10,0 --fov 70`
- Ground level by a warehouse: `--pos 1395,170,-1105 --ang -5,-20,0 --fov 70`
- Load it from a shot setup file with `import("goluwa/cli/commands.lua").RunString("map IA/Quarry")`. `--settle 15` is enough for the vegetation to show.


