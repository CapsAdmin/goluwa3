local commands = import("goluwa/cli/commands.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local system = import("goluwa/system.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local light_culling = library()
light_culling.oct_size = 64
light_culling.subs = 4
light_culling.bias = 0
light_culling.blur = 0
light_culling.softness = 0
local LIGHT_CULL_MAX_TRACES_PER_FRAME = 16
local LIGHT_CULL_RETRACE_INTERVAL = 2
local LIGHT_CULL_MOVE_TOLERANCE_SQ = 0.02 * 0.02
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local BINDING_UNIFORM = 0
local BINDING_MAP = 1
local BINDING_BVH_NODES = 2
local BINDING_BVH_TRIANGLES = 3
local BINDING_VERSION = 4

local function octahedral_glsl()
	return [[
		vec2 light_cull_oct_encode(vec3 d) {
			d /= (abs(d.x) + abs(d.y) + abs(d.z));
			vec2 p = d.xy;

			if (d.z < 0.0) {
				p = (1.0 - abs(d.yx)) * vec2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
			}

			return p * 0.5 + 0.5;
		}

		vec3 light_cull_oct_decode(vec2 uv) {
			vec2 p = uv * 2.0 - 1.0;
			vec3 d = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));

			if (d.z < 0.0) {
				d.xy = (1.0 - abs(d.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
			}

			return normalize(d);
		}
	]]
end

local MAP_SAMPLER_CONFIG = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
	wrap_r = "clamp_to_edge",
}

local function create_map_texture(size, format, debug_name, usage, sampler)
	local texture = Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = 1,
		image = {
			array_layers = MAX_LIGHTS,
			usage = usage,
		},
		view = {
			view_type = "2d_array",
			layer_count = MAX_LIGHTS,
		},
		sampler = sampler,
	}
	texture:SetDebugName(debug_name)
	return texture
end

local function get_frame_span()
	return math.max(render.GetSwapchainImageCount() or 1, 1)
end

local function get_map_size()
	return light_culling.map_size or light_culling.oct_size
end

local frustum_planes = {}
local frustum_frame = -1

local function get_frustum_planes()
	local frame = system.GetFrameNumber()

	if frustum_frame == frame then return frustum_planes end

	local m = render3d.GetProjectionViewMatrix()
	local x0, x1, x2, x3 = m.m00, m.m10, m.m20, m.m30
	local y0, y1, y2, y3 = m.m01, m.m11, m.m21, m.m31
	local planes = frustum_planes
	planes[0], planes[1], planes[2], planes[3] = m.m03 + x0, m.m13 + x1, m.m23 + x2, m.m33 + x3
	planes[4], planes[5], planes[6], planes[7] = m.m03 - x0, m.m13 - x1, m.m23 - x2, m.m33 - x3
	planes[8], planes[9], planes[10], planes[11] = m.m03 + y0, m.m13 + y1, m.m23 + y2, m.m33 + y3
	planes[12], planes[13], planes[14], planes[15] = m.m03 - y0, m.m13 - y1, m.m23 - y2, m.m33 - y3
	planes[16], planes[17], planes[18], planes[19] = m.m02, m.m12, m.m22, m.m32
	planes[20], planes[21], planes[22], planes[23] = m.m03 - m.m02, m.m13 - m.m12, m.m23 - m.m22, m.m33 - m.m32

	for i = 0, 20, 4 do
		local a, b, c = planes[i], planes[i + 1], planes[i + 2]
		local len = math.sqrt(a * a + b * b + c * c)

		if len > 0 then
			local inv_len = 1.0 / len
			planes[i] = a * inv_len
			planes[i + 1] = b * inv_len
			planes[i + 2] = c * inv_len
			planes[i + 3] = planes[i + 3] * inv_len
		end
	end

	frustum_frame = frame
	return planes
end

