# Render3D lighting, GI, fog, sky and water

Notes collected from past sessions. Dated numbers are snapshots; re-measure before relying on them.

## DDGI long range cascades and faceted bent normals

*10 cascades from 0.5 m, sun-change triggered updates, bent normal rotated onto the smooth normal*

- 2026-10-14: `ddgi.CASCADES` 10, `ddgi_probe_spacing` 0.5, ratio 2 (0.5 m to 256 m spacing, about 6 km wide), update intervals 1, 2, 4, 8, 16, 32, 64 x4, `ddgi_max_coverage` and `ddgi_max_ray_distance` 4000. Cascades are fitted to the scene bounds and the ones that already cover everything are dropped, so small maps don't pay. A pixel samples at most two cascades.
- Slow far cascades are rescued by `ddgi_change_threshold` (0.05, sun direction in radians plus relative brightness, 0 = off) and `ddgi_change_min_interval` (2): a cascade updates early when the sun moved that much since its last update. Local lights, emissives and the sky map are not tracked, `ddgi.ResetHistory()` resets all.
- The resolve looks up probes along the AO bent normal. The AO pass computes it against `get_geometric_normal` (depth derivatives, flat per triangle), which showed as faint vertical bands on a low poly sphere. The AO pass now rotates the bent normal from the geometric to the shading normal before writing it (`rotate_between`).

