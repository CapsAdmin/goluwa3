local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local draw = import("goluwa/render3d/scene/draw.lua")
local visibility = {}
-- an estimate of which of the rows the main cull drew can be seen: rays from the camera through random points of each
-- row's box, against the ray traced scene, and the row counts as seen when a ray's first solid hit is that row. it is
-- for looking at the culling (see scene_draw_dump and scene_draw_visibility), it stalls like draw.ReadBackCull does.
-- not every row can be told: rows that are not in the ray traced scene (InSceneBVH false, hidden from rays) never
-- get hit, and alpha tested or refractive ones are looked through. a thin or small row may be missed by all its rays
local NO_HIT = 0xFFFFFFFF
local RayArray = ffi.typeof("float[?]")
local pipeline

local function get_pipeline()
	if pipeline then return pipeline end

	pipeline = EasyPipeline.Compute{
		name = "scene_visibility_rays",
		DescriptorSetCount = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}, {binding_index = 1}},
		descriptor_sets = {{type = "acceleration_structure_khr", binding_index = 2, stageFlags = "compute"}},
		block = {{"count", "int"}},
		write = function(self, block)
			block.count = visibility.ray_count
			return block
		end,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) readonly buffer Rays { vec4 rays[]; };
			layout(set = 0, binding = 1) buffer Results { uint results[]; };
			layout(set = 0, binding = 2) uniform accelerationStructureEXT scene;
		]],
		shader = [[
			void main() {
				uint i = gl_GlobalInvocationID.x;

				if (i >= uint(compute.count)) return;

				vec3 origin = rays[i * 2u].xyz;
				vec3 direction = rays[i * 2u + 1u].xyz;
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene, gl_RayFlagsNoneEXT, 0xFF, origin, 0.0, direction, 100000.0);

				// what is not opaque (cutouts, glass) is not confirmed, the ray goes through it
				while (rayQueryProceedEXT(query)) {}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
					results[i] = 0xFFFFFFFFu;
				} else {
					results[i] = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				}
			}
		]],
	}
	return pipeline
end

-- {by_id = {[id] = {samples, self, other, sky, solid}}, drawn, seen, unseen} for the rows the main cull drew
function visibility.Estimate(rays_per_row)
	rays_per_row = rays_per_row or 128
	local drawn = draw.ReadBackCull(0)
	local ids = {}

	for id in pairs(drawn.by_id) do
		ids[#ids + 1] = id
	end

	local result = {by_id = {}, drawn = #ids, seen = 0, unseen = 0}

	if #ids == 0 or not render.GetDevice().ray_query_supported then return result end

	table.sort(ids)
	local raster = instances.GetRasterTable():Get()
	local data = instances.GetDataTable():Get()
	local camera = render3d.GetCamera():GetPosition()
	local count = #ids * rays_per_row
	local rays = RayArray(count * 8)
	local seed = 12345

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	for row, id in ipairs(ids) do
		local box = raster[id]

		for k = 0, rays_per_row - 1 do
			local x = box.min_x + (box.max_x - box.min_x) * random()
			local y = box.min_y + (box.max_y - box.min_y) * random()
			local z = box.min_z + (box.max_z - box.min_z) * random()
			local dx, dy, dz = x - camera.x, y - camera.y, z - camera.z
			local length = math.sqrt(dx * dx + dy * dy + dz * dz)

			if length < 1e-6 then dx, dy, dz, length = 0, 0, -1, 1 end

			local at = ((row - 1) * rays_per_row + k) * 8
			rays[at], rays[at + 1], rays[at + 2] = camera.x, camera.y, camera.z
			rays[at + 4], rays[at + 5], rays[at + 6] = dx / length, dy / length, dz / length
		end
	end

	local ray_buffer = render.CreateBuffer{
		byte_size = count * 32,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_visibility rays",
	}
	local result_buffer = render.CreateBuffer{
		byte_size = count * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_visibility results",
	}
	ffi.copy(ray_buffer:Map(), rays, count * 32)
	local compute = get_pipeline()
	visibility.ray_count = count
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd.gpu_timing_disabled = true
	cmd:Begin()
	local tlas = instances.Build(cmd)
	compute:UpdateDescriptorSet("storage_buffer", 1, 0, 0, ray_buffer, ray_buffer:GetSize())
	compute:UpdateDescriptorSet("storage_buffer", 1, 1, 0, result_buffer, result_buffer:GetSize())
	compute:UpdateDescriptorSet("acceleration_structure_khr", 1, 2, 0, tlas)
	cmd:PipelineBarrier{srcStage = {"acceleration_structure_build_khr", "host"}, dstStage = "compute", memoryBarrier = true}
	compute:Dispatch(cmd, math.ceil(count / 64), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
	local out = ffi.cast("uint32_t *", result_buffer:Map())

	for row, id in ipairs(ids) do
		local entry = {samples = rays_per_row, self = 0, other = 0, sky = 0}
		-- a solid instance is one the rays can hit and stop at
		entry.solid = bit.band(data[id].mask_lod, 0xFF) ~= 0 and bit.band(data[id].flags, instances.FLAG_NO_OPAQUE) == 0

		for k = 0, rays_per_row - 1 do
			local hit = out[(row - 1) * rays_per_row + k]

			if hit == id then
				entry.self = entry.self + 1
			elseif hit == NO_HIT then
				entry.sky = entry.sky + 1
			else
				entry.other = entry.other + 1
			end
		end

		result.by_id[id] = entry

		if entry.self > 0 then result.seen = result.seen + 1 else result.unseen = result.unseen + 1 end
	end

	ray_buffer:Remove()
	result_buffer:Remove()
	return result
end

return visibility
