local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local RESULT_COUNT = 8

local function trace(tlas, cmd, results, origin)
	origin = origin or {0, 0, 0}
	local pipeline = EasyPipeline.Compute{
		name = "scene_store_test_trace",
		DescriptorSetCount = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}},
		descriptor_sets = {
			{type = "acceleration_structure_khr", binding_index = 1, stageFlags = "compute"},
		},
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) buffer Results { uint results[]; };
			layout(set = 0, binding = 1) uniform accelerationStructureEXT scene;
		]],
		shader = ([[
			void trace(int slot, vec3 dir) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene, gl_RayFlagsOpaqueEXT, 0xFF, vec3(%f, %f, %f), 0.0, dir, 100.0);
				while (rayQueryProceedEXT(query)) {}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
					results[slot * 4] = 0u;
					return;
				}

				results[slot * 4] = 1u;
				results[slot * 4 + 1] = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				results[slot * 4 + 2] = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
				results[slot * 4 + 3] = floatBitsToUint(rayQueryGetIntersectionTEXT(query, true));
			}

			void main() {
				trace(0, vec3(0.0, 0.0, -1.0));
				trace(1, vec3(0.0, 1.0, 0.0));
			}
		]]):format(origin[1], origin[2], origin[3]),
	}
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, results, results:GetSize())
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", 1, 1, 0, tlas)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipeline.pipeline:Dispatch(cmd, 1, 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
end

T.Test3D("Graphics render3d scene store traces an instance of a mesh through its own blas", function()
	if not render.GetDevice().ray_query_supported then return end

	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 1)
	cube:BuildBoundingBox()
	cube:Upload()
	local row = meshes.Get(cube.mesh)
	T(row ~= nil)["=="](true)
	T(meshes.Get(cube.mesh))["=="](row)
	local matrix = Matrix44()
	matrix:Translate(0, 0, -4)
	local first = instances.Add(row, 0, matrix, instances.MASK_SOLID, 0)
	local second = instances.Add(row, 0, Matrix44():Translate(0, 0, -20), instances.MASK_SOLID, 0)
	local results = render.CreateBuffer{
		byte_size = RESULT_COUNT * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_store_test_results",
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local tlas = instances.Build(cmd)
	trace(tlas, cmd, results)
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("uint32_t*", results:Map())
	local t = ffi.new("uint32_t[1]", out[3])
	T(out[0])["=="](1)
	T(out[1])["=="](first)
	T(out[2] < 12)["=="](true)
	local distance = ffi.cast("float*", t)[0]
	T(distance > 2.9 and distance < 4.1)["=="](true)
	T(out[4])["=="](0)
	instances.Remove(first)
	instances.Remove(second)
	results:Remove()
end)

T.Test3D("Graphics render3d scene store keeps the free rows of a producer's range together", function()
	if not render.GetDevice().ray_query_supported then return end

	local tlas_table = instances.GetTables()
	local first = instances.Add(0, 0, Matrix44(), instances.MASK_SOLID, 0)
	local base_count = tlas_table.count
	local spans = {}
	local range = instances.AllocRange(10000)
	T(range)["=="](base_count)
	T(tlas_table.count)["=="](base_count + 10000)
	instances.FreeRange(range, 10000, true)
	T(tlas_table.count)["=="](base_count)
	range = instances.AllocRange(10000)
	local second = instances.Add(0, 0, Matrix44(), instances.MASK_SOLID, 0)
	T(second)["=="](base_count + 10000)
	instances.FreeRange(range, 10000, true)
	T(tlas_table.count)["=="](base_count + 10001)
	local rows, span_count = tlas_table:GetSpans(spans)
	T(span_count)["=="](2)
	T(rows)["=="](base_count + 1)
	T(spans[1])["=="](0)
	T(spans[2])["=="](base_count)
	T(spans[3])["=="](base_count + 10000)
	T(spans[4])["=="](1)
	local small = instances.AllocRange(3000)
	T(small)["=="](base_count)
	local other = instances.AllocRange(3000)
	T(other)["=="](base_count + 3000)
	instances.FreeRange(other, 3000, true)
	instances.FreeRange(small, 3000, true)
	rows, span_count = tlas_table:GetSpans(spans)
	T(span_count)["=="](2)
	T(rows)["=="](base_count + 1)
	instances.Remove(first)
	instances.Remove(second)
end)

T.Test3D("Graphics render3d scene store traces a structure built around a hole in the rows", function()
	if not render.GetDevice().ray_query_supported then return end

	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 1)
	cube:BuildBoundingBox()
	cube:Upload()
	local row = meshes.Get(cube.mesh)
	local first = instances.Add(row, 0, Matrix44():Translate(0, 0, -4), instances.MASK_SOLID, 0)
	local range = instances.AllocRange(8000)
	local second = instances.Add(row, 0, Matrix44():Translate(0, 6, 0), instances.MASK_SOLID, 0)
	instances.FreeRange(range, 8000, true)
	T(second - first > 8000)["=="](true)
	local results = render.CreateBuffer{
		byte_size = RESULT_COUNT * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_store_test_results",
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local tlas = instances.Build(cmd)
	trace(tlas, cmd, results)
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("uint32_t*", results:Map())
	T(out[0])["=="](1)
	T(out[1])["=="](first)
	T(out[4])["=="](1)
	T(out[5])["=="](second)
	instances.Remove(first)
	instances.Remove(second)
	results:Remove()
end)