local function sphere_in_frustum(x, y, z, radius)
	local planes = get_frustum_planes()

	for i = 0, 20, 4 do
		if planes[i] * x + planes[i + 1] * y + planes[i + 2] * z + planes[i + 3] < -radius then
			return false
		end
	end

	return true
end

local function is_cull_target(light)
	return light ~= nil and
		light.CullOcclusion ~= false and
		(
			light.LightType == "point" or
			light.LightType == "spot"
		)
end

local state = {}
local stamps = {}
local move_frame = {}
local geom_stale = {}
local slot_at_z = {}
local geom_box_count = {}
local geom_box_coords = {}
local geom_version = -1

local function box_key(x0, y0, z0, x1, y1, z1)
	return (
		"%d|%d|%d|%d|%d|%d"
	):format(
		math.floor(x0 * 1000 + 0.5),
		math.floor(y0 * 1000 + 0.5),
		math.floor(z0 * 1000 + 0.5),
		math.floor(x1 * 1000 + 0.5),
		math.floor(y1 * 1000 + 0.5),
		math.floor(z1 * 1000 + 0.5)
	)
end

local function sphere_overlaps_box(px, py, pz, radius_sq, box)
	local dx = math.max(box[1] - px, 0, px - box[4])
	local dy = math.max(box[2] - py, 0, py - box[5])
	local dz = math.max(box[3] - pz, 0, pz - box[6])
	return dx * dx + dy * dy + dz * dz <= radius_sq
end