**How to apply:** faint banding that follows mesh facets in GI means something in the lookup uses a depth-derived normal. Related: [DDGI software trace](#ddgi-software-trace).

## DDGI software trace

*only GI left; compute scene_bvh fallback; GOLUWA_NO_RAY_TRACING=1 to test*

Since 2026-09-27 radiance cascades and voxel GI are deleted; DDGI is the only GI. On a gpu without ray tracing `passes/ddgi.lua` swaps the ray tracing `ddgi_trace` pass for a compute one over `scene_bvh` (same hit buffer), and the shade pass shadows local lights with `scene_bvh_occluded`. Probe visibility rays are still skipped without ray queries.

`GOLUWA_NO_RAY_TRACING=1 luajit glw ...` makes the device report no ray tracing/ray query, so every fallback (ddgi, reflections, fog, lighting) can be tested on this machine; the env var reaches test workers. `test/tests/render3d/ddgi.lua` passes in both modes.

**Why:** the user prefers DDGI over RC and wanted the non-RT path working first, optimizing it later.
**How to apply:** when touching DDGI or anything gated on `ray_query_supported`/`ray_tracing_supported`, run the tests with and without the env var. Open items are in docs/refactoring-notes.md (GI section).

## DDGI emitter sampling

*additive FX were 99.9% of emitter power; filter + grid; ddgi_emitter_info*

Faint constant probe flashing on the Dear Esther crystal cave (2026-10-01) was the emitter samples, and the root cause was not the sampler.

- `Lightshaft_005` (an additive billboard) held 4.09e6 of 4.096e6 total emitter power. scene_bvh treats any additive material, or albedo-alpha-emissive, or emissive texture as emissive; DDGI then lights with it at emissive x albedo x 2000 cd/m2. Waterfalls, flowing water, wake masks, glass and sparkles were the same kind of mistake. The real crystals total about 250.
- With power-proportional global draws, every draw was the shaft, and a crystal drawn that way weighed g x total / (1 - share): fireflies for any `ddgi_emitter_grid` below 1.
- Fix: scene_bvh's Emitter records `additive` (additive and not albedo-alpha-emissive and no emissive texture); ddgi leaves those out unless `ddgi_additive_emitters 1`. Total power went 4.096e6 to 245.7 and the noise was gone.
- `ddgi_emitter_info` prints totals, the grid, and every emissive block with its materials' flags (blocks left out are marked). Use it first when emitter noise shows up.
- The emitter grid (`ddgi_emitter_grid` default 0.75, `ddgi_emitter_cell_size` 4 m) was built for many tiny emitters and is kept: near 0 it still bubbles slowly on this map. CPU build is in ddgi.lua `GetEmitters`, the sampler is `ddgi_pick_emitter_sample`; a CPU simulation showed mean 1.0007x of exact and 3x lower per-sample noise than power-only.
- Not checked: crystals should be blue. For albedo-alpha-emissive materials the sampler uses the texture's average colour and ignores its alpha mask, so a crystal texture with a white core may come out wrong and too bright.

**Why:** the tail of a single big emitter ruined the global proposal, and brute force (more candidates) only smoothed it.

**How to apply:** check emitter power with `ddgi_emitter_info` before tuning samplers. See [DDGI guided rays](#ddgi-guided-rays) and [DDGI fireflies came from fast-adapt](#ddgi-fireflies-came-from-fast-adapt).

## DDGI fireflies came from fast-adapt

*ratio vs ~0 night history; now needs 6 agreeing frames; measure at auto exposure, 20-frame gaps*

DDGI fireflies came from the irradiance fast-adapt snapping the history on noise. A probe sees a lit room through a doorway with 0, 1 or 2 rays per frame. Two approaches failed:
- **Single-frame ratio test:** fired on noise.
- **4-frame trend EMA vs history ratio, threshold 16 (2026-09-23):** still fired at night. The history on dark ground is ~0, so any flash is a huge ratio, and the flash lingers in the trend for many frames. It showed as probe-cell blotches all over open ground.

Fix (2026-09-24, `goluwa/render3d/passes/ddgi.lua` IRRADIANCE_INTEGRATE.adapt):
- It snaps only when each frame's own estimate differs from history by more than the `ddgi_irradiance_threshold` pvar (2) in the same direction for `ddgi_adapt_frames` (6) frames in a row.
- The run count is stored signed in the trend atlas alpha.

Results on the gi_reflections night overview, where ffly = pixels > 2× their median over captures 20 frames apart:

| setup | ffly | spot room light off | light on |
|---|---|---|---|
| old | 13.7% | 124 frames | 117 frames |
| fast-adapt disabled | 3.1% | 124 | 118 |
| new | 3.8% | 21 | 94 |

The old threshold of 16 never fired on real light switches (a 10× change); a threshold of 2 only became possible because runs filter out noise.

**Why:** exposure hides this. Screenshots at a pinned EV 6 look calm, but night auto exposure is around EV -3, about 700× brighter (see [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera)). Captures 3 frames apart are correlated by hysteresis 0.97 and understate flicker about 7×.

**How to apply:**
- Measure flicker by capturing at auto exposure with captures 20 frames apart (the old `tmp/ddgi_fireflies.lua` rig with FF_GAP/FF_EXPOSURE/FF_MAP env knobs and the light switch rig `tmp/ddgi_response.lua` are gone; rebuild with `Shot.Sequence`).

Emissive surfaces were the other half. The brightest-ray clamp erased lone hits on small emitters, under-counting them about 12×. Since 2026-09-24 they reach the probes only through RIS emitter samples (`ddgi.EMITTER_SAMPLES`), which brought night flicker down to 2.9%. Details are in docs/vulkan-raytrace.md, "Night fireflies and emitter sampling". Related: [DDGI software trace](#ddgi-software-trace).

## DDGI guided rays

*ddgi_guided_rays, per-probe radiance map steers rays; test/harnesses/guided_rays_scene.lua; ray clamp stays off*

DDGI fireflies from small bright openings are now attacked with path guiding (2026-09-30). `ddgi_guided_rays` (default 0.5, 0 = old uniform) is the share of a probe's 128 rays aimed by its own octahedral radiance map. Code: `pass_guide` in passes/ddgi.lua (last of the probe passes), direction and weight functions in `GetRayDirectionGLSL` in ddgi.lua.

- Guide texel: r = mean luma, g = cell probability, b = CDF, a = stamp hash of (world, cascade). A slot a different probe scrolled into has a mismatched stamp, so it falls back to uniform rays until its own guide exists.
- Every pass that needs a ray direction recomputes it from the guide; the guide is only replaced at the end of the frame, so trace, shade and integrate always agree. Any guide is unbiased as long as they agree, so a stale one only costs efficiency.
- Ray weight q = (1/4π) / (share/4π + (1-share) * density), density = prob * 16 / |d|_1^3; irradiance and distance integrates multiply their cosine weight by q. The relocation/back face statistics only look at the uniform rays.
- `ddgi_ray_clamp` (replaces the brightest-ray clamp, default 0/off) caps radiance at N x the probe's mean ray luma without its brightest. It only fixes fireflies, not dark "shadowflies", and darkens GI a bit.
- The view of it: `luajit glw --3d lua test/harnesses/guided_rays_scene.lua` (dark sealed room, small window, sun-lit ground outside; GR_WINDOW sets the size). 0.5 vs 0 was obviously more stable there, but barely visible in the main scene.

**Why:** hysteresis only turned the noise into slow bubbling; reducing the variance at the source was the correct fix. See [DDGI fireflies came from fast-adapt](#ddgi-fireflies-came-from-fast-adapt).

**How to apply:** if the guide seems to do nothing, check that stamps match (probes scrolled in are uniform for a frame) and that the cell size (about 22 degrees) is not larger than the opening.

## DDGI long range and bent normal facets

*10 cascades from 0.5 m, sun-change triggered updates, bent normal rotated onto the smooth normal*

Since 2026-10-14 DDGI has 10 cascades (`ddgi.CASCADES`), `ddgi_probe_spacing` 0.5 and ratio 2, so the coarsest is 256 m apart and about 6 km wide. Cascades are fit to the scene bounds and `ddgi_max_coverage` (4000), and any cascade past the one that covers everything is dropped, so small maps pay for fewer. Update intervals are 1, 2, 4, 8, 16, 32, then 64, which keeps the rays per frame close to the old 4 cascade setup. `ddgi_max_ray_distance` is 4000. A cascade also updates ahead of its interval when the sun moved or changed brightness by more than `ddgi_change_threshold` (radians plus relative luma, 0 is off) since its last update, at most every `ddgi_change_min_interval` frames. Only the sun is tracked, local lights, emitters and sky changes still wait for the interval.

The AO pass computes the bent normal against a depth derived geometric normal, which is flat per triangle. DDGI looks the probes up along it, so a low poly sphere showed faint stripes per facet. The bent normal is now rotated from the geometric normal onto the smooth gbuffer normal (`rotate_between` in passes/ambient_occlusion.lua) before it is written.

**Why:** the user wanted GI over large terrains with sparse far probes and unchanged near detail.
**How to apply:** if far GI looks stale after a lighting change that is not the sun, lower the relevant `ddgi_update_interval_N`. Any new consumer of the bent normal gets the smooth-normal-relative one.

## DDGI relocation: cramped probes

*probes in narrow gaps jiggle and leak sky; disable them*

DDGI probe relocation (passes/ddgi.lua probe_data pass, offset packed into probe data xyz as world + offset/spacing):
probes squeezed in a gap narrower than 2×RELOCATION_DISTANCE (e.g. furniture 0.2 m from a wall) get pushed back and forth,
jiggle every frame with the random ray rotation, and caused a large blue sky leak across the whole room. Fix: when the
averaged push mostly cancels ("cramped") keep the offset and disable the probe (w = 2). RTXGI's "move toward the farthest
hit" rule made ground probes drift sideways (farthest = random sky miss); averaged push away from close hits is used instead.

**Why:** the leak looked like exterior (roof) probes bleeding through the Chebyshev floor, but it was the two jiggling
crevice probes — the GI-only view (`ddgi_debug_gi 1`, low exposure) plus `ddgi_debug_probes 1` found it.

**How to apply:** when relocation changes look wrong, inspect with the probe debug view before tuning visibility. See
[DDGI fireflies came from fast-adapt](#ddgi-fireflies-came-from-fast-adapt), [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera).

## DDGI visibility min-weight leak

*faint probes skipped rays but were 1000x brighter; contribution-share rule fix, gm_construct room repro*

On gm_construct (brick room, grass on the roof) the room walls/ceiling glowed green and a bright band ran along the wall tops. `ddgi_visibility_rays` 0/1/2 changed nothing. Cause: commit 8d81b89c ("optimizations") only traces a probe's visibility ray if its blend weight is >= `DDGI_VISIBILITY_MIN_WEIGHT` (0.02). Probes outside the roof get weight ~0.004 after Chebyshev + the w<0.2 crush, so they were never ray-tested, but their irradiance is 100-1000x the dark room's, so a 1% share is the whole result.

Fix in `ddgi_sample_cascade` (goluwa/render3d/ddgi.lua): fetch the probe's irradiance before the ray test and trace if `w >= min_weight` OR `w * luma(E) > DDGI_VISIBILITY_MIN_SHARE (0.02) * luma(sum so far)`. Resolve cost +0.3 ms (0.86 -> ~1.2 ms), tracing everything was +0.95 ms. The shade pass still passes `DDGI_NO_VISIBILITY_RAYS` (now explicitly skips the contrast rule too); turning rays on there changed nothing visible.

Diagnosis tricks that worked: `ddgi.SKY_INTENSITY = 0` showed the green was sun-lit grass bounce, not sky; a debug return of hidden-weight fraction showed 0 everywhere (rays never fired); `behind_weight` showed no probe behind a surface contributed, so it was not a plane-side problem. `INSTANCE_FACING_CULL_DISABLE` is set on all TLAS instances, so `ddgi_visibility_front_faces_only` is a no-op.

A thin-walled sealed-box test in test/tests/render3d/ddgi.lua did not reproduce it (open case read 0 GI), so no regression test was added.

**Why:** the optimization assumed faint probes cannot show if they leak; at high indoor/outdoor contrast they dominate.
**How to apply:** if a leak persists while visibility rays seem to do nothing, first check whether the rays are even issued for the leaking probes (weight/share thresholds), not whether the rays hit. Related: [Fog needs DDGI visibility rays](#fog-needs-ddgi-visibility-rays), [DDGI relocation: cramped probes](#ddgi-relocation-cramped-probes), [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera).

## Fog needs DDGI visibility rays

*DDGI sampled without the TLAS leaks through thin walls on coarse cascades*

`ddgi_sample_cascade` only rejects probes behind thin walls via ray queries under `#ifdef DDGI_VISIBILITY_RAYS`, and a pass has to bind the TLAS (`ddgi_scene`) to get them. Without that, only the Chebyshev test is left, and it can't resolve a wall thinner than a coarse cascade's spacing. So points far from the camera inside a sealed building pick up the outdoor probes. The froxel fog scatter pass (`passes/volumetric_fog.lua`) had this bug: bluish blotchy fog inside a tall gm_construct building, visible only from a distance. Fixed by binding the TLAS like `passes/reflections.lua` does (+0.5 ms scatter GPU time on gm_construct).

**How to apply:** when a new pass samples DDGI and leaks only at a distance, check that it defines DDGI_VISIBILITY_RAYS first. Repro rig: `test/harnesses/fogleak/rig.lua` (sealed dark hall, fog on/off at locked EV, several distances). A gm_construct shot needs about 20 s settle before DDGI shows the leak; 6 s showed nothing. Related: [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera)

## Air and fog share the froxel volume

*FAR = shadow range, analytic only beyond; no single-point shadow lookups*

Since 2026-09-27 the aerial perspective ("blue haze") lives in the froxel volume with the scenery fog, lit by the shadowed sun and the DDGI/sky ambient. froxel_fog.FAR = 3000 (about the sun shadow map's 2700 m), SLICES = 96, which keeps near slice resolution close to the old 64 slices / 150 m. The composite integrates the air and fog analytically only beyond FAR, fully lit.

**Why:** the old composite applied the air from the camera with sun/sky visibility = 1 (blue haze indoors and in shade), and the far segment used ONE shadow lookup at a representative point, which projected hard, misplaced shadow shapes (V shapes, blue horizontal bands in the sky).
**How to apply:** don't reintroduce single-point shadow lookups for a medium segment. Every froxel holds air; for sky pixels the composite takes the unshadowed air of the first FAR out of the sky color instead (skipping air per froxel tile made halos at silhouettes). The ocean no longer applies its own aerial perspective, the fog does. The open-air ambient (get_scenery_fog_sky_ambient) is the sky averaged over all directions (upper sky from get_sky_irradiance, sky-lit ground below), never the sky along the view ray: that put the sunset glow in front of mountains hiding the sun. Froxel points use froxel_point: when the sample's pixel can't see the point, it moves to the ray of the froxel's pixel that sees furthest (fixes halos around foliage; clamping only per slice made staircase leaks on grazing walls).. Related: [Fog needs DDGI visibility rays](#fog-needs-ddgi-visibility-rays), [Scene color is pre-exposed](#scene-color-is-pre-exposed)

## GI measurement needs an exposure lock and a real camera

*both silently invalidate screenshot numbers*

- **Auto exposure** amplifies a dark interior back to mid grey, so a fixed leak and a fixed black room both measure ~128. Pin it with `r_exposure_lock <EV100>` (`goluwa/render3d/passes/blit.lua`; no argument = automatic; it takes an EV, indoor is about 10.5 and outdoor 15.5). `r_exposure_info` prints the metered EV. Local exposure also brightens dark regions per pixel, so set `r_local_exposure 0` for absolute comparisons. The DDGI resolve texture (`ddgi.GetScreenTexture`) is unaffected by any of this and is the better thing to read for GI numbers.
- **A one-frame camera override measures unconverged GI** (a sealed box read 0.71 where a held camera measures ~108). Use `Shot.Capture` (`goluwa/render3d/shot.lua`, `glw shot`), which holds a view for `settle` seconds (use 6 or more when numbers matter, 2.5 s is not always converged) and can wait for `converge`, or a priority-100 `View` with `ExposureLock`. Avoid pitch +-90, it yields a degenerate view matrix and a bogus reading.
- A converged mean says nothing about shimmer, and shimmer is what reads as "dirty": compare two captures a few frames apart from a stationary camera (mean absolute difference). Captures 3 frames apart are correlated by hysteresis 0.97 and understate flicker about 7x, use 20-frame gaps, and measure at auto exposure for night scenes (see the fast-adapt section).

## Scene color is pre-exposed

*multiply on write, divide on read, rescale histories; probes stay absolute*

Since 2026-09-27 the fp16 scene color targets (lighting, ocean, fog composite, translucent, taa) hold absolute cd/m2 times post_source.get_pre_exposure() = last frame's exposure / PRE_EXPOSURE_HEADROOM (32). The sun disc is physical (~2e9 cd/m2), which only fits because of this.
- Lighting math stays absolute. Multiply by get_pre_exposure() when writing scene color, divide when reading it for shading (ocean refraction, translucent refraction, fog composite, the reflections' last frame uses get_previous_pre_exposure()).
- History buffers (taa, ocean_resolve) scale by get_pre_exposure() / get_previous_pre_exposure(). The previous value is GetExposureTexture(false), valid only before this frame's exposure pass.
- blit/bloom: exposed = pre-exposed * exposure / pre_exposure_from_exposure(prev exposure). Metering converts back to absolute.
- Probe capture bundles have no exposure pipeline, so their pre-exposure is 1 and probes stay absolute.

**Why:** fp16 can't hold both a starlit night and the real sun; pre-exposure keeps the metered average near 0.28/32.
**How to apply:** new passes that sample or write scene color must use post_source.pre_exposure_block + GetPreExposureGLSL. Related: [Perf measurement pitfalls](performance.md#measuring-correctly).

## Shadow push wall leak

*full-texel push toward sun leaked under ceilings in far cascade; now 0.25 texel*

On gm_construct, a sawtooth of sunlight appeared along the wall/ceiling junction at distance (user view pos 2.64,-1.49,-21.2). Cause: in `sampleShadowMap` (render3d/directional_shadows.lua) the lookup point was moved `light_dir * max(texel_world_size, depth_step_world)` toward the sun. The sun's far cascade is 4096 d16 over 1350 m = 0.48 m texels (the 16 m inset is 0.01 m), so a wall point within ~0.5 m of the ceiling was pushed above the slab. Normal offset was not involved (NORMAL_K=0 changed nothing, push=0 fixed it).

Fix: push is now `texel_world_size * 0.25`. Checked for acne at 2 outdoor views and two sun angles; the diff against the full push was only at shadow edges.

**Why:** the user prefers fixing leaks in the shadow map over adding a ray-traced fix.
**How to apply:** thin-geometry leaks in far cascades scale with texel size; look at receiver offsets before adding cascades. Cascade layout lives in weather.lua (2 cascades, zoom 3 and 1, plus inset). The push is `light_dir * max(texel_world_size * 0.25, depth_step_world)` in directional_shadows.lua. Related: [DDGI visibility min-weight leak](#ddgi-visibility-min-weight-leak).

## Foliage quad shadows = RT contact ray

*TLAS has no alpha; CastShadows=false test tells shadow map vs ray terms apart*

Card-shaped dark quads under alpha-tested foliage (Crysis bigpatch_medium in Quarry, 2026-09-26) were the sun contact-shadow ray in `passes/lighting.lua` (`shadow_contact_visibility`), which traces the scene_bvh TLAS. The soup has no UVs, so it can't alpha test. Its reach is 8 cascade texels, which is metres in a level with a 2700 m shadow distance, so low ground cards darken the terrain. That's why it only shows in big levels and never in small test scenes.

Fix: alpha-tested visuals get the TLAS instance flag FORCE_NO_OPAQUE, and the contact ray uses gl_RayFlagsCullNoOpaqueEXT. The other TLAS rays force opaque via ray flags, so they're unaffected.

**Why:** toggling CastShadows=false on the entity did NOT remove the artifact. That's the quick test that separates the shadow map from ray-traced terms.
**How to apply:** for shadow artifacts only seen in levels, check the contact ray and other BVH/TLAS consumers before the shadow map paths (soup cascades 2+ also ignore alpha, see shadow_map.lua DrawSoup). Related: [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera)

## Glass tints light with a ray

*glass_light.lua, test/harnesses/glass_rooms.lua*

Glass (`Material:IsGlass()`: Refraction > 0, not additive) casts no shadow of its own while `r_glass_light` is on (`Material.GlassCastsShadow()` is false, so the shadow maps and the soup skip it). `get_glass_light(origin, dir, distance)` in the lighting pass traces a ray query with `gl_RayFlagsCullOpaqueEXT`: only see-through TLAS instances make candidates, each glass triangle multiplies the light by `refraction * 0.9 * albedo + (1 - refraction) * (1 - covering)` and is never confirmed. It runs for the sun and every local light that survived its shadow, and for the DDGI sun term in `ddgi_shade`. It replaced `glass_tint.lua` (four fitted 1024 maps, 25 taps, its own pass); the shadow edge is now as sharp as the geometry and point lights tint too.

- A closed glass box is counted once, by the faces the ray enters through (`!FrontFace`, the soup's faces wind the other way); `DoubleSided` glass counts every hit.
- Only instances flagged see-through (`scene_bvh` `see_through`, more than half the block's triangles refractive or alpha tested) are non opaque. Glass triangles in a mostly opaque model are opaque to the ray and stay untinted.
- The albedo of a glass hit is the texture's lowest mip, there are no uvs. `ddgi_material` carries `glass`, `glass_refraction`, `glass_covering`; `ddgi.HasGlass()` gates every ray (`glass_light` int in the lighting, ddgi and scene_reflection blocks) so a scene without glass pays nothing.
- Where it runs: the lighting pass and the translucent surface pass (sun and local lights; translucent carpets and glass surfaces get tinted light like opaque ones), `ddgi_shade` (the sun, local light samples, emitter samples, and every probe ray, which is multiplied by the glass between the probe and its hit or the sky), and `scene_reflection` (the sun and lights at a traced reflection hit, and the reflection ray itself, so a mirror shows a tinted view through a window). The screen space part of reflections reads lit scene colour and needs nothing. The local light visibility ray in `ddgi_shade` confirms every non opaque candidate except glass, the sun's trace any-hit shader ignores glass, and probe rays ignore refractive surfaces.
- A shadow map's penumbra reaches into the footprint of an opaque frame, where the sun's ray has no glass (the glass stops at the frame). The light there passed beside the frame, through the glass next to it. `get_glass_light`'s `search_radius` (the lighting pass gives it for a partly lit sun, 3 shadow texels clamped to 0.05 to 0.5 m) traces four more rays offset sideways when the first found none and takes the most absorbing result. Without it every frame shadow in gm_construct_m3_401's lobby had an untinted tan fringe on both sides (pos 185.84, 185.37, 214.62, sun quat -0.2567, -0.6705, -0.6424, 0.2680). Found with a debug view that drew the glass candidates per pixel: white (T = 1) bands wider than the dark cores.
- Cost on gm_construct_m3_401 (lobby, culled): lighting +0.3 ms, ddgi_shade +0.14, reflections +0.05, frame 11.5 to 12.0 ms.
- Not covered: the view ray through glass is the translucent pass's job, the software BVH trace without ray queries, and glass inside a mostly opaque model (see above).
- A graphics pipeline has one descriptor set unless `DescriptorSetCount` says more, and a set a command buffer still uses can't be rewritten (validation error on `vkUpdateDescriptorSets`). The TLAS and material buffer are per frame, so `translucent_surface` asks for `render.GetSwapchainImageCount()` sets like ocean does, and `glass_light.Bind` only writes what changed.
- **Translucent surfaces reflect the scene with a ray.** The forward translucent pass (glass, water-like panes, translucent carpets) had only the sky and the env probes, so a smooth pane showed a sky gradient instead of what stands in front of it (test room `reflect` in `test/harnesses/glass_rooms.lua`, `REFL_YAW`, `REFL_FOV`). `translucent_surface` now binds the TLAS, triangles, uvs and materials through `scene_reflection` (`SCENE_BINDINGS` 22 to 25, no light grid since it has its own) and the shader calls `trace_scene_reflection` along the mirror direction, weighted `1 - smoothstep(0.1, 0.35, perceptual_roughness)` against the probe reflection. One ray, no history, so rough surfaces keep the probes. `scene_reflection.GetDeclarationGLSL(bindings, true)` and `GetGLSL(block, true)` are the shared modes for a pass that has the light grid, `ddgi.GetCommonGLSL` and `get_glass_light` already (the visibility ray define stays off so the probe sampling is unchanged). The traced hit is lit through `get_glass_light` like any other.
- Without ray queries glass falls back to the dithered shadow (`GlassCastsShadow` true).
- Scenes: `luajit glw --3d --background --validate lua "import('test/harnesses/glass_rooms_shot.lua')"` writes `tmp/glass_rooms_<room>.png` for three rooms (red/green/blue ceiling panes, a blue pane with a point light, a blue glass box over an opaque floor; chrome balls in the first and last show the reflections). `SUN_EV=14` locks the exposure of the sunlit rooms (auto exposure washes the glass box out), `GLASS_OFF=1` turns the effect off, `LAMP_EV`/`LAMP_LUMEN` tune the lamp room.

## Reflection halo around objects on glossy floors

*gm_construct_m3_401 lobby, pos 169.97 179.46 204.18 ang -0.1807 -1.885 0 sun quat -0.2229 0.3602 0.0891 0.9015; also pos 184.59 187.46 206.04 ang -0.4527 -0.7677 0 sun quat -0.0115 0.9875 0.1302 0.0876*

A one pixel rim (a halo after taa) along the base of steps, columns and benches on a glossy dark floor, the colour of the sky (black with the sun down), worst indoors under a bright sky. Not the traced reflection (it showed with ray queries off), not direct light (0 there), not taa (it only widens it). Found by drawing the reflections texel's alpha raw, after the lighting's upsample and the roughness through a debug return in `get_reflection`:

- The reflections pass's history alpha was the cause. History is read bilinearly at the texel's own position, and at a silhouette that blends in the alpha of what is beside the surface (an object with roughness over the cutoff has alpha 0). The history feeds itself, so the floor's alpha settled at 0.4 to 0.6 while its neighbours were 0.6 (current frame raw alpha and the filtered one were both fine). Where the alpha is low `combine_reflections` mixes in `env_reflection`, which is the bright unoccluded sky indoors. Fix in `passes/reflections.lua`: the history alpha is clamped to the range of the similar texels' alphas the spatial filter just read (`alpha_min`, `alpha_max`).
- `get_reflection_blend_weight` (ibl.lua) was `(1 - smoothstep(0.08, 0.45, r))^2`, so a floor at perceptual roughness 0.13 to 0.2 already gave a third of the reflection to the environment. It is `1 - smoothstep(0.3, 0.45, r)` now, in line with the 0.45 the reflections and traced paths stop at. This alone halved the rim and removed the glowing tile grout.
- Tried and dropped, they changed nothing: widening the lighting's reflection upsample to 16 taps, four depth weighted history taps, a roughness weight in the reflections pass's spatial filter, capping the specular antialiasing of `get_antialiased_roughness` for glossy surfaces.
- Test room `reflection_floor` in `test/harnesses/glass_rooms.lua` (`TILE_ROUGHNESS`, `FLOOR_LAMP`, `PVARS=key=value,..`) does not reproduce it, its rim was the traced hit at the contact line.

## Reflection sphere scene

*addons/examples/lua/examples/render3d/reflection_spheres.lua*

An interactive scene: one metallic sphere in the middle of a room open to the sky (red, blue, yellow and green walls), its roughness changed by holding pageup and pagedown (`input.IsKeyDown` in an Update listener, 0.5 per second). The floor is a box with the Crysis `Terrain/Detail/plains_grass_green.dds` texture (tiled with `BaseTextureTransformU/V`, tinted green, the detail texture is nearly grey) (no grass shader, it takes no part in reflections or gi and made the scene hard to read), ringed by about 70 Crysis palms, bushes and plants and 220 `jungle_grass` patches. Needs Crysis 1. Run it with `luajit glw --3d lua "import('addons/examples/lua/examples/render3d/reflection_spheres.lua')"` (add `--hot-reload` to edit it live). The start position looks at the sphere through a gap in the vegetation. Hill and river trees were left out, their canopies are about 12 m wide.

## Global gi strength

`ddgi_strength` (default 1, 0 to 4) scales the light the probes give every consumer: `ddgi_sample_irradiance` is a wrapper that multiplies the real lookup (`ddgi_sample_irradiance_unscaled`), and the resolve pass's out-of-volume environment fallback is scaled the same way, so the lighting pass's diffuse gi and reflection fallback, the translucent pass, traced reflection hits, ocean and fog all follow it. The probes' own bounce rays (`ddgi_shade`, which defines `DDGI_UNSCALED`) are not scaled, that would compound with every update. 0 gives no indirect light from the probes (only the direct light, reflections and the sky in the reflection), 2 doubles it.

## Reflections are two passes

Naming: "reflections" is the whole system (the passes, their pvars, `reflection_data`, `reflection_tex`), "screenspace" is the part that marches the depth buffer and reads last frame's colour (`SCREENSPACE_*`, `trace_screenspace_direction`, `reflection_screenspace_roughness`, the ocean's `screenspace_*`). The screen space march is what traces the reflection of a smooth surface when `reflection_screenspace_roughness` is above 0 and the whole reflection where there are no ray queries (`reflection_ray_query` off or no hardware).

`passes/reflections.lua` holds `reflections_trace` (the rays, written raw to `reflection_raw`, `reflection_rough_rays` rays per rough pixel, see `blue_noise` for the sample numbers) and `reflections` (the 3x3 spatial filter and the temporal history, writes `reflections` and `reflection_depth`, which lighting and the history read). They were one pass whose filter read its neighbours from an 8x8 tile of shared memory, so a texel on a tile border averaged 4 or 6 neighbours and not 9 and the border showed as a grid every 16 pixels (the pass is half resolution) in the noise of a rough reflection: a high-pass scan of a rendered sphere at roughness 0.8, one ray, no aa, had its strongest period at 16 px in x and y with 1.8x the energy on the tile borders, 1.2x (the level of the other periods) after the split. The filter reads the raw texture and the gbuffer directly now. `shared_glsl` is the constants and helpers both passes use. `reflection_gi_threshold` (default 0.5, 1 is never) is the perceptual roughness where a reflection starts to be the light computed from the gi (`get_reflection`'s `env_reflection`: the probes' irradiance, the sky weighted by sky visibility, the env probes) and not what the rays traced, fully the gi `reflection_gi_fade` (default 0.15) above (`ibl.GetReflectionGIRange`, `get_reflection_blend_weight`). `reflections_trace` casts no ray above the end of the fade (`reflection_data.roughness_cutoff`), so a lower threshold also saves the rays. Furnace test, 2026-10-13: within 0.2 percent of the all traced result for the metal row and 0.2 percent for the dielectric row (the gi is no darker than the traced reflection), the blended sphere is a flat blur of the gi's colour, with none of the angular detail of the rays. `reflection_resolution` (`full`, `half`, `quarter`, default half) is the resolution both run at, changed at runtime by recreating their framebuffers (the history starts over). `reflection_filter_radius` is in texels of the half resolution, the filter scales it so the blur is the same on screen at every resolution. Full resolution costs about 4 times the rays, filter taps and memory of half; it improved the flicker of thin leaves in a mirror reflection a little but did not remove it (2026-10-13, the 4 phase pixel pick was ruled out with a toggle, nothing changed).

## Reflection furnace test

*addons/examples/lua/examples/render3d/reflection_furnace.lua*

A closed room whose walls emit and reflect (emission E, albedo A, so every surface has radiance E / (1 - A)) with two rows of albedo 1 spheres, metal and dielectric, roughness 0 to 1. In a furnace nothing may look brighter or darker than the walls. `luajit glw --3d lua "import('addons/examples/lua/examples/render3d/reflection_furnace.lua')"`, then toggle `ddgi_strength`, `reflection_rough_rays`, `reflection_screenspace_roughness`, `r_pass_reflections`, `r_pass_ambient_occlusion`. Measured as the mean of a patch of the sphere against the wall in the tonemapped image (about +-0.5 percent of resolution, the auto exposure moves the whole image by about 2 percent between runs, it is not linear radiance), on 2026-10-13, traced reflections at 4 rays, no radiance blend:
- metal spheres: +0.2 to -0.5 percent (traced), -0.9 to -1.5 percent with the reflections off (the probe and environment fallback alone), 0.0 to -0.2 percent with the ambient occlusion pass off too.
- dielectric spheres: -0.8 to -1.9 percent, rising with roughness, -1 to -2 percent with the reflections off. Their diffuse is the probes' light, 'ao' off took away about 1 percent.
- the room corners are visibly darker with the ambient occlusion on, the screen space ao darkens a furnace.

## Translucent shadow measurement

*alpha_measure.lua recipe, soup per-vertex opacity, LocalExposure=0 pitfall*

test/harnesses/alpha_scene.lua + test/harnesses/alpha_measure.lua (CAM_H=12 FOV=90 near/inset, CAM_H=25 FOV=60 far/soup, TOGGLE=1 flips material props at runtime) print "sun passed" per material vs 1-opacity. Results match within ~0.05.

**Why:** shadow maps only hold depth, so translucency is dithered (Material:GetShadowOpacity). Far cascades rasterize the scene_bvh soup, which had no materials: it now bakes per-vertex opacity in ExpandPositions (state.with_opacity) and DrawSoup draws `raster_dithered` blocks with a second pipeline. TLAS instances of see-through blocks are FORCE_NO_OPAQUE so the contact ray culls them.

**How to apply:**
- Measure with `LocalExposure = 0` in the view and an EV sweep of the lit floor to undo the tonemapper; without it results are flaky.
- `Screenshot(update_events=n)` runs Update events, not frames; shadows/GI need real frames (wait on FrameEnd, remove the listener with the returned fn).
- Floor of 60 m with the camera 25 m up got no far shadows at all, 200 m works; not investigated.
- A material changing translucency used to leave its visual out of every pass (stale RenderEntries); fixed in visual.lua patch/rebuild, test in test/tests/render3d/shadow_opacity.lua.
- DDGI/other TLAS rays still force-opaque, textured alpha-test in the soup is still opaque.

**Soup UVs (static flag `scene_bvh.SOUP_UVS`, now always true):** parallel 24 B/tri uv buffer, expander writes per-vertex uv + material id, dithered blocks draw with a pipeline that samples the albedo alpha via a per-pipeline material table (shadow_map.lua). Matches raster shadows on TEX=1 panels. Far shadows sometimes never appear in a run (soup ready after the cascade rendered?), flag on or off; rerun before trusting a number. The additive panel is an emitter and lights nearby floor samples via DDGI.

## Gbuffer roughness is GGX alpha

*gbuffer_roughness() is alpha, mra.g stores perceptual; clamp radiance in exposed units*

`gbuffer_roughness()` returns GGX alpha. Readers must `sqrt` it to get perceptual roughness. reflections.lua used to read it raw, and that mismatch hid bugs (fixed 2026-09-24). Since 2026-09-29 the raw mra.g channel holds perceptual roughness (write through `gbuffer_encode_roughness(alpha)`): 8-bit alpha put alpha 0.002 at 0, and the sun lobe's (alpha / lobe_alpha)^2 energy then removed the glint from mirrors.

Also, scene radiance is in absolute units (daylight at EV 12 is thousands). A fixed luminance clamp like "8.0" crushes everything to black. Apply such limits in exposed units via `post_source.GetExposureTexture(true)`, the way bloom and reflections do.

**Why:** the gm_flatgrass crack streaks came from the reflections' sky fallback bleeding through its non-alpha-weighted filters. Fixing the roughness then exposed the absolute clamp.
**How to apply:** any new pass reading mra.g or clamping radiance should follow the above. Before debugging reflection/DDGI-RT visuals, wait for BVHSceneReady (see [GI measurement needs an exposure lock and a real camera](#gi-measurement-needs-an-exposure-lock-and-a-real-camera)).

## Grazing fresnel ignored specular

*F90(F0) fix in ibl.lua; debug washed-out surfaces with black albedo*

Until 2026-09-26 the ambient specular was `reflection * (F0 * envBRDF.x + envBRDF.y)`: the grazing term assumed F90 = 1, so SpecularMultiplier 0 still gave a strong white sheen edge-on. Fixed Filament-style with `F90(f0) = clamp(dot(f0, 50 * 0.33), 0, 1)` in ibl.lua (F_Schlick, F_SchlickRoughness), lighting.lua and translucent.lua. Only F0 < 0.02 (specular multiplier < 0.5) changes; water is unaffected. The user said this "massively improved everything".

**Why:** grass looked grey-white at eye level; the cause was additive specular, not albedo or transmission.

**How to apply:** when a surface looks washed out or grey, render it with `set_albedo(vec3(0))` and remove terms one at a time (specular, transmission, fog) to find additive light. Thin geometry seen edge-on (grass blades) also gets huge direct GGX specular even at tiny F0; grass uses roughness 0.7 and specular 0.02 for that reason. Related: [Gbuffer roughness is GGX alpha](#gbuffer-roughness-is-ggx-alpha).

## HDR environment override

*weather.SetEnvironmentMap(path) disables sun/atmosphere, EXR PIZ float pitfall, intensity clamp*

`weather.SetEnvironmentMap(path)` (also `envmap <path> [intensity]` command, and atmosphere_controller `EnvironmentMap` / `EnvironmentMapIntensity`) sets `atmosphere.environment_map_path`. `atmosphere.IsEnabled()` then returns false (sun lux 0, no fog, clouds, aerial perspective), and `GetGLSLMainCode` samples the equirect first (u = atan(z,x)/2pi+0.5, v = 0.5-asin(y)/pi, top row up). envprobe re-renders via `atmosphere.GetEnvironmentMapVersion()` in `HasSkyChanged`, so IBL, DDGI and reflections all use the map. Sky is black until the async texture is ready.

**Why:** intensity defaults to 1000 cd/m2 per map unit because probes are b10g11r11 and clamp at 65504, so a bright sun pixel in an HDRI clips. Raise it only with that in mind; auto exposure hides the absolute level.

**How to apply:** test with `test/harnesses/envmap_scene.lua` sphere grid + `shot --setup`. exr.lua decodes none/RLE/ZIPS/ZIP/PIZ; PIZ wavelet must run once per 16-bit word plane (`start + j`, stride = words per pixel), float channels decoded as garbage without it. magick only writes half EXRs, so float PIZ is only verified against the user's 1K file (matches magick PFM to 4e-6).

## Underwater look-up artifact

*negative inscatter, not NaN; probe signs; tank test scene*

Looking steeply up inside water showed a huge white disc with a black ring. Cause: `integrate_attenuated` in passes/ocean.lua divided by `max(x, 1e-3)`, but x is negative when the path climbs faster than the light fades (dir.y > mu, ~48 deg up for the sky's mu 0.75). That gave large negative inscatter; bloom then spread the negatives (negative bloom_tex), the tonemap saw negative exposed values (black) next to huge ones (white). Fixed by dividing by x with near-zero entries swapped for 1.

**Why:** no NaN/inf anywhere, so isnan/isinf probes found nothing. Colour-coding `col * exposure` in blit.lua (nan/inf/negative/>1e4) and then the bloom texture's sign located it.

**How to apply:** for "inf/nan looking" artifacts, probe for negative values too. Test scene: addons/examples/lua/examples/render3d/water_volume_test.lua (40x12x40 tank, Position.y = surface, Size.y goes down). Related: [Water rendering](#water-rendering), [Scene color is pre-exposed](#scene-color-is-pre-exposed).

## Volumetric clouds

*how clouds hook into sky/shadows/fog; noise range and lattice-streak pitfalls*

Volumetric clouds (built 2026-09-29): `goluwa/render3d/clouds.lua` (layers, presets, GLSL) and `passes/clouds.lua` (noise bake, beer shadow map, sky dome, quarter-res checkerboard trace + half-res reconstruct). Composited in `passes/volumetric_fog.lua`. `weather.SetCloudLayers(layers)` (read back with `GetCloudLayers`/`GetCloudCover`; presets such as `windy` live in `climate.lua`).

- Sun is no longer dimmed by `(1 - cover)`. Per-pixel `get_cloud_shadow` is multiplied in: surface_lighting (type 0), the medium shadow fn (froxels, ocean), DDGI shade. Shadow maps are only disabled when `clouds.GetMaxTransmittance` is tiny (coverage 1, no gaps).
- The sky dome is published via `atmosphere.SetCloudSky` from `clouds.Update` (the weather Update listener). The lighting pass skips it in the main view (`sky_clouds`), since the fog composite draws screen-space clouds.
- Pitfall: baked perlin-worley/worley fbm values only span ~0.54-0.80 (`test/harnesses/clouds/noise_stats.lua` measures this). Channels must be stretched to 0-1, or any coverage fills the sky.
- Pitfall: radial streaks at the horizon come from the noise tile lattice, not step aliasing. Fixed by a domain warp from a turned, low-frequency copy of the base noise, ramped in with distance in tiles (CLOUD_WARP_*). The warp mip must be offset by log2(warp frequency), or far away it reads a flat mip and does nothing. At full strength up close it shears clouds into swirls; the user liked that, so it is the `swirl` layer field (preset `windy`).
- Block structs (`{"shadows", {...}}`) are NOT flattened by glsl_metadata. Splice fields in with `unpack(...)` last.
- Texture:GenerateMipmaps / BlitImage now support 3D (image depth) and take `{cmd, src_stage, dst_stage}`.
- Pitfall: detail_scale of 500-900 m reads as no detail at all (a cumulus 3 km away is ~3 m per half-res pixel). Presets use 150-400 m. A steep density ramp (the old `* 3`) gives hard cartoon outlines; the rim must be thin density for erosion to show.
- Weather map channels: r coverage, g regional heap height, b cirrus fibres (flat layers), a base height within `base_variation`. Heap tops also vary per cloud from a coarse read of base noise .g. Layers get distinct shape/detail offsets in SetLayers, so a view shows a different noise region than before 2026-09-29; judging coverage from one view is noisy (one view spans ~1-2 shape tiles).
- Pitfall: from high up, sky pixels look below the horizon, and nothing clipped them at the planet: atmosphere density functions clamp altitude at 0, so underground air/fog integrates at full ground density and whites everything out. integrate_scattering never clips; its callers must (volumetric_fog composite uses get_planet_distance, froxel far fog clips for is_sky, cloud_march clips t_max). Test scene ground is only a 16 km box.
- Pitfall: the sun disc is ~1e5-1e6x a cloud's brightness, so cloud transmittance decides its visibility down to ~1e-6. A hard march cutoff cuts the disc along a contour; no cutoff shows it through grey cloud (Wrenninge octaves underestimate forward diffuse light). Now T fades out between 1e-3 and 1e-4 (CLOUD_LIT/HIDDEN_TRANSMITTANCE). Fog is split at cloud_depth in the composite, else ground haze paints over nearer clouds below the horizon.
- Before/after: `test/harnesses/clouds/compare.sh <tag>` renders a fixed set of views into a jpg per tag.
- Views/shots: `test/harnesses/clouds/views.lua` with CLOUDS, VIEWS, EV, OUT env vars.

**Why:** Tuning took several rounds; these are the things that weren't obvious from the code.
**How to apply:** Read this before touching cloud density/lighting or adding a pass that lights with the sun. Related: [Scene color is pre-exposed](#scene-color-is-pre-exposed), [Air and fog share the froxel volume](#air-and-fog-share-the-froxel-volume).

## Water rendering

*ocean + water volumes in passes/ocean.lua; mean sea level, phase sign, ripple and streaming pitfalls*

Ocean and water_volume components are both drawn by the "ocean" pass (name kept for fog/envprobe/post_source). Sea state and presets live in goluwa/render3d/water.lua; showcase is addons/examples/lua/examples/render3d/water_showcase.lua (views via `water_view N`).

- Ocean level is now the MEAN surface (old Seascape heights were all positive).
- Phase function angle is dot(-view_dir, light_propagation_dir); the wrong sign made murky water glow milky.
- Never smoothstep(e, e, x) (footprint 0) — undefined in GLSL, broke all wave heights.
- A few discrete sine waves give visible crisscross grids; per-pixel ripples use advected gradient noise with analytic gradients instead.
- Submerged-floor test must be "is the point inside the volume", not a distance comparison along different rays.
- Ocean pass cost (island example from the sea, 8.3 ms before): ablating parts in one process (a bitmask uniform cycled every 3 s, compare modes inside one process, the process to process variance is bigger than the wins) showed the refraction side at 6.4 ms, of which the light shafts in `get_water_inscatter` were 5: 8 samples each with a `get_caustic` (newton steps, 4 wave fetches and the ripples a step). The reflection ray, detail ripples, shore ray, point lights and the 32 to 96 step trace were each under 1 ms. The caustic of the shafts is now faded out with distance from the camera (full under 25 m, gone at 140 m, where its lines are thinner than a pixel and average out to no change), 3.1 to 4.0 ms. A fade by `get_pixel_footprint` did not cut anything at the thresholds that matched those distances (the ocean renders at a size where the footprint is about half of what the formula for the display gives), so it is by distance. Looking straight down in shallow water has no distance to fade by, so the shafts take 2, 4 or 8 samples by the length of the path through the water and their caustic skips the fine ripples and the newton step (only the floor caustic has them): 13.9 to 9.0 ms in one-process A/B at that view. `height_map_tracing` takes `scene_limit` and stops where the scene is in front, so land pixels don't march the waves.
- The parts of the water that cost can be turned off with pvars (`r_water_caustics` for the floor's, `r_water_shaft_caustics`, `r_water_shafts`, `r_water_ripples`, `r_water_lights`, `r_water_reflection_trace`, `r_water_shore_foam`, `r_water_inscatter`, `r_water_refraction`, `r_water_sun_shadows`, `r_water_ambient_gi`, all on by default, defined at the top of passes/ocean.lua). They are bits of one uniform (`ocean_data.features`), so toggling doesn't recompile the shader. `test/harnesses/scatter/water_toggles.lua` turns each off in turn in one process at a shallow, straight down camera, with a baseline between every two (the gpu clock wanders by several ms inside a process, an un-interleaved run gave a 3.6 ms and a 6.6 ms "all on"). 6.6 ms all on at first, 5.3 after the lines below; what each saves (they overlap, so they don't add up): inscatter 2.2 (ambient gi 1.1, shafts 0.6), ripples 1.6, refraction 1.6, floor caustics 1.25, shaft caustics 0.65, reflection trace 0.7, sun shadows 0.45, lights 0.15, shore foam 0.07.
- The water's ambient light (`get_ambient_irradiance`, the ddgi probes) was the biggest piece of inscatter: it looks up 27 probes (smooth blend) and with `DDGI_VISIBILITY_MIN_WEIGHT` each of those above the weight fired a visibility ray query, up to 27 per pixel. It passes `DDGI_NO_VISIBILITY_RAYS` now, the surface of the sea is open sky so there is no wall to leak through, and the shots with and without are the same to the eye (2.15 to 1.1 ms). `get_caustic` also drops the newton steps and the small ripples once it is half blurred by depth. The alternating of shaft caustic samples between frames was tried and gained 0.25 ms, not kept.
- Terrain streaming lags ~5 s after camera jumps; shot sequences need settle ≥6 s or you see chunk skirts/ocean through land.

- Refraction only offsets the straight-behind pixel by the ripples' deviation from flat refraction. Flat (apparent depth) refraction in screen space tore apart at screen edges and behind objects crossing the surface (ghosts, missing water at the screen bottom); don't bring it back.
- Caustics: gradient noise (value noise lattice made triangles) + full refraction Jacobian by finite differences of the slope; filter only depth*0.012, short ripples are what make pool caustics.

- Map importers: water.MediumFromFog(linear color, extinction, albedo_scale) turns game water fog into our medium. BSP uses $fogcolor/$fogend (albedo scale 4; the vdf decoder already makes "{r g b}" a Color). Cry uses FogColor*FogColorMultiplier/FogDensity, albedo scale 4 (12 was milky).
- Crysis: ocean settings are Mission > Environment > Ocean/OceanAnimation; WaterLevel is mean sea level (no offset). WaterVolume = polygon (min-area rectangle fit), River = Bezier spline cut into <=16 m boxes. Load levels with the `map` command (`goluwa/engines.lua` finds the engine; `cry_engine.lua` tries the name and `Multiplayer/<name>`).
- More volumes than water.MAX_VOLUMES (64): the nearest to the camera are drawn.

Related: [Scene color is pre-exposed](#scene-color-is-pre-exposed), [GPU pass timing](performance.md#measuring-correctly)

## Import order in render3d

*low level render3d helpers must not import render3d; cry_engine/level.lua imports Material lazily*

`goluwa/cry_engine/level.lua` imports `render3d/material.lua` inside the function that needs it (not at module level), and `render3d/material.lua` no longer imports any engine content module, so the old steam -> crylevel -> render3d -> material loop is gone. The rule that remains: don't import render3d or weather at the top level of an importer of the content modules, and low level helpers (batch_table, instance_batcher) must not import render3d either, or importing them first creates a loop (test files that import them first would fail). Related: [Crysis fog and sun](crysis.md#crysis-fog-and-sun).

## Prefers physical over legacy look

*keep physically derived results even when the old look changes*

When a physically correct model changes the established look (e.g. PCSS with the real 0.27 deg sun made clear-day shadows slightly soft near the camera), the user liked the result better than the old fixed filter.

**Why:** said "much better than before, even at a clear day" on 2026-09-27 after the cloud-cover PCSS change.
**How to apply:** don't add special cases just to preserve the old look; derive from the physics or the reference engine and mention the visible change. Related: [Crysis vegetation bending](crysis.md#crysis-vegetation-bending).

## Ray-traced reflection material detail and visibility

With `reflection_screenspace_roughness` at 0 (default) and ray-query hardware, opaque and water reflections use the nearest scene hit as the authority for visibility and the screen space trace is skipped. Blending an unrelated screen-space hit over a solid RT hit can show distant buildings through the reflected balcony wall. Below the perceptual roughness it is set to, the screen is traced first and is the reflection where it holds one, and the same trace (cutouts alpha tested, the hit's own textures) fills the rest. There is no cheaper trace for those fills any more. Translucent surfaces have no screen space reflection and always trace.

Reflection history in motion: a reflection is an image behind the surface, `hit_distance` past it along the view ray, and it moves with the camera by another amount than the surface does. Reading the history where the surface was made reflections drag along with their surface and bend while the camera moved (no TAA, so the history is the only accumulation, 10 to 30 frames). The filter pass reads it where the image was (`reflection_hit_reprojection`, on): the image sits at `hit_distance / (1 + 2 * curvature * hit_distance)` behind the surface (the mirror equation, curvature from how far the normal turns over a texel, a concave surface can have no image), blended into the surface position over roughness 0.1 to 0.5 where the hit distance is an average, and the history weight falls by up to half with what is not corrected. The surface's own depth validates the history, not the image's. Measured on the sphere scene, camera strafing 2.4 m over 60 frames against a still capture of the same pose: error 8.4 off, 4.3 on (1.8 between two still captures). Foliage animates, so regions with leaves can't be measured this way.

Reflection pipelines bind the soup UV buffer (`uvs = 10`) as well as triangles and materials. Hit UVs and vertex blend weights are interpolated from ray-query barycentrics, the albedo texture is sampled at the hit and the second albedo/blend-modulate textures are applied where present. DDGI's averaged albedo is fine for diffuse probe lighting but loses the texture detail reflections need. Candidate intersections also run the shared alpha-cutout test, so cutout geometry is skipped. Terrain keeps its world-space material sampling. This is single-bounce hit shading, so secondary specular reflections are not reproduced.

Reflection rays run in the half-resolution reflections pass. Odd framebuffer sizes round the half size up, so the full/half ratio must not be truncated to an integer. `get_reflection_gbuffer_pos` in ibl.lua partitions the G-buffer by integer division for both ray generation and the reflection upsample (see test/tests/render3d/reflection_mapping.lua).
