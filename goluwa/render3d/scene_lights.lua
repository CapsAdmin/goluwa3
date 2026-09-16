local render3d = import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local system = import("goluwa/system.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local scene_lights = {}
scene_lights.MAX_LIGHTS = 128
scene_lights.MAX_CASCADES = directional_shadows.MAX_CASCADES
scene_lights.MAX_POINT_SHADOWS = 4

local function sort_lights(a, b)
	if a.last_update_frame ~= b.last_update_frame then
		return a.last_update_frame > b.last_update_frame
	end

	if a.distance_score ~= b.distance_score then
		return a.distance_score < b.distance_score
	end

	return a.light_index < b.light_index
end

local function is_frustum_cullable(light)
	local light_type = light.Type
	return light_type == "light_point" or light_type == "light_spot"
end

function scene_lights.IsLightVisible(light)
	if not is_frustum_cullable(light) then return true end

	local position = light.Owner.transform:GetPosition()
	return render3d.SphereInFrustum(position.x, position.y, position.z, light.Range)
end

local visible_lights = {}
local visible_instance_indices = {}
local visible_frame = -1

-- the lighting, fog and shadow submission all iterate this packed list so
-- the fragment shaders only loop over lights that can reach a visible pixel
function scene_lights.GetVisibleLights()
	local frame = system.GetFrameNumber()

	if visible_frame == frame then
		return visible_lights, visible_instance_indices
	end

	local all = render3d.GetLights()
	local count = 0

	for i = 1, math.min(#all, scene_lights.MAX_LIGHTS) do
		local light = all[i]

		if scene_lights.IsLightVisible(light) then
			count = count + 1
			visible_lights[count] = light
			visible_instance_indices[count] = i
		end
	end

	for i = count + 1, #visible_lights do
		visible_lights[i] = nil
		visible_instance_indices[i] = nil
	end

	visible_frame = frame
	return visible_lights, visible_instance_indices
end

function scene_lights.BuildLightsBlockLayout()
	return {
		{"position", "vec4"},
		{"direction", "vec4"},
		{"color", "vec4"},
		{"params", "vec4"},
	}
end

function scene_lights.BuildShadowsBlockLayout()
	return {
		{"light_space_matrices", "mat4", scene_lights.MAX_CASCADES},
		{"local_directional_light_space_matrix", "mat4"},
		{"inset_light_space_matrix", "mat4"},
		{"cascade_splits", "float", scene_lights.MAX_CASCADES},
		{"cascade_texel_world_sizes", "float", scene_lights.MAX_CASCADES},
		{"local_directional_shadow_texel_world_size", "float"},
		{"inset_shadow_distance", "float"},
		{"inset_shadow_texel_world_size", "float"},
		{"shadow_map_indices", "int", scene_lights.MAX_CASCADES},
		{"local_directional_shadow_map_index", "int"},
		{"inset_shadow_map_index", "int"},
		{"point_shadow_positions", "vec4", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_map_indices", "int", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_light_indices", "int", scene_lights.MAX_POINT_SHADOWS},
		{"point_shadow_count", "int"},
		{"directional_shadow_light_index", "int"},
		{"local_directional_shadow_light_index", "int"},
		{"cascade_count", "int"},
	}
end

function scene_lights.GetLightGLSLCode()
	return [=[
			int get_light_type(lights_t light) {
				return int(light.position.w);
			}

			vec3 get_light_direction(lights_t light) {
				return normalize(light.direction.xyz);
			}

			// Inverse square falloff that reaches exactly zero at the light's
			// range instead of cutting off with a visible edge.
			float get_light_distance_attenuation(float dist, float range) {
				float ratio = dist / range;
				float window = clamp(1.0 - ratio * ratio * ratio * ratio, 0.0, 1.0);
				return window * window / max(dist * dist, 0.0025);
			}

			bool get_light_vector_and_attenuation(lights_t light, vec3 world_pos, out vec3 L, out float attenuation) {
				int type = get_light_type(light);
				vec3 light_dir = get_light_direction(light);
				attenuation = 1.0;

				if (type == 0) {
					L = normalize(-light_dir);
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
					attenuation = get_light_distance_attenuation(dist, range);
					return true;
				}

				if (type == 2) {
					vec3 from_light = world_pos - light.position.xyz;
					float dist = length(from_light);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					// light_dir points back toward the source, so light travels
					// along -light_dir and surfaces behind the light are not lit
					float in_front = 1.0 - smoothstep(-0.1, 0.2, dot(from_light / dist, light_dir));

					if (in_front <= 0.0) {
						return false;
					}

					L = light_dir;
					attenuation = in_front * get_light_distance_attenuation(dist, range);
					return true;
				}

				if (type == 3) {
					vec3 from_light = world_pos - light.position.xyz;
					float dist = length(from_light);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					float inner_cone = clamp(light.params.y, -1.0, 1.0);
					float outer_cone = clamp(light.params.z, -1.0, inner_cone);
					float cone_attenuation = smoothstep(outer_cone, inner_cone, dot(light_dir, from_light / dist));
					L = normalize(light.position.xyz - world_pos);
					attenuation = cone_attenuation * get_light_distance_attenuation(dist, range);
					return true;
				}

				return false;
			}
		]=]
end

function scene_lights.WriteLightsBlock(lights_block, lights)
	for i = 0, scene_lights.MAX_LIGHTS - 1 do
		local data = lights_block[i]
		local light = lights[i + 1]

		if light then
			local rotation = light.Owner.transform:GetRotation()
			local direction = light.Type == "light_directional" and
				rotation:GetBackward() or
				rotation:GetForward()
			light.Owner.transform:GetPosition():CopyToFloatPointer(data.position)
			direction:CopyToFloatPointer(data.direction)

			if light.Type == "light_sun" then
				data.position[3] = 0
				data.params[0] = 0
				data.params[1] = 0
				data.params[2] = 0
			elseif light.Type == "light_point" then
				data.position[3] = 1
				data.params[0] = light.Range
				data.params[1] = 0
				data.params[2] = 0
			elseif light.Type == "light_directional" then
				data.position[3] = 2
				data.params[0] = light.Range
				data.params[1] = 0
				data.params[2] = 0
			elseif light.Type == "light_spot" then
				data.position[3] = 3
				data.params[0] = light.Range
				data.params[1] = math.cos(math.rad(light.InnerCone))
				data.params[2] = math.cos(math.rad(light.OuterCone))
			else
				error("Unknown light type: " .. tostring(light.Type), 2)
			end

			data.color[0] = light.Color.r
			data.color[1] = light.Color.g
			data.color[2] = light.Color.b
			data.color[3] = light.Intensity
			data.params[3] = 0
		else
			data.position[0] = 0
			data.position[1] = 0
			data.position[2] = 0
			data.position[3] = 0
			data.direction[0] = 0
			data.direction[1] = 0
			data.direction[2] = 1
			data.direction[3] = 0
			data.color[0] = 0
			data.color[1] = 0
			data.color[2] = 0
			data.color[3] = 0
			data.params[0] = 0
			data.params[1] = 0
			data.params[2] = 0
			data.params[3] = 0
		end
	end
end

local function write_sun_shadows(self, shadow_block, sun)
	local cascade_slot = 1
	local sun_entity = sun.Owner

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map.enabled and shadow_map.light == sun_entity then
			if shadow_map.role == "inset" then
				shadow_block.inset_shadow_map_index = self:GetTextureIndex(shadow_map:GetDepthTexture(1))
				shadow_map:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.inset_light_space_matrix)
				shadow_block.inset_shadow_distance = shadow_map:GetCascadeSplits()[1] or 0
				shadow_block.inset_shadow_texel_world_size = shadow_map:GetCascadeTexelWorldSize(1)
			else
				for i = 1, shadow_map:GetCascadeCount() do
					if cascade_slot > scene_lights.MAX_CASCADES then break end

					shadow_block.shadow_map_indices[cascade_slot - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
					shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(shadow_block.light_space_matrices[cascade_slot - 1])
					shadow_block.cascade_splits[cascade_slot - 1] = shadow_map:GetCascadeSplits()[i] or -1
					shadow_block.cascade_texel_world_sizes[cascade_slot - 1] = shadow_map:GetCascadeTexelWorldSize(i)
					cascade_slot = cascade_slot + 1
				end
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
		if shadow_map.enabled and shadow_map.light then
			local list = maps_by_light[shadow_map.light]

			if not list then
				list = {}
				maps_by_light[shadow_map.light] = list
			end

			list[#list + 1] = shadow_map
		end
	end

	local camera = render3d.GetRenderCamera()
	local camera_position = camera and camera:GetPosition()

	for i = 0, scene_lights.MAX_CASCADES - 1 do
		shadow_block.shadow_map_indices[i] = -1
		shadow_block.cascade_splits[i] = -1
		shadow_block.cascade_texel_world_sizes[i] = 0
	end

	shadow_block.inset_shadow_map_index = -1
	shadow_block.inset_shadow_distance = 0
	shadow_block.inset_shadow_texel_world_size = 0
	shadow_block.directional_shadow_light_index = -1
	shadow_block.local_directional_shadow_map_index = -1
	shadow_block.local_directional_shadow_light_index = -1
	shadow_block.local_directional_shadow_texel_world_size = 0
	shadow_block.cascade_count = 0

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
		if light_index > scene_lights.MAX_LIGHTS then break end

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
		elseif light.Type == "light_point" and light_maps then
			for _, shadow_map in ipairs(light_maps) do
				if shadow_map.mode ~= "point" then goto continue_light end

				local position = light.Owner.transform:GetPosition()
				local distance_score = 0

				if camera_position then
					local dx = position.x - camera_position.x
					local dy = position.y - camera_position.y
					local dz = position.z - camera_position.z
					distance_score = dx * dx + dy * dy + dz * dz
				end

				point_shadow_candidates[#point_shadow_candidates + 1] = {
					light = light,
					shadow_map = shadow_map,
					light_index = light_index - 1,
					last_update_frame = shadow_map.last_update_frame or -1,
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
		light.Owner.transform:GetPosition():CopyToFloatPointer(shadow_block.point_shadow_positions[point_shadow_count - 1])
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

return scene_lights