local function read_results(draw, tlas_getter, origin)
	local results = render.CreateBuffer{
		byte_size = RESULT_COUNT * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_store_test_results",
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	trace(tlas_getter(cmd), cmd, results, origin)
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("uint32_t*", results:Map())
	local copy = {out[0], out[1], out[2], out[3], out[4]}
	results:Remove()
	return copy
end

T.Test3D("Graphics render3d scene store follows a visual that moves, hides and is removed", function(draw)
	if not render.GetDevice().ray_query_supported then return end

	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 1)
	cube:BuildBoundingBox()
	cube:Upload()
	local entity = Entity.New{Name = "scene_store_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	local visual = entity:AddComponent("visual")
	local primitive = Entity.New{Name = "scene_store_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(cube)
	visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(1, 0, 0, 1)})
	visual:BuildAABB()
	draw()
	draw()
	local hit = read_results(draw, rt.GetTLAS)
	T(hit[1])["=="](1)
	entity.transform:SetPosition(Vec3(0, 0, -40))
	draw()
	draw()
	local moved = read_results(draw, rt.GetTLAS)
	T(moved[1])["=="](1)
	T(ffi.cast("float*", ffi.new("uint32_t[1]", moved[4]))[0] > 30)["=="](true)
	visual:SetVisible(false)
	draw()
	draw()
	T(read_results(draw, rt.GetTLAS)[1])["=="](0)
	visual:SetVisible(true)
	draw()
	draw()
	T(read_results(draw, rt.GetTLAS)[1])["=="](1)
	entity:Remove()
	draw()
	draw()
	T(read_results(draw, rt.GetTLAS)[1])["=="](0)
end)

T.Test3D("Graphics render3d scene store shows rays the level of detail of the distance", function(draw)
	if not render.GetDevice().ray_query_supported then return end

	local render3d = import("goluwa/render3d/render3d.lua")
	render3d.GetCamera():SetPosition(Vec3(0, 0, 0))
	local fine = Polygon3D.New()
	shapes.BuildCube(fine, 2)
	fine:BuildBoundingBox()
	fine:Upload()
	local coarse = Polygon3D.New()
	shapes.BuildCube(coarse, 4)
	coarse:BuildBoundingBox()
	coarse:Upload()
	coarse:SetLODLevel(1)
	coarse:SetLODDistance(2)
	local entity = Entity.New{Name = "scene_store_lod"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -5))
	local visual = entity:AddComponent("visual")
	local material = Material.New{ColorMultiplier = Color(1, 0, 0, 1)}

	for i, polygon in ipairs{fine, coarse} do
		local primitive = Entity.New{Name = "scene_store_lod_primitive" .. i, Parent = entity}
		primitive:AddComponent("transform")
		primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
		primitive.visual_primitive:SetMaterial(material)
	end

	visual:BuildAABB()
	draw()
	draw()
	local near = read_results(draw, rt.GetTLAS)
	T(near[1])["=="](1)
	local near_distance = ffi.cast("float*", ffi.new("uint32_t[1]", near[4]))[0]
	T(near_distance > 2.5 and near_distance < 3.5)["=="](true)
	entity.transform:SetPosition(Vec3(0, 0, -40))
	draw()
	draw()
	local far = read_results(draw, rt.GetTLAS)
	T(far[1])["=="](1)
	local far_distance = ffi.cast("float*", ffi.new("uint32_t[1]", far[4]))[0]
	T(far_distance > 35.5 and far_distance < 36.5)["=="](true)
	entity:Remove()
	fine:Remove()
	coarse:Remove()
end)

T.Test3D("Graphics render3d scene store follows a skinned mesh in the ray traced scene", function(draw)
	if not render.GetDevice().ray_query_supported then return end

	local Skeleton = import("goluwa/render3d/skeleton.lua")
	local bind_local = ffi.new("float[14]", {0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1})
	local inverse_bind = ffi.new(
		"float[24]",
		{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 1, 0}
	)
	local skeleton = Skeleton.New{
		BoneNames = {"root", "arm"},
		Parents = {-1, 0},
		BindLocal = bind_local,
		InverseBind = inverse_bind,
	}
	skeleton:AddClip{
		Name = "swing",
		Duration = 1,
		Loop = true,
		Sample = function(clip, cycle, params, out)
			ffi.copy(out, bind_local, 14 * 4)
			local half = cycle * math.pi / 4
			out[12] = math.sin(half)
			out[13] = math.cos(half)
		end,
	}
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	poly.Skin = {
		BoneIndices = ffi.new("uint8_t[?]", count * 4),
		BoneWeights = ffi.new("float[?]", count * 4),
	}

	for i = 0, count - 1 do
		poly.Skin.BoneIndices[i * 4] = 1
		poly.Skin.BoneWeights[i * 4] = 1
	end

	local entity = Entity.New{Name = "scene_store_skinned"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	local visual = entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = "scene_store_skinned_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(poly)
	primitive:SetMaterial(Material.New{ColorMultiplier = Color(1, 0, 0, 1)})
	visual.Skeleton = skeleton
	local animator = entity:AddComponent("animator")
	animator:Bind(skeleton)
	animator:SetSequence("swing")
	animator:SetPlaying(false)
	animator:SetTime(0)
	animator:Animate(0)
	visual:BuildAABB()
	local origin = {-0.45, -0.45, 0}
	draw()
	draw()
	T(read_results(draw, rt.GetTLAS, origin)[1])["=="](1)
	animator:SetTime(0.5)
	animator:Animate(0)
	draw()
	draw()
	T(read_results(draw, rt.GetTLAS, origin)[1])["=="](0)
	animator:Unbind()
	entity:Remove()
end)