local function process_geometry_change(lights)
	local version = scene_bvh.version

	if geom_version == version then return end

	local box_count = {}
	local box_coords = {}

	for _, visual in ipairs(Visual.Instances) do
		local aabb = visual:GetWorldAABB()

		if
			aabb and
			aabb.min_x < aabb.max_x and
			aabb.min_y < aabb.max_y and
			aabb.min_z < aabb.max_z
		then
			local key = box_key(aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z)
			box_count[key] = (box_count[key] or 0) + 1

			if not box_coords[key] then
				box_coords[key] = {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z}
			end
		end
	end

	local changed = {}

	for key, count in pairs(box_count) do
		local old = geom_box_count[key] or 0

		if old ~= count then changed[#changed + 1] = box_coords[key] end
	end

	for key in pairs(geom_box_count) do
		if not box_count[key] then changed[#changed + 1] = geom_box_coords[key] end
	end

	geom_box_count = box_count
	geom_box_coords = box_coords
	geom_version = version

	if #changed > 0 then
		for light_index = 1, math.min(#lights, MAX_LIGHTS) do
			local light = lights[light_index]

			if is_cull_target(light) then
				local pos = light.Owner.transform:GetPosition()
				local radius_sq = light.Range * light.Range

				for i = 1, #changed do
					if sphere_overlaps_box(pos.x, pos.y, pos.z, radius_sq, changed[i]) then
						geom_stale[light_index] = true

						break
					end
				end
			end
		end
	end
end

local function build_trace_pipeline()
	return EasyPipeline.Compute{
		name = "light_culling_trace",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{binding_index = BINDING_MAP},
			{binding_index = BINDING_VERSION},
		},
		storage_buffers = {
			{binding_index = BINDING_BVH_NODES},
			{binding_index = BINDING_BVH_TRIANGLES},
		},
		uniform_buffers = {
			{
				name = "cull_data",
				binding_index = BINDING_UNIFORM,
				block = {
					{"cull_positions", "vec4", MAX_LIGHTS},
					{"slot_at_z", "int", MAX_LIGHTS},
					{"cull_stamps", "int", MAX_LIGHTS},
					{"oct_size", "int"},
				},
				write = function(self, block)
					local lights = render3d.GetLights()

					for i = 0, MAX_LIGHTS - 1 do
						local light = lights[i + 1]

						if is_cull_target(light) then
							light.Owner.transform:GetPosition():CopyToFloatPointer(block.cull_positions[i])
							block.cull_positions[i][3] = light.Range
						else
							block.cull_positions[i][0] = 0
							block.cull_positions[i][1] = 0
							block.cull_positions[i][2] = 0
							block.cull_positions[i][3] = 0
						end

						block.slot_at_z[i] = slot_at_z[i + 1] or 0
						block.cull_stamps[i] = stamps[i + 1] or 0
					end

					block.oct_size = get_map_size()
					return block
				end,
			},
		},
		custom_declarations = (
				[[
			layout(set = 0, binding = %d, r32f) uniform writeonly image2DArray light_cull_map;
			layout(set = 0, binding = %d, r32ui) uniform uimage2DArray light_cull_version;
		]]
			):format(BINDING_MAP, BINDING_VERSION) .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES),
		shader = (
				[[
			const float LIGHT_CULL_T_MIN = 0.05;

			]] .. octahedral_glsl() .. [[

			]] .. scene_bvh.GetTraversalGLSL() .. [[

			const int LIGHT_CULL_SUBS = ]] .. light_culling.subs .. [[;

			void main() {
				ivec2 p = ivec2(gl_GlobalInvocationID.xy);
				int slot = cull_data.slot_at_z[gl_GlobalInvocationID.z];
				vec4 light = cull_data.cull_positions[slot];
				uint stamp = uint(cull_data.cull_stamps[slot]);
				int size = cull_data.oct_size;

				uint version = imageLoad(light_cull_version, ivec3(p, slot)).r;

				if (version >= stamp) return;

				float fsize = float(size);
				float dist = 0.0;
				bool clear = false;

				vec2 uv0 = vec2(p) / fsize;
				vec2 uv_step = vec2(1.0) / (fsize * float(LIGHT_CULL_SUBS));
				scene_bvh_hit hit;

				for (int sy = 0; sy < LIGHT_CULL_SUBS; sy++) {
					for (int sx = 0; sx < LIGHT_CULL_SUBS; sx++) {
						vec2 uv = uv0 + (vec2(sx, sy) + 0.5) * uv_step;
						vec3 dir = light_cull_oct_decode(uv);

						if (scene_bvh_trace(light.xyz, dir, LIGHT_CULL_T_MIN, light.w, hit)) {
							dist = max(dist, hit.distance);
						} else {
							clear = true;
							sy = LIGHT_CULL_SUBS;
						}
					}
				}

				if (clear) dist = light.w;

				imageStore(light_cull_map, ivec3(p, slot), vec4(dist));
				imageStore(light_cull_version, ivec3(p, slot), uvec4(stamp));
			}
		]]
			),
	}
end

local function ensure_map_texture()
	if not light_culling.map_texture then
		local size = light_culling.oct_size
		light_culling.map_texture = create_map_texture(
			size,
			"r32_sfloat",
			"light_culling_occlusion",
			{"sampled", "storage", "transfer_src", "transfer_dst"},
			MAP_SAMPLER_CONFIG
		)
		light_culling.version_texture = create_map_texture(
			size,
			"r32_uint",
			"light_culling_version",
			{"sampled", "storage", "transfer_src"},
			nil
		)
		light_culling.map_size = size
	end
end

local function ensure_resources()
	ensure_map_texture()

	if not light_culling.trace_pipeline then
		light_culling.trace_pipeline = build_trace_pipeline()
	end
end

local function get_descriptor_slot()
	local frame = render.GetCurrentFrame() or 1
	return ((frame - 1) % get_frame_span()) + 1
end

light_culling.last_dispatches = 0

function light_culling.Draw(cmd)
	light_culling.last_dispatches = 0

	if not (scene_bvh.IsReady() and scene_bvh.LightCulling ~= false) then return end

	local lights = render3d.GetLights()
	local frame = system.GetFrameNumber()
	process_geometry_change(lights)
	local dirty_count = 0

	for light_index = 1, MAX_LIGHTS do
		local light = lights[light_index]

		if not is_cull_target(light) then
			state[light_index] = nil
			stamps[light_index] = nil
			move_frame[light_index] = nil
			geom_stale[light_index] = nil
			slot_at_z[light_index] = nil
		else
			local pos = light.Owner.transform:GetPosition()

			if sphere_in_frustum(pos.x, pos.y, pos.z, light.Range) then
				local info = state[light_index]
				local stamp = stamps[light_index] or 0
				local mode = 0

				if (not info) or info.light ~= light then
					stamp = stamp + 1
					mode = 1
				else
					local pending = stamp > info.stamp_dispatched

					if geom_stale[light_index] then
						geom_stale[light_index] = nil

						if not pending then stamp = stamp + 1 end

						mode = 2
					elseif info.range < light.Range - 1e-4 then
						if not pending then stamp = stamp + 1 end

						mode = 2
					elseif
						(
							(
								pos.x - info.x
							) * (
								pos.x - info.x
							) + (
								pos.y - info.y
							) * (
								pos.y - info.y
							) + (
								pos.z - info.z
							) * (
								pos.z - info.z
							) > LIGHT_CULL_MOVE_TOLERANCE_SQ and
							frame - (
								move_frame[light_index] or
								-LIGHT_CULL_RETRACE_INTERVAL
							) >= LIGHT_CULL_RETRACE_INTERVAL
						)
					then
						stamp = stamp + 1
						move_frame[light_index] = frame
						mode = 2
					elseif pending then
						mode = 2
					end
				end

				if mode ~= 0 then
					stamps[light_index] = stamp
					slot_at_z[dirty_count + 1] = light_index - 1
					dirty_count = dirty_count + 1
				end
			end
		end
	end

	if dirty_count == 0 then return end

	if dirty_count > LIGHT_CULL_MAX_TRACES_PER_FRAME then
		dirty_count = LIGHT_CULL_MAX_TRACES_PER_FRAME
	end

	ensure_resources()
	local pipeline = light_culling.trace_pipeline
	local map_texture = light_culling.map_texture
	local version_texture = light_culling.version_texture
	local slot = get_descriptor_slot()
	render.TransitionResourceToComputeStorage(map_texture, {cmd = cmd, base_array_layer = 0, layer_count = MAX_LIGHTS})
	render.TransitionResourceToComputeStorage(version_texture, {cmd = cmd, base_array_layer = 0, layer_count = MAX_LIGHTS})
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_MAP, 0, map_texture:GetView())
	pipeline:UpdateDescriptorSet("storage_image", slot, BINDING_VERSION, 0, version_texture:GetView())
	scene_bvh.BindBuffers(pipeline, slot, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
	pipeline:UploadConstants()
	local size = get_map_size()
	light_culling.last_dispatches = dirty_count
	gpu_timing.BeginScope(cmd, "light_culling")
	pipeline.pipeline:Dispatch(cmd, size, size, dirty_count, slot, pipeline.dynamic_offsets)
	gpu_timing.EndScope(cmd, "light_culling")

	for _, texture in ipairs({map_texture, version_texture}) do
		render.TransitionResourceFrom(
			texture,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "compute",
				srcAccess = "shader_write",
				dstStage = "compute",
				dstAccess = "shader_read",
				base_array_layer = 0,
				layer_count = MAX_LIGHTS,
			}
		)
	end

	for i = 1, dirty_count do
		local light_index = slot_at_z[i] + 1
		local light = lights[light_index]
		local pos = light.Owner.transform:GetPosition()
		state[light_index] = {
			light = light,
			x = pos.x,
			y = pos.y,
			z = pos.z,
			range = light.Range,
			stamp_dispatched = stamps[light_index],
		}
	end
