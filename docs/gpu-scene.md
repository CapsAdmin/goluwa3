# The scene store (`goluwa/render3d/scene/`)

The gpu-side description of the world. Ray queries (GI, reflections, glass, fog, light occlusion, particle collision, scatter cover/conform) trace against it, and the main view and sun shadow maps cull and draw from it. Nothing on the draw path reads back from the gpu. `gpu_culling.lua` only holds what the culling shares: `culling_enabled` (`r_feature_culling`), the last frame's depth pyramid, the frame the drawn cull was dispatched in (`MarkMainViewDrawn`, `GetDrawnCullFrame`) and `ExtractFrustumPlanes`.

## Parts

Meshes have their own bottom level acceleration structure, instances point at them, and hit shaders read everything from the same tables.

- `store.lua`: row tables in persistently mapped buffers with a free list. Tables the cpu rewrites every frame are **staged**: the cpu writes a host shadow copy and calls `Touch(row)`, and `store.FlushStaged(cmd)` (called from `instances.Build`, `draw.Cull`, `draw.CullShadow`, outside a render pass) copies touched rows to a device local buffer. Writing a staged table without `Touch` leaves the gpu with the old row. Values the gpu writes itself (the update pass, producer rows) are not in the shadow.
- `meshes.lua`: one row per `Mesh` (vertex/index addresses, stride, triangle count, BLAS address), created on demand by `meshes.Get(mesh, dynamic)`. The BLAS is built from the mesh's own buffers (`accel.lua`). A `dynamic` mesh is refit in the frame `skinning.Dispatch` skinned it. All meshes use the polygon vertex layout; the hit shaders assume it.
- `instances.lua`: two tables with the same index: the TLAS records (`customIndex` is the row) and the shader data (mesh row, material row, flags, mask, bounding sphere, LOD switch ratios). `Build(cmd)` builds waiting BLASes, runs producers, runs the update pass (hides a row by flag, mask, `r_rt_distance`, or LOD mismatch; `r_rt_lod_scale`, `lod_level`) and builds the TLAS. `rt.GetTLAS(cmd)` does this once a frame from `render3d.lua`, after `UpdateScene` and skinning, before any pass records.
- `bridge.lua`: `visual.lua` feeds it. A visual is one instance per render entry of every LOD (billboards included), with ray mask and flags from its material (`instances.GetMaterialFlags`). It also serves consumers: `ConsumeDirty` (dirty boxes, light occlusion), `GetBounds` (DDGI volume), the emissive instances. `emitters.lua` builds DDGI's emitter cdf on the gpu each frame, so moving emitters cost the cpu nothing.
- `hit.lua`: the one place that reads a hit (instance, primitive): `scene_hit_tri`, `scene_hit_uv`, `scene_instance_material`, `scene_hit_texture_lod`. `GetTraceGLSL(tlas)` gives `scene_trace`/`scene_occluded` (solid mask) for passes that do not shade the hit, with stubs when there are no ray queries. Passes declare `hit.GetDescriptorSets(...)` and call `hit.Bind` every frame.
- `scatter_rt.lua`: a producer that turns scatter's shadow lists into instance rows on the gpu every frame (`FLAG_PRODUCED`, left alone by the update pass). `r_scatter_rt` turns it off, `bvh = false` on a prototype keeps it out.
- `draw.lua`: the main view draw (below).
- `visibility.lua` / `scene_draw_visibility`: estimates which drawn rows are actually visible by tracing rays from the camera into the scene.

Visuals with `InSceneBVH = false` are not ray traced (mask 0) but are still drawn; `RaysOnly` visuals are traced and never drawn. `ViewHidden` visuals are traced and cast shadows but are not drawn in the gbuffer (a first person head: gone from the camera, still in reflections). Without ray queries (`ray_tracing_supported`) nothing is built and shaders use stubs; `GOLUWA_NO_RAY_TRACING=1` tests this.

## Drawing from the store

- `draw.Cull` (recorded in `pre_render`) runs one thread per drawn row: distance, frustum planes, screen size, depth pyramid occlusion, LOD choice with dither fade (`lod_fade_width`, fade in `world[0][3]`), and writes an indexed indirect draw plus the world and previous world matrices. `draw.Draw` binds a batch table (one record per slot) and draws four groups (single/double sided, height map or not) with the two multi draw pipelines.
- Translucent rows (`RASTER_TRANSLUCENT`) get a second cull kind with their own buffers and thickness per slot; `draw.DrawTranslucent` draws them with multi draw twins of the translucent surface passes. The cpu still walks translucent components only to feed the passes' depth range and refraction request.
- Sun shadow cascades (`ShadowMap:CullScene`/`DrawScene`, `draw.CullShadow`) write non indexed indirect draws for rows with `RASTER_SHADOW`, picking the LOD nearest the camera and skipping casters smaller than `min_caster_texel_size`. Height-map visuals, scatter and point lights are drawn from the cpu.
- The cpu still draws: entries without gpu buffers (`bridge.GetCPUDrawnVisuals`), every entry when the store did not cull the frame (multiple cameras in the stack, scene views, `visual.noculling`), ignore-z materials, debug drawing, and `particle_emitter_cpu`.
- A row's cull box is its own mesh's box (`bridge.GetEntryBox`), not the visual's; a map is one visual with many parts and the whole box would always contain the camera.

## Rules

- Everything the gpu reads of a row must stay valid for frames in flight: freed rows keep their data `RETIRE_FRAMES` before being zeroed, `Buffer` releases are deferred by submission serial, and growing a table keeps the old buffer for a few frames. Reading a zeroed mesh row makes a ray read address 0 and loses the device.
- Build the TLAS outside a render pass and before the passes that trace.
- DDGI's ray pipeline payload size must equal `Payload` (`max_ray_payload_size`); a bigger payload than declared is a device lost, not a validation error.
- A mesh whose vertices change in place needs `dynamic` and something that says when (`skinning.updated`); nothing else refits.
- Rotate gpu-read per-frame resources by `render.frame_serial`, not the frame number (a blocking wait inside Update can record a second frame with the same number).

## Verifying

- `test/tests/render3d/scene_store.lua` (rows, TLAS, LOD by distance, skinned refit) and `scene_cull.lua` (cull against a cpu reference: frustum, distance, size, LOD, depth pyramid, shadow cascades).
- `draw.ReadBackCull(kind)` / `draw.ReadBackShadowCull` copy the last cull to the host and stall: tests and debugging only. `r_scene_draw_debug` reads it back about once a second for the CULLING tab; `scene_draw_dump` lists drawn rows.
- `ddgi_debug_scene albedo` shows what rays see. `rt_build` is the gpu time scope of the update and build.
- Blocking gpu waits (`render.SubmitAndWait`) exist only outside the per frame path (probe bakes, scene view screenshots, pool setup, terrain bake results).
