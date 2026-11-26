# The scene store (`goluwa/render3d/scene/`)

The gpu-side description of the world. Ray queries (GI, reflections, glass, fog, light occlusion, particle collision, scatter) trace against it, and the main view and sun shadow maps cull and draw from it. Nothing on the draw path reads back from the gpu. `gpu_culling.lua` holds only what culling shares (`r_feature_culling`, the last depth pyramid, `ExtractFrustumPlanes`).

## Parts

Meshes have their own bottom level acceleration structure, instances point at them, and hit shaders read everything from the same tables.

- `store.lua`: row tables in persistently mapped buffers with a free list. Tables the cpu rewrites every frame are **staged**: the cpu writes a host copy and calls `Touch(row)`, and `store.FlushStaged(cmd)` copies touched rows to device memory outside a render pass. Writing a staged table without `Touch` leaves the gpu with the old row.
- `meshes.lua`: one row per `Mesh` (vertex, extras, index and BLAS addresses), created on demand by `meshes.Get(mesh, dynamic)`; BLASes are built in `accel.lua`. A `dynamic` mesh is refit in the frame skinning changed it.
- `instances.lua`: the TLAS records and the per instance shader data share an index. `Build(cmd)` builds waiting BLASes, runs the gpu update pass (visibility by flag, mask, `r_rt_distance`, LOD via `r_rt_lod_scale`/`lod_level`, deformed copies) and builds the TLAS. `rt.GetTLAS(cmd)` does this once a frame from `render3d.lua`, after `UpdateScene` and skinning, before any pass records.
- `bridge.lua`: fed by `visual.lua`. A visual is one instance per render entry of every LOD, with ray mask and flags from its material. It also serves dirty boxes, scene bounds (DDGI volume) and emissive instances; `emitters.lua` builds the emitter cdf on the gpu.
- `parts.lua`, `materials.lua`, `ray_materials.lua`: shared per (mesh, material) state and the material tables hit shaders read. A part (one per mesh and material, and per polygon for bending materials) is what rays trace: the mesh row of its BLAS (an opacity micromap variant when it has one) and its bend pool. Instances refer to it by id, so changing either is one row write.
- `hit.lua`: the one place that reads a hit (`scene_hit_tri`, `scene_hit_uv`, `scene_instance_material`, `scene_query_primitive`). `GetTraceGLSL(tlas)` gives `scene_trace`/`scene_occluded` for passes that do not shade the hit, with stubs when ray queries are unavailable. Passes declare `hit.GetDescriptorSets(...)` and call `hit.Bind` every frame.
- `draw.lua`: the main view and shadow cull and draw (below). `visibility.lua` estimates which drawn rows are visible by tracing from the camera.
- Related: `deformed_copies.lua` (wind bent BLAS copies, see [foliage.md](foliage.md)), `opacity_micromaps.lua` ([vulkan-raytrace.md](vulkan-raytrace.md)), `cluster_rt.lua` ([cluster-lod.md](cluster-lod.md)), `tessellation.lua` ([tessellation.md](tessellation.md)), `software_raster.lua` ([render3d-pipeline.md](render3d-pipeline.md)).

Visuals with `InSceneBVH = false` are drawn but not traced; `RaysOnly` visuals are traced but not drawn; `ViewHidden` visuals are traced and cast shadows but are not drawn in the gbuffer (a first person head). Without ray queries nothing is built and shaders use stubs; `GOLUWA_NO_RAY_TRACING=1` tests this.

## Drawing from the store