end

function light_culling.Reset()
	for k in pairs(state) do
		state[k] = nil
	end

	for k in pairs(stamps) do
		stamps[k] = nil
	end

	for k in pairs(move_frame) do
		move_frame[k] = nil
	end

	for k in pairs(geom_stale) do
		geom_stale[k] = nil
	end
end

-- per-light debug state for the console and the stress scene overlay
function light_culling.GetDebugState()
	local lights = render3d.GetLights()
	local out = {
		frame = system.GetFrameNumber(),
		bias = light_culling.bias,
		blur = light_culling.blur,
		softness = light_culling.softness,
		oct_size = get_map_size(),
		max_traces = LIGHT_CULL_MAX_TRACES_PER_FRAME,
		lights = {},
	}

	for light_index = 1, MAX_LIGHTS do
		local light = lights[light_index]

		if is_cull_target(light) then
			local info = state[light_index]
			local stamp = stamps[light_index] or 0
			local pos = light.Owner.transform:GetPosition()
			out.lights[#out.lights + 1] = {
				index = light_index - 1,
				name = light.Owner.Name or ("light" .. light_index),
				x = pos.x,
				y = pos.y,
				z = pos.z,
				range = light.Range,
				stamp = stamp,
				dispatched = info and info.stamp_dispatched or 0,
				pending = stamp > (info and info.stamp_dispatched or 0),
				geom_stale = geom_stale[light_index] ~= nil,
				in_frustum = sphere_in_frustum(pos.x, pos.y, pos.z, light.Range),
			}
		end
	end

	return out
