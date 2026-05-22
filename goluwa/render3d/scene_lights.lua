local render3d = import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
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
					attenuation = 1.0 / max(dist * dist, 0.0025);
					return true;
				}

				if (type == 2 || type == 3) {
					vec3 from_light = world_pos - light.position.xyz;
					float dist = length(from_light);
					float range = max(light.params.x, 0.0001);

					if (dist <= 0.0001 || dist >= range) {
						return false;
					}

					vec3 cone_axis = light_dir;
					vec3 cone_dir = from_light / dist;
					float inner_cone = clamp(light.params.y, -1.0, 1.0);
					float outer_cone = clamp(light.params.z, -1.0, inner_cone);
					float cone_attenuation = smoothstep(outer_cone, inner_cone, dot(cone_axis, cone_dir));
					attenuation = cone_attenuation / max(dist * dist, 0.0025);
					L = type == 2 ? normalize(-light_dir) : normalize(light.position.xyz - world_pos);
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
			local direction = light.LightType == "directional" and
				rotation:GetBackward() or
				rotation:GetForward()
			light.Owner.transform:GetPosition():CopyToFloatPointer(data.position)
			direction:CopyToFloatPointer(data.direction)

			if light.LightType == "sun" then
				data.position[3] = 0
			elseif light.LightType == "point" then
				data.position[3] = 1
			elseif light.LightType == "directional" then
				data.position[3] = 2
			elseif light.LightType == "spot" then
				data.position[3] = 3
			else
				error("Unknown light type: " .. tostring(light.LightType), 2)
			end

			data.color[0] = light.Color.r
			data.color[1] = light.Color.g
			data.color[2] = light.Color.b
			data.color[3] = light.Intensity
			data.params[0] = light.Range
			data.params[1] = light.InnerCone
			data.params[2] = light.OuterCone
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

function scene_lights.WriteShadowBlock(self, shadow_block, lights)
	local sun, sun_light_index = directional_shadows.GetPrimarySun(lights)
	local directional = nil
	local directional_light_index = -1
	local point_shadow_count = 0
	local point_shadow_candidates = {}
	local camera = render3d.GetCamera()
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

		if not directional and light.LightType == "directional" and light:GetCastShadows() then
			directional = light
			directional_light_index = light_index - 1
		elseif light.LightType == "point" and light:GetCastShadows() then
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
				light_index = light_index - 1,
				last_update_frame = light.LastShadowUpdateFrame or -1,
				distance_score = distance_score,
			}
		end
	end

	table.sort(point_shadow_candidates, sort_lights)

	for i = 1, math.min(#point_shadow_candidates, scene_lights.MAX_POINT_SHADOWS) do
		local candidate = point_shadow_candidates[i]
		local light = candidate.light
		local shadow_map = light:GetShadowMap()
		point_shadow_count = point_shadow_count + 1
		shadow_block.point_shadow_map_indices[point_shadow_count - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture())
		light.Owner.transform:GetPosition():CopyToFloatPointer(shadow_block.point_shadow_positions[point_shadow_count - 1])
		shadow_block.point_shadow_positions[point_shadow_count - 1][3] = shadow_map:GetFarPlane()
		shadow_block.point_shadow_light_indices[point_shadow_count - 1] = candidate.light_index
	end

	shadow_block.point_shadow_count = point_shadow_count

	if sun and not sun:GetCastShadows() then
		sun = nil
		sun_light_index = -1
	end

	if sun then
		local shadow_map = sun:GetShadowMap()
		local cascade_count = shadow_map:GetCascadeCount()

		for i = 1, cascade_count do
			shadow_block.shadow_map_indices[i - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
			shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(shadow_block.light_space_matrices[i - 1])
			shadow_block.cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i] or -1
			shadow_block.cascade_texel_world_sizes[i - 1] = shadow_map:GetCascadeTexelWorldSize(i)
		end

		shadow_block.cascade_count = cascade_count
		shadow_block.directional_shadow_light_index = sun_light_index

		if sun.InsetShadowMap then
			shadow_block.inset_shadow_map_index = self:GetTextureIndex(sun.InsetShadowMap:GetDepthTexture(1))
			sun.InsetShadowMap:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.inset_light_space_matrix)
			shadow_block.inset_shadow_distance = sun.InsetShadowMap:GetCascadeSplits()[1] or 0
			shadow_block.inset_shadow_texel_world_size = sun.InsetShadowMap:GetCascadeTexelWorldSize(1)
		end
	end

	if directional then
		local shadow_map = directional:GetShadowMap()
		shadow_block.local_directional_shadow_map_index = self:GetTextureIndex(shadow_map:GetDepthTexture(1))
		shadow_block.local_directional_shadow_light_index = directional_light_index
		shadow_block.local_directional_shadow_texel_world_size = shadow_map:GetCascadeTexelWorldSize(1)
		shadow_map:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.local_directional_light_space_matrix)
	end
end

return scene_lights
