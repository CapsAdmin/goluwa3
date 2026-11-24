# Cluster LOD (`goluwa/render3d/cluster_lod/`)

Large static models are drawn as a per frame cut through a hierarchy of triangle clusters (`r_cluster_lod`, on by default). The hierarchy is built on a worker thread (`build.lua` through `thread_pool`, algorithm in `hierarchy.lua`) the first time a polygon is drawn, from its `packed` vertex data. Only polygons that keep packed data qualify (Source 2 models, `.mesh`, cgf), above `r_cluster_lod_min_triangles`, with a material that is opaque, not alpha tested, not height mapped and not vertex animated (`cluster_lod.IsMaterialEligible`). `r_cluster_lod_error` is the raster pixel error budget, `r_cluster_lod_rt_error` the ray tracing one.

A related path, cluster streaming (`scene/cluster_stream.lua`, `cluster_stream/`, `r_cluster_stream*`), draws meshes baked into cluster stream files from streamed cluster pages as a gbuffer extra; rays and shadow maps see a reduced fallback mesh.

## Hierarchy

- Clusters of up to 128 triangles are grouped and simplified to half by quadric edge collapse, regrouped across the old borders each level, until one cluster is left. Cluster triangles index the original vertex buffer, so nothing is uploaded twice.
- Group and mesh borders are locked, and a collapse never creates an edge between two locked vertices, so neighbouring groups always agree on their shared border. Groups that cannot simplify enough stay as roots.
- Error is the propagated vertex deviation, accumulated along the merge chain. Parent bounding spheres contain their children's, so the projected error is monotonic and a cluster is drawn when its own error is under the budget and its parent's is over it. UV and normal deviation gate collapses but are not part of the bound.
- UV seams: simplification runs on position topology with a uv island id per triangle; a vertex may only collapse into one that touches all its islands, so every corner keeps a valid wedge.

## Raster

- `scene/draw.lua`: a polygon in cluster mode has one group that the row cull skips; `scene_cluster_cull` (one thread per row and cluster) writes one indirect command per visible cluster into the buffers the multi draw already reads. It follows the row cull because it needs the row's seen stamp, and it repeats the row's discrete LOD choice.
- Command space per set is `group_capacity + CLUSTER_COMMANDS`; the cluster pass undoes its count on overflow so the finalize pass cannot write out of its region.
- Shadow maps use the whole mesh.

## Ray tracing

- With `VK_NV_cluster_acceleration_structure` (`r_rt_clusters`, `scene/cluster_rt.lua`) every cluster is built once as a cluster acceleration structure, and each frame `cluster_rt_select` picks a cut per instance by projected error at the ray tracing budget (distance only, no frustum, since rays come from everywhere) and builds one BLAS per instance from it.
- The cluster id is the cluster's first triangle in the index pool, so `scene_query_primitive` (`hit.lua`) turns a hit into a pool triangle and the instance's cluster mesh row (`meshes.GetClusterRow`). Every place that reads a hit's primitive must use `scene_query_primitive`.
- Without the extension, `cluster_lod.BuildCuts` makes a few uniform-error cuts as index buffers over the same vertices, and `bridge.UpdateVisual` adds a ray only row per cut (`meshes.GetCut`) beside the full detail row, which gets `FLAG_RT_LOD` so raster passes ignore the ray-only level fields.
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
