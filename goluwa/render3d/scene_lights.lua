local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local terrain_shadow = import("goluwa/render3d/terrain_shadow.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")
local scene_lights = {}
import.loaded["goluwa/render3d/scene_lights.lua"] = scene_lights
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid
scene_lights.MIN_CAPACITY = 64
scene_lights.capacity = scene_lights.MIN_CAPACITY
scene_lights.MAX_CASCADES = directional_shadows.MAX_CASCADES
scene_lights.MAX_POINT_SHADOWS = 32

local function sort_lights(a, b)
	if a.distance_score ~= b.distance_score then
		return a.distance_score < b.distance_score
	end

	return a.light_index < b.light_index
end

function scene_lights.FitCapacity(count, capacity)
	local needed = scene_lights.MIN_CAPACITY

	while needed < count do
		needed = needed * 2
	end

	if not capacity or needed > capacity then return needed end

	if needed * 4 <= capacity then return needed * 2 end

	return capacity
end

function scene_lights.BuildShadowsBlockLayout()
	local layout = {
		{"light_space_matrices", "mat4", scene_lights.MAX_CASCADES},
		{"local_directional_light_space_matrix", "mat4"},
		{"cascade_splits", "float", scene_lights.MAX_CASCADES},
		{"cascade_texel_world_sizes", "float", scene_lights.MAX_CASCADES},
		{"cascade_depth_quanta", "float", scene_lights.MAX_CASCADES},
		{"local_directional_depth_quantum", "float"},
		{"local_directional_shadow_texel_world_size", "float"},
		{"shadow_map_indices", "int", scene_lights.MAX_CASCADES},
		{"local_directional_shadow_map_index", "int"},
		{"point_shadow_positions", "vec4", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_map_indices", "int", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_light_indices", "int", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_count", "int"},
		{"directional_shadow_light_index", "int"},
		{"local_directional_shadow_light_index", "int"},
		{"cascade_count", "int"},
		{"sun_angular_radius_tan", "float"},
		{"noise_phase", "float"},
		{"sun_normal_bias", "float"},
		{"sun_light_bias", "float"},
		{"sun_contact_ray", "float"},
		unpack(clouds.GetShadowBlockLayout()),
	}

	for _, field in ipairs(terrain_shadow.GetShadowBlockLayout()) do
		layout[#layout + 1] = field
	end

	return layout
end

function scene_lights.GetLightGLSLCode()
	return [=[
			struct lights_t {
				vec4 position;
				vec4 direction;
				vec4 color;
				vec4 params;
				vec4 falloff;
				ivec4 slots;
			};

			layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SceneLights { lights_t l[]; };

			lights_t scene_light(uint64_t lights, int i) {
				return SceneLights(lights).l[i];
			}

			int get_light_type(lights_t light) {
				return int(light.position.w);
			}

			vec3 get_light_direction(lights_t light) {
				return normalize(light.direction.xyz);
			}

			float get_light_falloff(lights_t light, float dist) {
				return light.falloff.x + dist * (light.falloff.y + dist * light.falloff.z);
			}

			float get_light_distance_attenuation(lights_t light, float dist, float range) {
				float ratio = dist / range;
				float window = clamp(1.0 - ratio * ratio * ratio * ratio, 0.0, 1.0);
				return window * window / max(get_light_falloff(light, dist), 0.0025);
			}

			bool get_light_vector_and_attenuation(lights_t light, vec3 world_pos, out vec3 L, out float attenuation) {
				int type = get_light_type(light);
				attenuation = 1.0;

				if (type == 0) {
					L = -get_light_direction(light);
					return true;
				}

				if (type == 1) {
					vec3 light_to_pos = light.position.xyz - world_pos;
					float dist = length(light_to_pos);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					L = light_to_pos / dist;
					attenuation = get_light_distance_attenuation(light, dist, range) * light.params.w;
					return true;
				}

				if (type == 2) {
					vec3 from_light = world_pos - light.position.xyz;
					float dist = length(from_light);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					vec3 light_dir = get_light_direction(light);
					float in_front = 1.0 - smoothstep(-0.1, 0.2, dot(from_light / dist, light_dir));

					if (in_front <= 0.0) {
						return false;
					}

					L = light_dir;
					attenuation = in_front * get_light_distance_attenuation(light, dist, range) * light.params.w;
					return true;
				}

				if (type == 3) {
					vec3 from_light = world_pos - light.position.xyz;
					float dist = length(from_light);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					vec3 light_dir = get_light_direction(light);
					float inner_cone = clamp(light.params.y, -1.0, 1.0);
					float outer_cone = clamp(light.params.z, -1.0, inner_cone);
					float cosine = dot(light_dir, from_light / dist);

					if (cosine <= outer_cone) return false;

					float cone_attenuation = smoothstep(outer_cone, inner_cone, cosine);
					L = normalize(light.position.xyz - world_pos);
					attenuation = cone_attenuation * get_light_distance_attenuation(light, dist, range) * light.params.w;
					return true;
				}

				return false;
			}
		]=]
end

do
	local LightRecord = ffi.typeof([[struct {
		float position[4];
		float direction[4];
		float color[4];
		float params[4];
		float falloff[4];
		int32_t slots[4];
	}]])
	local LightRecordArray = ffi.typeof("$[?]", LightRecord)
	local Uint32Pointer = ffi.typeof("const uint32_t*")
	local RECORD_SIZE = ffi.sizeof(LightRecord)
	local RING = 4
	local light_rotation = Quat()
	local light_direction = Vec3()
	local light_forward = orientation.FORWARD_VECTOR
	local light_backward = -orientation.FORWARD_VECTOR
	local uploads = setmetatable({}, {__mode = "k"})

	local function write_record(data, light, index)
		local world = light.Owner.transform:GetWorldMatrix()
		data.position[0], data.position[1], data.position[2] = world:GetTranslation()
		Quat.SetVecMul(
			light_direction,
			world:GetRotation(light_rotation),
			light.Type == "light_directional" and light_backward or light_forward
		):CopyToFloatPointer(data.direction)
		data.falloff[0] = light.SourceRadius ^ 2 + light.ConstantFalloff
		data.falloff[1] = light.LinearFalloff
		data.falloff[2] = light.QuadraticFalloff
		data.falloff[3] = light.GlowRadius
		data.direction[3] = light.SourceRadius

		if light.Type == "light_sun" then
			data.position[3] = 0
			data.params[0] = 0
			data.params[1] = 0
			data.params[2] = 0
		elseif light.Type == "light_point" then
			data.position[3] = 1
			data.params[0] = light:GetEffectiveRange()
			data.params[1] = 0
			data.params[2] = 0
		elseif light.Type == "light_directional" then
			data.position[3] = 2
			data.params[0] = light:GetEffectiveRange()
			data.params[1] = 0
			data.params[2] = 0
		elseif light.Type == "light_spot" then
			data.position[3] = 3
			data.params[0] = light:GetEffectiveRange()
			data.params[1] = math.cos(math.rad(light.InnerCone))
			data.params[2] = math.cos(math.rad(light.OuterCone))
		else
			error("Unknown light type: " .. tostring(light.Type), 2)
		end

		local color_scale = light:GetColorScale()
		data.color[0] = light.Color.r * color_scale
		data.color[1] = light.Color.g * color_scale
		data.color[2] = light.Color.b * color_scale
		data.color[3] = light:GetPhotometricAmount()
		data.params[3] = light:GetInverseEmissionSolidAngle()
		data.slots[0] = light_occlusion.GetMapLayer(index, light)
		data.slots[1] = -1
		data.slots[2] = -1
		data.slots[3] = -1
	end

	function scene_lights.GetAddress(lights)
		local count = #lights

		if count == 0 then return 0 end

		local upload = uploads[lights]

		if not upload then
			upload = {buffers = {}, serial = -1, address = 0}
			uploads[lights] = upload
		end

		if upload.serial == render.frame_serial then return upload.address end

		local capacity = scene_lights.FitCapacity(count, upload.capacity)

		if capacity ~= upload.capacity then
			upload.capacity = capacity
			upload.host = LightRecordArray(capacity)
		end

		local slot = render.frame_serial % RING + 1
		local buffer = upload.buffers[slot]

		if not buffer or buffer:GetSize() ~= upload.capacity * RECORD_SIZE then
			if buffer then buffer:Remove() end

			buffer = render.CreateBuffer{
				byte_size = upload.capacity * RECORD_SIZE,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_lights",
			}
			upload.buffers[slot] = buffer
		end

		local host = upload.host

		for i = 1, count do
			write_record(host[i - 1], lights[i], i - 1)
		end

		ffi.copy(buffer:Map(), host, count * RECORD_SIZE)
		upload.serial = render.frame_serial
		upload.address = buffer:GetDeviceAddress()
		return upload.address
	end

	function scene_lights.GetHash(lights)
		if scene_lights.GetAddress(lights) == 0 then return 0 end

		local words = ffi.cast(Uint32Pointer, uploads[lights].host)
		local hash = #lights

		for i = 0, #lights * RECORD_SIZE / 4 - 1 do
			hash = bit.bxor(bit.rol(hash, 5), words[i])
		end

		return hash
	end
end

function scene_lights.Update(cmd)
	scene_lights.capacity = scene_lights.FitCapacity(#render3d.GetLights(), scene_lights.capacity)
	light_grid.SetCapacity(cmd, scene_lights.capacity)
	light_occlusion.SetCapacity(cmd, scene_lights.capacity)
end

local function write_sun_shadows(self, shadow_block, sun)
	local cascade_slot = 1
	local sun_entity = sun.Owner

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map:IsEnabled() and shadow_map.light == sun_entity then
			for i = 1, shadow_map:GetCascadeCount() do
				if cascade_slot > scene_lights.MAX_CASCADES then break end

				shadow_block.shadow_map_indices[cascade_slot - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
				shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(shadow_block.light_space_matrices[cascade_slot - 1])
				shadow_block.cascade_splits[cascade_slot - 1] = shadow_map:GetCascadeSplits()[i] or -1
				shadow_block.cascade_texel_world_sizes[cascade_slot - 1] = shadow_map:GetCascadeTexelWorldSize(i)
				shadow_block.cascade_depth_quanta[cascade_slot - 1] = shadow_map:GetDepthQuantum(i)
				cascade_slot = cascade_slot + 1
			end
		end
	end

	shadow_block.cascade_count = cascade_slot - 1
end

function scene_lights.WriteShadowBlock(self, shadow_block, lights)
	local sun, sun_light_index = directional_shadows.GetPrimarySun(lights)
	local directional = nil
	local directional_map = nil
	local directional_light_index = -1
	local point_shadow_count = 0
	local point_shadow_candidates = {}
	local maps_by_light = {}

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map:IsEnabled() and shadow_map.light then
			local list = maps_by_light[shadow_map.light]

			if not list then
				list = {}
				maps_by_light[shadow_map.light] = list
			end

			list[#list + 1] = shadow_map
		end
	end

	local camera = render3d.GetCamera()
	local camera_position = camera and camera:GetPosition()

	for i = 0, scene_lights.MAX_CASCADES - 1 do
		shadow_block.shadow_map_indices[i] = -1
		shadow_block.cascade_splits[i] = -1
		shadow_block.cascade_texel_world_sizes[i] = 0
		shadow_block.cascade_depth_quanta[i] = 1 / 65535
	end

	shadow_block.local_directional_depth_quantum = 1 / 65535
	shadow_block.directional_shadow_light_index = -1
	shadow_block.local_directional_shadow_map_index = -1
	shadow_block.local_directional_shadow_light_index = -1
	shadow_block.local_directional_shadow_texel_world_size = 0
	shadow_block.cascade_count = 0
	shadow_block.sun_angular_radius_tan = directional_shadows.GetSunAngularRadiusTan()
	shadow_block.noise_phase = render3d.GetNoisePhase()
	shadow_block.sun_normal_bias = directional_shadows.bias.normal
	shadow_block.sun_light_bias = directional_shadows.bias.light
	shadow_block.sun_contact_ray = directional_shadows.bias.contact
	clouds.WriteShadowBlock(self, shadow_block)
	terrain_shadow.WriteShadowBlock(self, shadow_block)

	for i = 0, 15 do
		shadow_block.local_directional_light_space_matrix[i] = 0
	end

	for i = 0, scene_lights.MAX_POINT_SHADOWS - 1 do
		shadow_block.point_shadow_map_indices[i] = -1
		shadow_block.point_shadow_light_indices[i] = -1
		shadow_block.point_shadow_positions[i][0] = 0
		shadow_block.point_shadow_positions[i][1] = 0
		shadow_block.point_shadow_positions[i][2] = 0
		shadow_block.point_shadow_positions[i][3] = 0
	end

	shadow_block.point_shadow_count = 0

	for light_index, light in ipairs(lights) do
		local light_maps = maps_by_light[light.Owner]

		if
			not directional and
			light.Type == "light_directional" and
			light_maps and
			#light_maps > 0
		then
			for _, shadow_map in ipairs(light_maps) do
				if shadow_map.mode == "directional" then
					directional = light
					directional_map = shadow_map
					directional_light_index = light_index - 1

					break
				end
			end
		elseif (light.Type == "light_point" or light.Type == "light_spot") and light_maps then
			for _, shadow_map in ipairs(light_maps) do
				if shadow_map.mode ~= "point" then goto continue_light end

				local position = light.Owner.transform:GetWorldPosition()
				local distance_score = 0

				if camera_position then
					local dx = position.x - camera_position.x
					local dy = position.y - camera_position.y
					local dz = position.z - camera_position.z
					distance_score = math.max(math.sqrt(dx * dx + dy * dy + dz * dz) - shadow_map:GetFarPlane(), 0)
				end

				point_shadow_candidates[#point_shadow_candidates + 1] = {
					light = light,
					shadow_map = shadow_map,
					light_index = light_index - 1,
					distance_score = distance_score,
				}

				break
			end

			::continue_light::
		end
	end

	table.sort(point_shadow_candidates, sort_lights)

	for i = 1, math.min(#point_shadow_candidates, scene_lights.MAX_POINT_SHADOWS) do
		local candidate = point_shadow_candidates[i]
		local light = candidate.light
		local shadow_map = candidate.shadow_map
		local rendered = true

		for face = 1, 6 do
			if not shadow_map.cascade[face].is_sampleable then
				rendered = false

				break
			end
		end

		if not rendered then goto continue end

		point_shadow_count = point_shadow_count + 1
		shadow_block.point_shadow_map_indices[point_shadow_count - 1] = self:GetCubeMapTextureIndex(shadow_map:GetDepthTexture())
		light.Owner.transform:GetWorldPosition():CopyToFloatPointer(shadow_block.point_shadow_positions[point_shadow_count - 1])
		shadow_block.point_shadow_positions[point_shadow_count - 1][3] = shadow_map:GetFarPlane()
		shadow_block.point_shadow_light_indices[point_shadow_count - 1] = candidate.light_index

		::continue::
	end

	shadow_block.point_shadow_count = point_shadow_count

	if sun then
		write_sun_shadows(self, shadow_block, sun)

		if shadow_block.cascade_count == 0 then
			sun = nil
			sun_light_index = -1
		else
			shadow_block.directional_shadow_light_index = sun_light_index
		end
	end

	if directional and directional_map and directional_map.cascade[1].is_sampleable then
		local shadow_map = directional_map
		shadow_block.local_directional_shadow_map_index = self:GetTextureIndex(shadow_map:GetDepthTexture(1))
		shadow_block.local_directional_shadow_light_index = directional_light_index
		shadow_block.local_directional_shadow_texel_world_size = shadow_map:GetCascadeTexelWorldSize(1)
		shadow_block.local_directional_depth_quantum = shadow_map:GetDepthQuantum(1)
		shadow_map:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.local_directional_light_space_matrix)
	end
end

function scene_lights.GetPointShadowGLSL(data_block)
	return (
			[[
		int getPointShadowSlot(int light_index) {
			for (int i = 0; i < ]] .. data_block .. [[.shadows.point_shadow_count; i++) {
				if (]] .. data_block .. [[.shadows.point_shadow_light_indices[i] == light_index) {
					return i;
				}
			}

			return -1;
		}

		float samplePointShadowProjection(int shadow_map_idx, vec3 sample_dir, float current_depth, float bias, float filter_radius_texels) {
			vec3 lookup_dir = normalize(vec3(-sample_dir.x, sample_dir.y, sample_dir.z));
			float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
			float angular_radius = filter_radius_texels / max(face_size, 1.0);
			vec3 up = abs(lookup_dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 tangent = normalize(cross(up, lookup_dir));
			vec3 bitangent = cross(lookup_dir, tangent);
			float visibility = 0.0;
			const vec2 POISSON_DISK[8] = vec2[8](
				vec2(-0.326, -0.406),
				vec2(-0.840, -0.074),
				vec2(-0.696,  0.457),
				vec2(-0.203,  0.621),
				vec2( 0.962, -0.195),
				vec2( 0.473, -0.480),
				vec2( 0.519,  0.767),
				vec2( 0.185, -0.893)
			);

			for (int i = 0; i < 8; i++) {
				vec2 offset = POISSON_DISK[i] * angular_radius;
				vec3 tap_dir = normalize(lookup_dir + tangent * offset.x + bitangent * offset.y);
				float stored_depth = texture(CUBEMAP(shadow_map_idx), tap_dir).r;
				visibility += current_depth - bias > stored_depth ? 0.0 : 1.0;
			}

			return visibility / 8.0;
		}

		float calculatePointShadow(int shadow_slot, vec3 world_pos, vec3 normal, vec3 light_dir) {
			if (shadow_slot < 0 || shadow_slot >= ]] .. data_block .. [[.shadows.point_shadow_count) return 1.0;

			int shadow_map_idx = ]] .. data_block .. [[.shadows.point_shadow_map_indices[shadow_slot];
			if (shadow_map_idx < 0) return 1.0;

			vec3 light_pos = ]] .. data_block .. [[.shadows.point_shadow_positions[shadow_slot].xyz;
			float far_plane = ]] .. data_block .. [[.shadows.point_shadow_positions[shadow_slot].w;
			float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
			float texel_world_size = far_plane / max(face_size, 1.0);
			float normal_bias = max(texel_world_size * 2.0, 0.01);
			float bias_val = normal_bias * max(1.0 - dot(normal, light_dir), 0.2);
			vec3 offset_pos = world_pos + normal * bias_val;
			vec3 light_to_surface = offset_pos - light_pos;
			float light_distance = length(light_to_surface);

			if (light_distance <= 0.0001 || light_distance >= far_plane) return 1.0;

			vec3 sample_dir = light_to_surface / light_distance;
			float current_depth = light_distance / max(far_plane, 0.0001);
			float normalized_bias = max(bias_val / max(far_plane, 0.0001), 0.0005);
			return samplePointShadowProjection(shadow_map_idx, sample_dir, current_depth, normalized_bias, 1.25);
		}
		]]
		)
end

-- light_grid builds its pass from this module when it loads
light_grid = import("goluwa/render3d/light_grid.lua")
return scene_lights
