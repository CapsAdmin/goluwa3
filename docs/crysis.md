# Crysis levels

Crysis content is loaded by `goluwa/cry_engine/` (`level.lua`, `scene.lua`, `terrain.lua`, `water.lua`, `mtl_material.lua`, `units.lua`) with models from `goluwa/codecs`. Load levels with the `map` command (`map IA/Quarry`; prefix `cry:` if a name exists in several engines). Where behavior must match CryEngine, read the shipped CryFX shader sources in `Game/Shaders.pak` (`Shaders/HWScripts/CryFX/*.cfx|cfi`, readable with python zipfile) before guessing; every earlier guess about encodings in this area was wrong until the shaders were read.

## Materials and textures

- `_ddn.dds` normal maps are ATI2 (3Dc), which stores Y in the first half of each block and X in the second, the reverse of BC5. `dds.lua` swaps the halves for ATI2, after which Cry normals follow the engine's TBN convention with no extra flips. If normals look wrong, correlate normal XY with the diffuse brightness gradient before adding flips.
- `mtl_material.lua` converts Cry MTLs to roughness/metallic at load time like `vmt_material.lua` does for Source. Cry shininess is a phong lobe and specular color times the gloss map is its strength: roughness comes from the lobe (blended to 1 for weak specular), a gloss mask (diffuse alpha or the Specular texture) becomes `RoughnessMin/Max`, and metallic only comes from the Metal shader or `metal` surface types where specular strength is high (`MetallicFromRoughnessMask`, `MetallicMaskMin/Max`). Not handled: spec-map-alpha power, colored specular tints, Illum/Metal environment maps.
- Terrain color (`level.ParseCoverData` of `level.pak/terrain/cover.ctc`, a quadtree of DXT5 sectors): layer 0 is chromaticity (R, G) plus brightness (B), decoded as in CryEngine's `tex2DTerrain`; alpha is baked sun shadow; layer 1 is the terrain normal map. The detail texture is added in gamma space (adding in linear leaves saturated specks near black); that is `TerrainLayerAdditiveDetail`.
- UseTerrainColor vegetation blends albedo toward the terrain color (grass: `1 - blendWithTerrainAmount`; other vegetation a fixed 0.5 in `terrain.ApplyVegetationMaterialState`), via `GroundColorTexture`. Without it trees look about twice as bright as the terrain next to them. It is not applied in GI/ray hit shading.

## Sun, fog, water

- Sun and fog live in `level.editor_xml` under Missions > Mission[Name=Current]: TimeOfDay (time, "Volumetric fog: Global density") and Lighting (`SunRotation` is latitude, Longitude). The sun uses CryEngine's CTimeOfDay formula; `Lighting.SunVector` is stale, ignore it. `level.lua` computes `sun_direction` and `fog_density`; `scene.lua` hands them to the `atmosphere_controller` (`GroundFogVisibility = -ln(0.02) / (fog_density * 0.0025)`), bypassing the weather latitude/date system. If fog looks wrong in a Crysis level, suspect the density scale first. The level code never reads the time of day's ambient or sun color; the scene is lit by the engine's own sky.
- Ocean settings are Mission > Environment > Ocean/OceanAnimation; `WaterLevel` is mean sea level. `WaterVolume` is a polygon (min-area rectangle), `River` a Bezier spline cut into boxes of at most 16 m. Fog color for water comes through `water.MediumFromFog`.
- Cry's water shaders (CommonCausticsPass.cfi, Water.cfx, WaterOcean.cfx) use non physical caustics and normal-map waves; the engine's ocean does its own physically based version (see [render3d-lighting.md](render3d-lighting.md)).

## Vegetation

- Vertex colors (CGF stream 3, RGBA): R leaf edge flutter, G branch phase, B branch stiffness (1 rigid, bend = 1 - B), A ambient occlusion. A cgf without a color stream gets r 0, g 0, b 1, a 1 (held still), because zeros read as flexible everywhere. `Polygon3D.BendHeight` is the whole cgf's max height shared by all submeshes so trunk and leaves bend together.
- Vegetation animation (`model_pipeline.BuildVertexAnimationGlsl`) is based on CE2's `_DetailBending`. Detail bending applies only with the Vegetation GenMask DETAIL_BENDING plus LEAVES or GRASS; main bending applies to every object whose level vegetation group has `Bending != 0`, and rotates vertices about the origin keeping length (which keeps palm trunks from stretching). The CPU side follows Lumberyard: the bend vector is wind times 0.25 softly clamped, and the detail speed is 0.3 of its length; passing the raw wind as the detail speed makes leaves buzz because the wave input past 0.5 gets faster, not wider. Deliberate differences from CE2: the engine smooths the triangle wave, centers the flutter wave and pushes along the wind part of the normal, and pushes branches downwind. Tune `BEND_PER_HEIGHT` for sway strength before touching the shader. See [foliage.md](foliage.md) for the shared wind rules.
- Painted vegetation (`vegetationinstancesarray.editor_data`: 19 byte records of f32 x, y, z, f32 scale, u8 prototype id, u8 brightness, u8 angle) is drawn by scatter as placed instances, one `scatter_placements` entity per prototype (see [scatter.md](scatter.md)), never one entity per instance. "Fit to Terrain" (GenMask 0x4000) is scatter `Conform`; scatter is off on cry terrain (layers get `scatter = 0`). Only LOD 0 is drawn plus a billboard (`BillboardRadii`).

## Performance of big levels

Beach has ~30k visuals and flying streams terrain, so a visual is added, removed or hidden nearly every frame. Rules that keep it workable:

- Scene updates must be incremental; terrain chunk bakes are batched into one command buffer with one fence (never a `SubmitAndWait` per chunk); removing an object scans `Instances`/`Children` from the back, because streamed objects are recent.
- `system.GetTimeNS()` returns `uint64`; dividing it by `1e9` gives whole seconds. `tonumber` first. A budgeted thinker that never exhausts its budget runs every task fully every frame.
- Large `BatchTable` growth must keep its records; queue model-load callbacks through `utility.CreateLoadCache(cache, budget)` so hundreds of instances do not build their primitives in one slice.
- Measure with `glw bench crysis_beach` (`test/benchmarks/crysis_beach.lua`). Wait ~30 s after the load "settles" before judging vegetation, and capture twice before calling a difference a regression. Print frames over 150 ms to find load stalls. See [performance.md](performance.md) for measurement pitfalls.

## Quarry test camera

Objects sit around (1414, 178, -1158); the default camera at the origin is far away. Overview: `--pos 1380,215,-1080 --ang -20,-10,0 --fov 70`; ground level by a warehouse: `--pos 1395,170,-1105 --ang -5,-20,0 --fov 70`. `--settle 15` is enough for vegetation to show.
