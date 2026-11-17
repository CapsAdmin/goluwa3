# Cluster LOD (`goluwa/render3d/cluster_lod/`)

Large static models are drawn as a per frame cut through a hierarchy of triangle clusters, on by default (`r_cluster_lod`). The hierarchy is built on a worker thread (`build.lua` through `thread_pool`, algorithm in `hierarchy.lua`) the first time a polygon is drawn, from its `packed` vertex data. Only polygons that keep packed data qualify (Source 2 models, `.mesh`, cgf), with at least `r_cluster_lod_min_triangles` triangles, and a material that is opaque, not alpha tested, not height mapped and not vertex animated (`cluster_lod.IsMaterialEligible`).

## Hierarchy

- Clusters of up to 128 triangles, groups of up to 16 clusters simplified to half by quadric edge collapse, regrouped across the old group borders each level, until one cluster is left. Cluster triangles index the original vertex buffer (a vertex is a position, normal and uv wedge), nothing is uploaded twice.
- Group borders and mesh borders are locked. A collapse never makes a new edge between two locked vertices (two groups would each make it and the cut would have a four triangle edge). A group that cannot reach 90% of its triangles is stuck and its clusters stay as roots.
- Error is the propagated vertex deviation: the distance of a removed vertex to the new local surface, summed along the merge chain, kept per vertex across levels. Spheres of a parent contain the spheres of its children, so the projected error is monotonic and a cluster is drawn when its own error is under the pixel budget and its parent's is over it. UV and normal deviation gate collapses but are not a reliable bound.
- Seams: simplification runs on position topology with a uv island id per triangle. A vertex may only collapse into one that touches all its islands, so every corner keeps a valid wedge.

## Raster

- `draw.lua`: a polygon in cluster mode keeps one group whose room is rows times leaf clusters; the row cull skips it (group `mesh_row` is `0xFFFFFFFF`), and `scene_cluster_cull` (one thread per row and cluster pair, from `cluster_rows`) writes one indirect command per visible cluster into the same buffers the multi draw already reads. It needs the row's seen stamp of the frame, so it follows the row cull, and it repeats the discrete LOD selection of the row.
- Command space per set is `group_capacity + CLUSTER_COMMANDS`; the cluster pass undoes its count on overflow so the finalize pass cannot write out of its region.
- Shadow maps and the ray traced scene still use the whole mesh unless noted below.

## Ray tracing

- `cluster_lod.BuildCuts` picks up to three cuts of one error value each (a uniform error is always a consistent cut), each at most half the triangles of the previous one, as index buffers over the same vertex buffer. Models that cannot reduce by half get none.
- `bridge.UpdateVisual` adds an ray only row per cut next to the full detail row (`meshes.GetCut`, its own BLAS) and gives the full row `FLAG_RT_LOD`, which makes every raster pass ignore the level fields that only the update pass should use. The ranges are the cut's error projected to `r_cluster_lod_rt_error` pixels at 1080p and 60 degrees, as a ratio of the visual radius like discrete LODs.

## Inspecting

- `r_cluster_lod_debug 1` tints the models drawn through the cluster path green and the ones waiting for their hierarchy yellow (per mesh and material, in `gbuffer_instancing.write_record`; toggling touches the materials so the batch table rewrites them).
- `cluster_lod_why [name part]` lists why meshes are not clustered: a summary by reason, then the 20 biggest unclustered meshes, or every mesh whose name matches. The reasons come from `draw.GetClusterReport`, which checks in the order `get_cluster_state` does.

## Pitfalls

- A cast pointer into a blob does not keep it alive (`ffi.cast` of a local `ffi.new`): hold the blob.
- Do not call `BuildBoundingBox` on a polygon made with `UploadVertexArray`; it rebuilds from the empty `Vertices` table and leaves an invalid box.
- `os.clock()` in a worker counts process cpu time, so the build seconds in the stats are inflated.
- Existing rows do not switch when `r_cluster_lod` changes; set it before loading.
- Tests: `test/tests/render3d/cluster_lod.lua` (builder on the cpu, the cull read back, the traced BLAS by distance).
