local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local opacity_micromaps = import("goluwa/render3d/scene/opacity_micromaps.lua")
local pvars = import("goluwa/cli/pvars.lua")

-- candidates are never confirmed, so only a micromap's opaque state can commit a hit on a non opaque instance
local function trace_unconfirmed(tlas, results)
	local pipeline = EasyPipeline.Compute{
		name = "opacity_micromap_test_trace",
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
		shader = [[
			void trace(int slot, vec3 dir) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene, 0u, 0xFF, vec3(0.0), 0.0, normalize(dir), 100.0);
				while (rayQueryProceedEXT(query)) {}
				results[slot] = rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT ? 0u : 1u;
			}

			void main() {
				trace(0, vec3(-0.5, 0.0, -4.0));
				trace(1, vec3(0.5, 0.0, -4.0));
			}
		]],
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, results, results:GetSize())
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", 1, 1, 0, tlas)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipeline.pipeline:Dispatch(cmd, 1, 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	local out = ffi.cast("uint32_t*", results:Map())
	return out[0], out[1]
end

local function build()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local tlas = instances.Build(cmd)
	cmd:End()
	render.SubmitAndWait(cmd)
	return tlas
end

T.Test3D("Graphics render3d opacity micromaps decide alpha tested hits in hardware", function()
	if not (render.GetDevice().ray_query_supported and opacity_micromaps.IsSupported()) then
		return
	end

	pvars.SetSession("r_rt_opacity_micromaps", true)
	local pixels = ffi.new("uint8_t[?]", 16 * 16 * 4)

	for y = 0, 15 do
		for x = 0, 15 do
			local i = (y * 16 + x) * 4
			pixels[i], pixels[i + 1], pixels[i + 2] = 255, 255, 255
			pixels[i + 3] = x < 8 and 0 or 255
		end
	end

	local material = Material.New()
	material:SetAlbedoTexture(Texture.New{buffer = pixels, width = 16, height = 16, format = "r8g8b8a8_unorm"})
	material:SetAlphaTest(true)
	local quad = Polygon3D.New()
	shapes.BuildPlane(quad, Vec3(0, 0, 0), Vec3(0, 0, 1), 1, 1)
	quad:BuildBoundingBox()
	quad:Upload()
	local record = meshes.GetRecord(meshes.Get(quad.mesh))
	local flags, mask = instances.GetMaterialFlags(material)
	T(bit.band(flags, instances.FLAG_NO_OPAQUE) ~= 0)["=="](true)
	local results = render.CreateBuffer{
		byte_size = 8,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "opacity_micromap_test_results",
	}
	local matrix = Matrix44():Translate(0, 0, -4)
	local plain = instances.Add(record.row, 0, matrix, mask, flags)
	local tlas = build()
	local left, right = trace_unconfirmed(tlas, results)
	T(left + right)["=="](0)
	instances.Remove(plain)
	local row = opacity_micromaps.GetRow(record, material)
	T(row ~= record.row)["=="](true)
	local mapped = instances.Add(row, 0, matrix, mask, flags)

	for _ = 1, 4 do
		tlas = build()
	end

	T(meshes.GetRecord(row).omm.micromap ~= nil)["=="](true)
	left, right = trace_unconfirmed(tlas, results)
	T(left + right)["=="](1)
	instances.Remove(mapped)
	results:Remove()
end)
