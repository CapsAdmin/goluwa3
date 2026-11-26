# Cluster LOD (`goluwa/render3d/cluster_lod/`)

Large static models are drawn as a per frame cut through a hierarchy of triangle clusters (`r_cluster_lod`, on by default). The hierarchy is built on a worker thread (`build.lua` through `thread_pool`, algorithm in `hierarchy.lua`) the first time a polygon is drawn, from its `packed` vertex data. Only polygons that keep packed data qualify (Source 2 models, `.mesh`, cgf), above `r_cluster_lod_min_triangles`, with a material that is opaque, not alpha tested, not height mapped and not vertex animated (`cluster_lod.IsMaterialEligible`). `r_cluster_lod_error` is the one pixel error budget: the raster, the shadow maps and the ray traced scene all take the cut it gives through the camera's projection (`cluster_lod.SetView` once per frame, `cluster_lod_fine_enough` in every selection pass). A shadow caster or traced surface finer than the drawn one lies above it and shadows it in patches the shape of the coarse triangles, so no consumer may use a finer cut than the raster.

A related path, cluster streaming (`scene/cluster_stream.lua`, `cluster_stream/`, `r_cluster_stream*`), draws meshes baked into cluster stream files from streamed cluster pages as a gbuffer extra; rays and shadow maps see a reduced fallback mesh.

## Hierarchy

- Clusters of up to 128 triangles are grouped and simplified to half by quadric edge collapse, regrouped across the old borders each level, until one cluster is left. Cluster triangles index the original vertex buffer, so nothing is uploaded twice.
- Group and mesh borders are locked, and a collapse never creates an edge between two locked vertices, so neighbouring groups always agree on their shared border. Groups that cannot simplify enough stay as roots.
- Error is the propagated vertex deviation, accumulated along the merge chain. Parent bounding spheres contain their children's, so the projected error is monotonic and a cluster is drawn when its own error is under the budget and its parent's is over it. UV and normal deviation gate collapses but are not part of the bound.
- UV seams: simplification runs on position topology with a uv island id per triangle; a vertex may only collapse into one that touches all its islands, so every corner keeps a valid wedge.
- Thin shells: the two sides of a sheet are simplified separately, and once either moves by more than half the gap between them they cross, the inner side poking through the outer one and shadowing it in patches. Each vertex's clearance (the nearest surface of the same mesh facing the other way, along its normal, within a few cells of a triangle grid) bounds how far a collapse may move it.
- A group that cannot simplify is retried with looser rules: first open edges no other group or chunk shares may collapse and attribute tolerances widen, then uv seams are ignored too. The error stays the measured position deviation.

## Cluster streaming

- A group is the unit of residency: its clusters load and unload together and are replaced all at once by the coarser clusters it was simplified into, when its error at its sphere is under the budget. A group links to the groups holding those coarser clusters, which must be resident before it is.
- A cluster carries its own error (from the group it was simplified from, `gen`, or -1 at the finest stored level) besides the bounds it is culled by.
- Every level together with the root groups below it is a whole watertight mesh; the fallback mesh rays and shadow maps see is the finest such level within the fallback triangle budget.
- Groups are split into a node tree of small spatial leaves. A node's sphere bounds its groups' spheres and its error is their largest, so a node whose error projects under the budget has no group that draws, and the per frame cpu walk stops there. The walk emits a superset of candidates and the cull pass decides exactly.

## Raster

- `scene/draw.lua`: a polygon in cluster mode has one group that the row cull skips; `scene_cluster_cull` (one thread per row and cluster) writes one indirect command per visible cluster into the buffers the multi draw already reads. It follows the row cull because it needs the row's seen stamp, and it repeats the row's discrete LOD choice.
- Command space per set is `group_capacity + CLUSTER_COMMANDS`; the cluster pass undoes its count on overflow so the finalize pass cannot write out of its region.
- Shadow maps cast the same cut (`scene_shadow_cluster_cull`, after the shadow finalize, one command per cluster), not the whole mesh. Clusters behind the camera, which only cast shadows or get traced, take the cut by distance. Cascades that are not redrawn every frame keep the cut of the frame they were drawn in.

## Ray tracing

- With `VK_NV_cluster_acceleration_structure` (`r_rt_clusters`, `scene/cluster_rt.lua`) every cluster is built once as a cluster acceleration structure, and each frame `cluster_rt_select` picks the raster's cut per instance (the same error test, without the frustum test, since rays come from everywhere) and builds one BLAS per instance from it.
- The cluster id is the cluster's first triangle in the index pool, so `scene_query_primitive` (`hit.lua`) turns a hit into a pool triangle and the instance's cluster mesh row (`meshes.GetClusterRow`). Every place that reads a hit's primitive must use `scene_query_primitive`.
- Without the extension, `cluster_lod.BuildCuts` makes a few uniform-error cuts as index buffers over the same vertices, and `bridge.UpdateVisual` adds a ray only row per cut (`meshes.GetCut`) beside the full detail row, which gets `FLAG_RT_LOD` so raster passes ignore the ray-only level fields. These cuts switch by distance at a reference projection, so they only approximate the raster's cut.
- Bending materials keep the fixed cuts, since their BLAS copies are bent per frame.

## Inspecting

- `r_cluster_lod_debug 1` tints models drawn through the cluster path green and ones waiting for their hierarchy yellow.
- `cluster_lod_why [name part]` lists why meshes are not clustered (from `draw.GetClusterReport`).
- Test: `test/tests/render3d/cluster_lod.lua` (cpu builder, cull readback, traced BLAS by distance).

## Pitfalls

- A cast pointer into a blob does not keep it alive (`ffi.cast` of a local `ffi.new`): hold the blob.
- Do not call `BuildBoundingBox` on a polygon made with `UploadVertexArray`; it rebuilds from the empty `Vertices` table.
- `os.clock()` in a worker counts process cpu time, so build seconds in the stats are inflated.
- Existing rows do not switch when `r_cluster_lod` changes; set it before loading.