- `draw.Cull` runs one thread per drawn row (distance, frustum, screen size, depth pyramid occlusion, LOD with dither fade) and writes world and previous world matrices into its group's slots; a finalize writes one indexed indirect draw per group (mesh and material) plus a `draw_groups` table, so the vertex stage finds the batch by `gl_DrawID`. `draw.Draw` draws each set (pipeline variant, single/double sided) with one `DrawIndexedIndirectCount`.
- The cull stamps rows it sees (`instances.GetSeenTable`); the ray tracing update traces rows not seen last frame at a coarser LOD (`r_rt_culled_lod_scale`), never removing them.
- Translucent rows get their own cull kind; `draw.DrawTranslucent` draws them with multi draw twins of the translucent passes.
- Sun shadow cascades cull rows with `RASTER_SHADOW` right before drawing (`draw.CullShadow`) into shared buffers, so a grown buffer is retired a few frames later because an earlier cascade in the same unsubmitted command buffer may still read it.
- **Streams** (`draw.CreateStream`, `ResizeStream`, `RemoveStream`): instances a gpu producer writes every frame (scatter), which cannot be cpu rows. A producer calls `draw.BeginStreams(cmd)` on `PreSceneBuild`, appends with `scene_stream_append` from `draw.STREAM_GLSL` (view list and shadow list), then `draw.EndStreams(cmd)`. After the cull, streams share everything with rows (finalize, variants, visibility buffer routing, batch table, velocity). Layout changes must happen before `BeginStreams` in a frame. `GetStreamDemand` and `GetStreamStats` help with sizing.
- **Traced buffers**: shaders reading instance rows by id use the tables as they were at this frame's TLAS build (`instances.GetTracedBuffers`). Instances can be added later in the frame (cluster hierarchies finishing, loads), and their rows are not in those buffers, so a CPU built id list that the gpu reads against them (the emitter list) must skip ids `instances.IsTraced` rejects; reading one reads an unwritten row, mesh row 0 and a null vertex address.
- **Produced rows** (`traced = true` streams, `FLAG_PRODUCED`, `r_rt_streams`, `r_rt_stream_distance`): `EndStreams` writes ray traced rows for stream instances on the gpu, visible only in the frame they were written. A producer must not ask for this frame's TLAS itself (use `rt.GetBuiltTLAS`, the last build): that builds the scene before its rows exist.
- The cpu still draws entries without gpu buffers (`bridge.GetCPUDrawnVisuals`), everything when the store did not cull the frame (several cameras, scene views, `visual.noculling`), ignore-z materials and `particle_emitter_cpu`.
- A row's cull box is its own mesh's box (`bridge.GetEntryBox`), not the visual's: a map is one visual with many parts and its box would always contain the camera.

## Rules

- An instance mask is one surface kind (`MASK_SOLID`, `MASK_SEE_THROUGH`, `MASK_DECAL`, plus `MASK_SELF`/`MASK_GLASS`) with GI bits on top. A ray that skips a kind builds its cull mask from the kinds it keeps (`instances.MASK_SURFACES`), never all bits minus one kind, since the GI bits are on every kind.
- Everything the gpu reads of a row must stay valid for frames in flight: freed rows are zeroed only after `RETIRE_FRAMES`, buffer releases are deferred by submission serial, grown tables keep the old buffer a few frames. A ray reading a zeroed mesh row reads address 0 and loses the device.
- Build the TLAS outside a render pass and before the passes that trace.
- A ray pipeline's payload size must match `max_ray_payload_size`; a larger payload than declared is a device lost, not a validation error.
- A mesh whose vertices change in place needs `dynamic` and an update signal (`skinning.updated`). Procedural deformation (wind) traces against deformed copies chosen on the gpu; all deformed BLAS refits go through `accel.QueueRefit`.
- Buffer references assume 16 byte aligned bases; a misaligned table reads garbage, not an error.
- Rotate gpu-read per-frame resources by `render.frame_serial`, not the frame number.
- Blocking gpu waits (`render.SubmitAndWait`) only exist outside the per frame path.

## Verifying

- `test/tests/render3d/scene_store.lua` (rows, TLAS, LOD, skinned refit) and `scene_cull.lua` (cull against a cpu reference, including shadow cascades).
- `draw.ReadBackCull(kind)` / `draw.ReadBackShadowCull` copy the last cull to the host and stall (tests and debugging only). `r_scene_draw_debug` feeds the CULLING tab; `scene_draw_dump` lists drawn rows.
- `radiance_cache_debug_scene albedo` shows what rays see. `rt_build` is the gpu scope of the update and build.