end

function light_culling.GetOcclusionTexture()
	ensure_map_texture()
	return light_culling.map_texture
end

function light_culling.GetVersionTexture()
	ensure_map_texture()
	return light_culling.version_texture
end

function light_culling.GetDeclarationGLSL(binding, set)
	return (
		[[
		layout(set = %d, binding = %d) uniform sampler2DArray light_cull_map;
	]]
	):format(set or 0, binding)
end

function light_culling.GetOcclusionDescriptor()
	local texture = light_culling.GetOcclusionTexture()
	return {texture:GetView(), texture.sampler or render.CreateSampler(MAP_SAMPLER_CONFIG)}
end

function light_culling.GetBlockLayout()
	return {
		{"bvh_cull_slot", "int", MAX_LIGHTS},
		{"bvh_cull_active", "int"},
		{"bvh_cull_oct_size", "int"},
		{"bvh_cull_bias", "float"},
		{"bvh_cull_blur", "float"},
		{"bvh_cull_softness", "float"},
	}
end

function light_culling.WriteCullBlock(block, lights)
	for i = 0, MAX_LIGHTS - 1 do
		block.bvh_cull_slot[i] = -1
	end

	local active = 0

	if scene_bvh.IsReady() and scene_bvh.LightCulling ~= false then
		for light_index = 1, math.min(#lights, MAX_LIGHTS) do
			local light = lights[light_index]

			if is_cull_target(light) then
				local info = state[light_index]

				if info and info.light == light then
					local pos = light.Owner.transform:GetPosition()

					if sphere_in_frustum(pos.x, pos.y, pos.z, light.Range) then
						block.bvh_cull_slot[light_index - 1] = light_index - 1
						active = 1
					end
				end
			end
		end
	end

	block.bvh_cull_active = active
	block.bvh_cull_oct_size = get_map_size()
	block.bvh_cull_bias = light_culling.bias
	block.bvh_cull_blur = light_culling.blur
	block.bvh_cull_softness = light_culling.softness
end

function light_culling.GetSamplingGLSL(data_block)
	return (
			[[
		const int LIGHT_CULL_MAX_SLOTS = ]] .. MAX_LIGHTS .. [[;

		]] .. octahedral_glsl() .. [[

		float light_cull_fetch(int slot, vec3 dir) {
			vec2 uv = light_cull_oct_encode(dir);

			if (]] .. data_block .. [[.bvh_cull_blur <= 0.0) {
				return texture(light_cull_map, vec3(uv, float(slot))).r;
			}

			vec2 o = vec2(]] .. data_block .. [[.bvh_cull_blur / float(]] .. data_block .. [[.bvh_cull_oct_size));
			return (
				texture(light_cull_map, vec3(uv, float(slot))).r +
				texture(light_cull_map, vec3(uv + vec2(o.x, 0.0), float(slot))).r +
				texture(light_cull_map, vec3(uv - vec2(o.x, 0.0), float(slot))).r +
				texture(light_cull_map, vec3(uv + vec2(0.0, o.y), float(slot))).r +
				texture(light_cull_map, vec3(uv - vec2(0.0, o.y), float(slot))).r
			) * 0.2;
		}

		float light_cull_shadow_factor(int slot, vec3 light_pos, float range, vec3 world_pos) {
			if (slot < 0 || slot >= LIGHT_CULL_MAX_SLOTS || ]] .. data_block .. [[.bvh_cull_active == 0) return 1.0;
			vec3 to_pos = world_pos - light_pos;
			float dist = length(to_pos);

			if (dist >= range) return 1.0;

			float occl = light_cull_fetch(slot, to_pos / max(dist, 1e-5));

			// 0 means the texel was never traced (the map is zero initialized)
			// and is assumed clear, it will be traced on the next dispatch
			if (occl <= 0.0) return 1.0;

			if (]] .. data_block .. [[.bvh_cull_softness <= 0.0) {
				return dist > occl + occl * ]] .. data_block .. [[.bvh_cull_bias ? 0.0 : 1.0;
			}

			float margin = (dist - occl * (1.0 + ]] .. data_block .. [[.bvh_cull_bias)) /
				max(occl * ]] .. data_block .. [[.bvh_cull_softness, 1e-5);
			return 1.0 - smoothstep(0.0, 1.0, margin);
		}
	]]
		)
end

commands.Add("light_culling_bias=number[0.045]", function(bias)
	light_culling.bias = bias
	logf("[light_culling] bias %g\n", bias)
end)

commands.Add("light_culling_blur=number[0]", function(blur)
	light_culling.blur = math.max(0, blur)
	logf("[light_culling] blur radius %.1f texels\n", light_culling.blur)
end)

commands.Add("light_culling_softness=number[0]", function(softness)
	light_culling.softness = math.max(0, softness)
	logf("[light_culling] softness margin %g\n", light_culling.softness)
end)

commands.Add("light_culling_subs=number[1]", function(subs)
	light_culling.subs = math.clamp(math.floor(subs), 1, 32)

	if light_culling.trace_pipeline then
		light_culling.trace_pipeline = nil
		light_culling.Reset()
	end

	logf("[light_culling] sub rays per texel %d\n", light_culling.subs)
end)

commands.Add("light_culling_size=number[64]", function(size)
	light_culling.oct_size = math.clamp(math.floor(size), 16, 256)
	logf(
		"[light_culling] octahedral map size %d%s\n",
		light_culling.oct_size,
		light_culling.map_texture and " (current maps keep their size)" or ""
	)
end)

commands.Add("lc_debug", function()
	local debug_state = light_culling.GetDebugState()
	logf(
		"[light_culling] frame %d, %d cull lights, bias %g blur %g softness %g oct %d\n",
		debug_state.frame,
		#debug_state.lights,
		debug_state.bias,
		debug_state.blur,
		debug_state.softness,
		debug_state.oct_size
	)

	for _, light in ipairs(debug_state.lights) do
		logf(
			"  [%d] %-20s pos (%.1f %.1f %.1f) range %g stamp %d dispatched %d%s%s%s\n",
			light.index,
			light.name,
			light.x,
			light.y,
			light.z,
			light.range,
			light.stamp,
			light.dispatched,
			light.pending and " PENDING" or "",
			light.geom_stale and " GEOM_STALE" or "",
			light.in_frustum and "" or " OUT_OF_FRUSTUM"
		)
	end
end)

commands.Add("scene_bvh_light_culling=boolean[true]", function(enabled)
	scene_bvh.LightCulling = enabled ~= false
	logf(
		"[scene_bvh] light culling %s\n",
		scene_bvh.LightCulling and "enabled" or "disabled"
	)
end)

return light_culling
