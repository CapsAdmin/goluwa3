local T = import("test/environment.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local cluster_rt = import("goluwa/render3d/scene/cluster_rt.lua")
local ffi = require("ffi")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local build = import("goluwa/render3d/cluster_lod/build.lua")
local format = import("goluwa/render3d/cluster_lod/format.lua")
local Record = ffi.typeof("$ *", format.ClusterRecord)
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local cluster_lod = import("goluwa/render3d/cluster_lod/cluster_lod.lua")
local threads = import("goluwa/bindings/threads.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vk = import("goluwa/bindings/vk.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local PIXELS_PER_RADIAN = 1080 / (2 * math.tan(math.rad(60) / 2))

local function icosphere(subdivisions, bend)
	local t = (1 + math.sqrt(5)) / 2
	local px = {-1, 1, -1, 1, 0, 0, 0, 0, t, t, -t, -t}
	local py = {t, t, -t, -t, -1, 1, -1, 1, 0, 0, 0, 0}
	local pz = {0, 0, 0, 0, t, t, -t, -t, -1, 1, -1, 1}
	local faces = {
		0,
		11,
		5,
		0,
		5,
		1,
		0,
		1,
		7,
		0,
		7,
		10,
		0,
		10,
		11,
		1,
		5,
		9,
		5,
		11,
		4,
		11,
		10,
		2,
		10,
		7,
		6,
		7,
		1,
		8,
		3,
		9,
		4,
		3,
		4,
		2,
		3,
		2,
		6,
		3,
		6,
		8,
		3,
		8,
		9,
		4,
		9,
		5,
		2,
		4,
		11,
		6,
		2,
		10,
		8,
		6,
		7,
		9,
		8,
		1,
	}

	for i = 1, 12 do
		local l = math.sqrt(px[i] ^ 2 + py[i] ^ 2 + pz[i] ^ 2)
		px[i], py[i], pz[i] = px[i] / l, py[i] / l, pz[i] / l
	end

	for _ = 1, subdivisions do
		local cache, next_faces = {}, {}

		local function middle(a, b)
			local key = math.min(a, b) * 4194304 + math.max(a, b)

			if cache[key] then return cache[key] end

			local x, y, z = px[a + 1] + px[b + 1], py[a + 1] + py[b + 1], pz[a + 1] + pz[b + 1]
			local l = math.sqrt(x * x + y * y + z * z)
			px[#px + 1], py[#py + 1], pz[#pz + 1] = x / l, y / l, z / l
			cache[key] = #px - 1
			return #px - 1
		end

		for f = 1, #faces, 3 do
			local a, b, c = faces[f], faces[f + 1], faces[f + 2]
			local ab, bc, ca = middle(a, b), middle(b, c), middle(c, a)

			for _, v in ipairs{a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca} do
				next_faces[#next_faces + 1] = v
			end
		end

		faces = next_faces
	end

	local vertices = vertex_layout.ArrayType(#px)

	for i = 0, #px - 1 do
		local x, y, z = px[i + 1], py[i + 1], pz[i + 1]
		local r = 1 + 0.06 * math.sin(5 * x + 1) * math.cos(4 * y) * math.sin(6 * z)
		local v = vertices[i]
		v.position[0], v.position[1], v.position[2] = x * r, y * r, z * r
		v.normal[0], v.normal[1], v.normal[2] = x, y, z
		v.uv[0], v.uv[1] = x * 0.5 + 0.5, y * 0.5 + 0.5

		if bend then
			v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = 0.5, y * 0.5 + 0.5, 1 - math.abs(y), 1
			v.pivot[0], v.pivot[1], v.pivot[2], v.pivot[3] = x > 0 and 0.4 or -0.4, 0, 0, 1
		end
	end

	local indices = ffi.new("uint32_t[?]", #faces)

	for i = 1, #faces do
		indices[i - 1] = faces[i]
	end

	return vertices, #px, indices, #faces
end

local function run_build(subdivisions, bend)
	local vertices, vertex_count, indices, index_count = icosphere(subdivisions, bend)
	local meta, blob = build.Build{
		vertices = ffi.string(vertices, vertex_count * vertex_layout.Stride),
		vertex_count = vertex_count,
		indices = ffi.string(indices, index_count * 4),
		index_count = index_count,
		index_size = 4,
	}
	return meta,
	ffi.cast(Record, blob),
	ffi.cast("uint32_t *", blob + meta.cluster_count * format.RECORD_SIZE),
	vertex_count,
	index_count / 3,
	blob
end

local function select_cut(records, count, camera_x, threshold)
	local cut = {}

	for i = 0, count - 1 do
		local r = records[i]
		local dx = r.lod[0] - camera_x
		local d = math.max(math.sqrt(dx * dx + r.lod[1] ^ 2 + r.lod[2] ^ 2) - r.lod[3], 1e-9)
		local draw = r.error * PIXELS_PER_RADIAN / d <= threshold

		if draw and r.parent_error < format.NO_PARENT_ERROR then
			local px = r.parent[0] - camera_x
			local pd = math.max(math.sqrt(px * px + r.parent[1] ^ 2 + r.parent[2] ^ 2) - r.parent[3], 1e-9)
			draw = r.parent_error * PIXELS_PER_RADIAN / pd > threshold
		end

		if draw then cut[#cut + 1] = i end
	end

	return cut
end

local function open_edges(records, indices, cut, vertex_count)
	local counts, triangles = {}, 0

	for _, i in ipairs(cut) do
		local r = records[i]

		for t = 0, r.index_count / 3 - 1 do
			triangles = triangles + 1
			local a, b, c = indices[r.first_index + t * 3],
			indices[r.first_index + t * 3 + 1],
			indices[r.first_index + t * 3 + 2]

			for _, e in ipairs{{a, b}, {b, c}, {c, a}} do
				local key = math.min(e[1], e[2]) * vertex_count + math.max(e[1], e[2])
				counts[key] = (counts[key] or 0) + 1
			end
		end
	end

	local open = 0

	for _, n in pairs(counts) do
		if n ~= 2 then open = open + 1 end
	end

	return open, triangles
end

T.Test("cluster lod builds a hierarchy whose leaves are the whole mesh", function()
	local meta, records, indices, vertex_count, triangles, blob = run_build(4)
	local leaf_triangles, roots = 0, 0

	for i = 0, meta.cluster_count - 1 do
		local r = records[i]
		T(r.index_count > 0 and r.index_count <= 128 * 3)["=="](true)
		T(r.first_index + r.index_count <= meta.index_count)["=="](true)
		T(r.bounds[3] > 0)["=="](true)

		if r.parent_error >= format.NO_PARENT_ERROR then
			roots = roots + 1
		else
			T(r.parent_error > r.error)["=="](true)
		end
	end

	for i = 0, meta.index_count - 1 do
		T(indices[i] < vertex_count)["=="](true)
	end

	for _, i in ipairs(select_cut(records, meta.cluster_count, 1e9, 0)) do
		leaf_triangles = leaf_triangles + records[i].index_count / 3
	end

	T(roots >= 1)["=="](true)
	T(ffi.sizeof(blob) > 0)["=="](true)
	T(leaf_triangles)["=="](triangles)
	T(meta.levels > 3)["=="](true)
end)

T.Test("cluster lod cuts stay watertight and shrink with distance", function()
	local meta, records, indices, vertex_count, triangles, blob = run_build(5)
	local previous = math.huge

	for _, distance in ipairs{1.3, 2.5, 6, 20, 80} do
		local cut = select_cut(records, meta.cluster_count, distance, 1)
		local open, cut_triangles = open_edges(records, indices, cut, vertex_count)
		T(open)["=="](0)
		T(cut_triangles <= previous)["=="](true)
		previous = cut_triangles
	end

	T(previous < triangles / 20)["=="](true)
	local near = select_cut(records, meta.cluster_count, 1.3, 0.01)
	local _, near_triangles = open_edges(records, indices, near, vertex_count)
	T(near_triangles)["=="](triangles)
	T(ffi.sizeof(blob) > 0)["=="](true)
end)

T.Test3D("Graphics render3d cluster lod draws a cut of a large model that follows the camera", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(1000)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local vertices, vertex_count, indices, index_count = icosphere(6)
	local indices16 = ffi.new("uint16_t[?]", index_count)

	for i = 0, index_count - 1 do
		indices16[i] = indices[i]
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices16, index_count, true)
	local entity = Entity.New{Name = "cluster_lod_sphere"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -3))
	local visual = entity:AddComponent("visual")
	visual:SetUseOcclusionCulling(false)
	local primitive = Entity.New{Name = "cluster_lod_sphere_primitive", Parent = entity}
	primitive:AddComponent("transform")
	primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
	primitive.visual_primitive:SetMaterial(Material.New())
	visual:BuildAABB()
	local started = system.GetTime()

	while not cluster_lod.GetState(polygon) do
		thread_pool.Update()
		draw()
		threads.sleep(5)
		T(system.GetTime() - started < 25)["=="](true)
	end

	for _ = 1, 4 do
		draw()
	end

	local full = index_count / 3
	local near = scene_draw.ReadBackCull(0)
	local stats = scene_draw.GetClusterStats()
	T(stats.rows)["=="](1)
	T(stats.pairs)["=="](cluster_lod.GetState(polygon).count)
	T(near.commands > 1)["=="](true)
	T(near.triangles <= full)["=="](true)
	T(near.triangles < full / 2)["=="](true)
	T(near.triangles > full / 100)["=="](true)
	entity.transform:SetPosition(Vec3(0, 0, -300))

	for _ = 1, 4 do
		draw()
	end

	local far = scene_draw.ReadBackCull(0)
	T(far.commands >= 1)["=="](true)
	T(far.triangles < near.triangles / 4)["=="](true)
	T(far.triangles >= 1)["=="](true)
	entity:Remove()
end)

local function read_traced_blas(ids)
	local tlas = instances.GetTables()
	local bytes = tlas.count * 64
	local destination = render.CreateBuffer{
		byte_size = bytes,
		buffer_usage = {"transfer_dst"},
		memory_property = {"host_visible", "host_coherent"},
		label = "cluster_lod_readback",
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local region = ffi.new(ffi.typeof("$[1]", vk.VkBufferCopy))
	region[0].size = bytes
	cmd:CopyBuffer(tlas:GetBuffer(), destination, region, 1)
	cmd:End()
	render.SubmitAndWait(cmd)
	local words = ffi.cast("uint32_t *", destination:Map())
	local traced = {}

	for _, id in ipairs(ids) do
		traced[id] = tonumber(words[id * 16 + 14]) + tonumber(words[id * 16 + 15]) * 4294967296
	end

	destination:Remove()
	return traced
end

local function trace_hit_plane_distance()
	local hit = import("goluwa/render3d/scene/hit.lua")
	local results = render.CreateBuffer{
		byte_size = 16,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "cluster_lod_trace_results",
	}
	local descriptor_sets = {
		{type = "acceleration_structure_khr", binding_index = 1, stageFlags = "compute"},
	}

	for _, set in ipairs(hit.GetDescriptorSets(2, "compute")) do
		descriptor_sets[#descriptor_sets + 1] = set
	end

	local pipeline = EasyPipeline.Compute{
		name = "cluster_lod_test_trace",
		DescriptorSetCount = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}},
		descriptor_sets = descriptor_sets,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) buffer Results { float results[]; };
			layout(set = 0, binding = 1) uniform accelerationStructureEXT scene;
		]] .. hit.GetGLSL(2),
		shader = [[
			void main() {
				rayQueryEXT query;
				vec3 dir = normalize(vec3(0.1, 0.05, -1.0));
				rayQueryInitializeEXT(query, scene, gl_RayFlagsOpaqueEXT, 0xFF, vec3(0.0), 0.0, dir, 100.0);
				while (rayQueryProceedEXT(query)) {}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
					results[0] = 0.0;
					return;
				}

				uint instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				scene_triangle tri = scene_hit_tri(instance, scene_query_primitive(query, true));
				float t = rayQueryGetIntersectionTEXT(query, true);
				results[0] = 1.0;
				results[1] = abs(dot(dir * t - tri.v0, tri.normal));
				results[2] = t;
			}
		]],
	}
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, results, results:GetSize())
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", 1, 1, 0, instances.tlas)
	hit.Bind(pipeline, 1, 2)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
	pipeline.pipeline:Dispatch(cmd, 1, 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("float *", results:Map())
	local hit_found, plane_distance, distance = out[0], out[1], out[2]
	results:Remove()
	pipeline:Remove()
	return hit_found == 1, plane_distance, distance
end

T.Test3DRayTracing("Graphics render3d cluster lod traces a coarser cut of a large model with distance", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(1000)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local vertices, vertex_count, indices, index_count = icosphere(6)
	local indices16 = ffi.new("uint16_t[?]", index_count)

	for i = 0, index_count - 1 do
		indices16[i] = indices[i]
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices16, index_count, true)
	local entity = Entity.New{Name = "cluster_lod_rt_sphere"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -3))
	local visual = entity:AddComponent("visual")
	visual:SetUseOcclusionCulling(false)
	local primitive = Entity.New{Name = "cluster_lod_rt_sphere_primitive", Parent = entity}
	primitive:AddComponent("transform")
	primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
	primitive.visual_primitive:SetMaterial(Material.New())
	visual:BuildAABB()
	local started = system.GetTime()

	if cluster_rt.IsEnabled() then
		while not (cluster_lod.GetState(polygon) and cluster_rt.GetStats().instances > 0) do
			thread_pool.Update()
			draw()
			threads.sleep(5)
			T(system.GetTime() - started < 25)["=="](true)
		end

		local id = visual.scene_instances[1].id
		T(#visual.scene_instances)["=="](1)

		local function selected()
			for _ = 1, 6 do
				draw()
			end

			return cluster_rt.ReadSelectedCounts()[id]
		end

		pvars.SetSession("r_cluster_lod_rt_error", 0.0001)
		local near = selected()
		T(read_traced_blas({id})[id] ~= 0)["=="](true)
		local hit_found, plane_distance, distance = trace_hit_plane_distance()
		T(hit_found)["=="](true)
		T(plane_distance < 0.001)["=="](true)
		T(distance > 1 and distance < 3.1)["=="](true)
		pvars.SetSession("r_cluster_lod_rt_error", 2)
		entity.transform:SetPosition(Vec3(0, 0, -300))
		local far = selected()
		T(far > 0)["=="](true)
		T(far < near)["=="](true)
		T(read_traced_blas({id})[id] ~= 0)["=="](true)
		entity:Remove()
		return
	end

	while not (cluster_lod.GetState(polygon) and #visual.scene_instances > 1) do
		thread_pool.Update()
		draw()
		threads.sleep(5)
		T(system.GetTime() - started < 25)["=="](true)
	end

	local state = cluster_lod.GetState(polygon)
	local list = visual.scene_instances
	T(#list)["=="](#state.cuts + 1)
	local ids = {}

	for i, item in ipairs(list) do
		ids[i] = item.id
	end

	local function traced_rows()
		for _ = 1, 6 do
			draw()
		end

		local traced = read_traced_blas(ids)
		local rows = meshes.GetTable():Get()
		local live = {}

		for i, item in ipairs(list) do
			live[i] = traced[item.id] ~= 0 and
				traced[item.id] == tonumber(rows[item.mesh_row].blas_address)
		end

		return live
	end

	pvars.SetSession("r_cluster_lod_rt_error", 0.0001)
	local near = traced_rows()
	T(near[1])["=="](true)

	for i = 2, #list do
		T(near[i])["=="](false)
	end

	pvars.SetSession("r_cluster_lod_rt_error", 2)
	entity.transform:SetPosition(Vec3(0, 0, -300))
	local far = traced_rows()
	T(far[1])["=="](false)
	local coarse = 0

	for i = 2, #list do
		if far[i] then coarse = coarse + 1 end
	end

	T(coarse)["=="](1)
	entity:Remove()
end)

T.Test3DRayTracing("Graphics render3d cluster lod keeps an emissive model on its own mesh row for the emitters", function(draw)
	if not cluster_rt.IsEnabled() then return end

	local emitters = import("goluwa/render3d/scene/emitters.lua")
	local Texture = import("goluwa/render/texture.lua")
	local Color = import("goluwa/structs/color.lua")
	local vertices, vertex_count, indices, index_count = icosphere(6)
	local indices16 = ffi.new("uint16_t[?]", index_count)

	for i = 0, index_count - 1 do
		indices16[i] = indices[i]
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices16, index_count, true)
	local material = Material.New()
	material:SetEmissiveTexture(Texture.GetFallback())
	material:SetEmissiveMultiplier(Color(1, 1, 1, 1))
	local entity = Entity.New{Name = "cluster_lod_emissive_sphere"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -3))
	local visual = entity:AddComponent("visual")
	visual:SetUseOcclusionCulling(false)
	local primitive = Entity.New{Name = "cluster_lod_emissive_sphere_primitive", Parent = entity}
	primitive:AddComponent("transform")
	primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
	primitive.visual_primitive:SetMaterial(material)
	visual:BuildAABB()
	local started = system.GetTime()

	while not (cluster_lod.GetState(polygon) and cluster_rt.IsReady(polygon)) do
		thread_pool.Update()
		draw()
		threads.sleep(5)
		T(system.GetTime() - started < 25)["=="](true)
	end

	for _ = 1, 4 do
		draw()
	end

	local row = meshes.Get(polygon.mesh)
	T(visual.scene_instances[1].mesh_row)["=="](row)
	local list = emitters.Get(true)
	local found = false

	for _, source in ipairs(list.sources) do
		if source.instance == visual.scene_instances[1].id then
			found = source.triangle_count == meshes.GetRecord(row).triangle_count
		end
	end

	T(found)["=="](true)
	entity:Remove()
end)

