local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local RESULT_COUNT = 8

-- one ray straight at the instance and one that misses it
local function trace(tlas, cmd, results, origin_z)
	local pipeline = EasyPipeline.Compute{
		name = "scene_store_test_trace",
		DescriptorSetCount = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}},
		descriptor_sets = scene_bvh.GetTLASDescriptor(1),
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) buffer Results { uint results[]; };
			layout(set = 0, binding = 1) uniform accelerationStructureEXT scene;
		]],
		shader = [[
			void trace(int slot, vec3 dir) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene, gl_RayFlagsOpaqueEXT, 0xFF, vec3(0.0), 0.0, dir, 100.0);
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
		]],
	}
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, results, results:GetSize())
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", 1, 1, 0, tlas)
	cmd:PipelineBarrier{srcStage = "acceleration_structure_build_khr", dstStage = "compute", memoryBarrier = true}
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