T.Test("cluster lod keeps bending vertices of different stiffness and pivot apart", function()
	local plain_meta, plain_records, plain_indices, vertex_count, triangles, plain_blob = run_build(5, false)
	local bend_meta, bend_records, bend_indices, _, _, bend_blob = run_build(5, true)
	T(bend_meta.bend)["=="](true)
	T(plain_meta.bend)["=="](false)
	local plain_cut = select_cut(plain_records, plain_meta.cluster_count, 80, 1)
	local bend_cut = select_cut(bend_records, bend_meta.cluster_count, 80, 1)
	local open, bend_triangles = open_edges(bend_records, bend_indices, bend_cut, vertex_count)
	local _, plain_triangles = open_edges(plain_records, plain_indices, plain_cut, vertex_count)
	T(open)["=="](0)
	T(bend_triangles >= plain_triangles)["=="](true)
	T(bend_triangles < triangles)["=="](true)
	T(ffi.sizeof(plain_blob) + ffi.sizeof(bend_blob) > 0)["=="](true)
end)

T.Test3D("Graphics render3d cluster lod takes alpha tested bending plants too", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(60))
	camera:SetNearZ(0.1)
	camera:SetFarZ(1000)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local vertices, vertex_count, indices, index_count = icosphere(6, true)
	local indices16 = ffi.new("uint16_t[?]", index_count)

	for i = 0, index_count - 1 do
		indices16[i] = indices[i]
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices16, index_count, true)
	polygon:SetBendHeight(2)
	local material = Material.New()
	material:SetAlphaTest(true)
	material:SetBending(1)
	local entity = Entity.New{Name = "cluster_lod_plant"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -3))
	local visual = entity:AddComponent("visual")
	visual:SetUseOcclusionCulling(false)
	local primitive = Entity.New{Name = "cluster_lod_plant_primitive", Parent = entity}
	primitive:AddComponent("transform")
	primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
	primitive.visual_primitive:SetMaterial(material)
	visual:BuildAABB()
	local started = system.GetTime()

	while not cluster_lod.GetState(polygon) do
		thread_pool.Update()
		draw()
		threads.sleep(5)
		T(system.GetTime() - started < 25)["=="](true)
	end

	for _ = 1, 4 do
		draw()
	end

	T(scene_draw.GetClusterStats().rows)["=="](1)
	local result = scene_draw.ReadBackCull(0)
	T(result.commands > 1)["=="](true)
	T(result.triangles < index_count / 3)["=="](true)
	local record = cluster_lod.GetState(polygon)
	T(record.count > 0)["=="](true)
	entity:Remove()
end)
