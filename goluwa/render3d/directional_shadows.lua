local Vec3 = import("goluwa/structs/vec3.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = {}
directional_shadows.MAX_CASCADES = 4

function directional_shadows.GetPrimarySun(lights)
	lights = lights or render3d.GetLights()

	for i, light in ipairs(lights) do
		if light.LightType == "sun" then return light, i - 1 end
	end

	return nil, -1
end

function directional_shadows.GetPrimarySunDirection(lights)
	lights = lights or render3d.GetLights()
	local sun_dir = Vec3(0, 1, 0)
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then sun_dir = sun.Owner.transform:GetRotation():GetBackward() end

	return sun_dir
end

function directional_shadows.GetPrimarySunIntensity(lights)
	lights = lights or render3d.GetLights()
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then return sun.Intensity end

	return atmosphere.GetSunIntensity()
end

function directional_shadows.GetPrimarySunColor(lights)
	lights = lights or render3d.GetLights()
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then return sun.Color end

	return Vec3(1, 1, 1)
end

function directional_shadows.BuildFogShadowBlockLayout()
	local max_cascades = directional_shadows.MAX_CASCADES
	return {
		{"light_space_matrices", "mat4", max_cascades},
		{"inset_light_space_matrix", "mat4"},
		{"cascade_splits", "float", max_cascades},
		{"cascade_texel_world_sizes", "float", max_cascades},
		{"inset_shadow_distance", "float"},
		{"inset_shadow_texel_world_size", "float"},
		{"shadow_map_indices", "int", max_cascades},
		{"inset_shadow_map_index", "int"},
		{"cascade_count", "int"},
	}
end

function directional_shadows.WriteFogShadowBlock(self, shadow_block, lights)
	local sun = directional_shadows.GetPrimarySun(lights)
	local max_cascades = directional_shadows.MAX_CASCADES

	for i = 0, max_cascades - 1 do
		shadow_block.shadow_map_indices[i] = -1
		shadow_block.cascade_splits[i] = -1
		shadow_block.cascade_texel_world_sizes[i] = 0
	end

	shadow_block.inset_shadow_map_index = -1
	shadow_block.inset_shadow_distance = 0
	shadow_block.inset_shadow_texel_world_size = 0
	shadow_block.cascade_count = 0

	for i = 0, 15 do
		shadow_block.inset_light_space_matrix[i] = 0
	end

	if not sun or not sun:GetCastShadows() then return end

	local shadow_map = sun:GetShadowMap()
	local cascade_count = shadow_map:GetCascadeCount()

	for i = 1, cascade_count do
		shadow_block.shadow_map_indices[i - 1] = self:GetTextureIndex(shadow_map:GetDepthTexture(i))
		shadow_map:GetLightSpaceMatrix(i):CopyToFloatPointer(shadow_block.light_space_matrices[i - 1])
		shadow_block.cascade_splits[i - 1] = shadow_map:GetCascadeSplits()[i] or -1
		shadow_block.cascade_texel_world_sizes[i - 1] = shadow_map:GetCascadeTexelWorldSize(i)
	end

	shadow_block.cascade_count = cascade_count

	if sun.InsetShadowMap then
		shadow_block.inset_shadow_map_index = self:GetTextureIndex(sun.InsetShadowMap:GetDepthTexture(1))
		sun.InsetShadowMap:GetLightSpaceMatrix(1):CopyToFloatPointer(shadow_block.inset_light_space_matrix)
		shadow_block.inset_shadow_distance = sun.InsetShadowMap:GetCascadeSplits()[1] or 0
		shadow_block.inset_shadow_texel_world_size = sun.InsetShadowMap:GetCascadeTexelWorldSize(1)
	end
end

function directional_shadows.GetMediumDirectionalShadowGLSL(block_name, result_fn_name)
	result_fn_name = result_fn_name or "get_fog_sun_visibility"
	return (
		[[
			int getCascadeIndex(vec3 world_pos) {
				float dist = -(%s.view * vec4(world_pos, 1.0)).z;

				for (int i = 0; i < %s.shadows.cascade_count; i++) {
					if (dist < %s.shadows.cascade_splits[i]) {
						return i;
					}
				}

				return %s.shadows.cascade_count - 1;
			}

			bool projectMediumShadowMap(
				mat4 light_space_matrix,
				vec3 world_pos,
				vec3 light_dir,
				float texel_world_size,
				out vec3 proj_coords
			) {
				float medium_bias = max(texel_world_size * 1.5, 0.0005);
				vec3 offset_pos = world_pos + light_dir * medium_bias;
				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				return !(
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.0 ||
					proj_coords.x > 1.0 ||
					proj_coords.y < 0.0 ||
					proj_coords.y > 1.0
				);
			}

			float sampleMediumShadowProjection(int shadow_map_idx, vec3 proj_coords, float filter_radius_texels) {
				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));
				vec2 texel_size = 1.0 / shadow_size;
				float current_depth = proj_coords.z;
				float receiver_bias = 0.00002;
				float visibility = 0.0;
				const vec2 POISSON_DISK[12] = vec2[12](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893),
					vec2( 0.507,  0.064),
					vec2( 0.896,  0.412),
					vec2(-0.322, -0.933),
					vec2(-0.792, -0.598)
				);

				for (int i = 0; i < 12; ++i) {
					vec2 offset = POISSON_DISK[i] * filter_radius_texels * texel_size;
					float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + offset).r;
					visibility += current_depth - receiver_bias > pcf_depth ? 0.0 : 1.0;
				}

				return visibility / 12.0;
			}

			float sampleMediumShadowCascade(int cascade_idx, vec3 world_pos, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= %s.shadows.cascade_count) return 1.0;

				int shadow_map_idx = %s.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectMediumShadowMap(
					%s.shadows.light_space_matrices[cascade_idx],
					world_pos,
					light_dir,
					%s.shadows.cascade_texel_world_sizes[cascade_idx],
					proj_coords
				)) {
					return 1.0;
				}

				return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleMediumInsetShadow(vec3 world_pos, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (%s.shadows.inset_shadow_map_index < 0) return false;

				vec3 proj_coords;

				if (!projectMediumShadowMap(
					%s.shadows.inset_light_space_matrix,
					world_pos,
					light_dir,
					%s.shadows.inset_shadow_texel_world_size,
					proj_coords
				)) {
					return false;
				}

				shadow = sampleMediumShadowProjection(%s.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float %s(vec3 world_pos, vec3 light_dir) {
				if (get_fog_sun_horizon_visibility(light_dir) <= 0.0001) {
					return 0.0;
				}

				if (%s.shadows.cascade_count <= 0 || %s.shadows.shadow_map_indices[0] < 0) {
					return 1.0;
				}

				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;

				float dist = -(%s.view * vec4(world_pos, 1.0)).z;
				float shadow = sampleMediumShadowCascade(cascade_idx, world_pos, light_dir);

				if (cascade_idx < %s.shadows.cascade_count - 1) {
					float previous_split = cascade_idx > 0 ? %s.shadows.cascade_splits[cascade_idx - 1] : 0.0;
					float current_split = %s.shadows.cascade_splits[cascade_idx];
					float cascade_span = max(current_split - previous_split, 0.0001);
					float blend_band = max(cascade_span * 0.15, 8.0);
					float blend_start = current_split - blend_band;

					if (dist > blend_start) {
						float next_shadow = sampleMediumShadowCascade(cascade_idx + 1, world_pos, light_dir);
						float blend = clamp((dist - blend_start) / max(current_split - blend_start, 0.0001), 0.0, 1.0);
						shadow = mix(shadow, next_shadow, blend);
					}
				}

				if (%s.shadows.inset_shadow_map_index >= 0 && dist < %s.shadows.inset_shadow_distance) {
					float inset_shadow = 1.0;

					if (sampleMediumInsetShadow(world_pos, light_dir, inset_shadow)) {
						float inset_band = max(%s.shadows.inset_shadow_distance * 0.25, 4.0);
						float inset_blend = 1.0 - smoothstep(
							max(%s.shadows.inset_shadow_distance - inset_band, 0.0),
							%s.shadows.inset_shadow_distance,
							dist
						);
						shadow = mix(shadow, inset_shadow, inset_blend);
					}
				}

				return shadow;
			}
		]]
	):format(
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		result_fn_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name
	)
end

function directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, result_fn_name, options)
	result_fn_name = result_fn_name or "calculateShadow"
	options = options or {}
	local normal_expr = options.normal_expr or "normal"
	return (
		[[
			float getShadowReceiverPlaneBias(vec2 uv, float current_depth, vec2 texel_size, float filter_radius_texels) {
				vec2 uv_dx = dFdx(uv);
				vec2 uv_dy = dFdy(uv);
				float depth_dx = dFdx(current_depth);
				float depth_dy = dFdy(current_depth);
				float det = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;

				if (abs(det) < 1e-8) {
					return 0.0;
				}

				vec2 depth_grad_uv = vec2(
					(depth_dx * uv_dy.y - depth_dy * uv_dx.y) / det,
					(depth_dy * uv_dx.x - depth_dx * uv_dy.x) / det
				);
				return dot(abs(depth_grad_uv), texel_size * filter_radius_texels);
			}

			int getCascadeIndex(vec3 world_pos) {
				float dist = -(%s.view * vec4(world_pos, 1.0)).z;

				for (int i = 0; i < %s.shadows.cascade_count; i++) {
					if (dist < %s.shadows.cascade_splits[i]) {
						return i;
					}
				}

				return %s.shadows.cascade_count - 1;
			}

			bool projectShadowMap(
				mat4 light_space_matrix,
				vec3 world_pos,
				vec3 normal,
				vec3 light_dir,
				float texel_world_size,
				out vec3 proj_coords
			) {
				vec3 offset_pos = world_pos;

				if (dot(normal, normal) > 1e-6) {
					float normal_bias = max(texel_world_size * 1.5, 0.0005);
					float bias_val = normal_bias * max(1.0 - dot(%s, light_dir), 0.15);
					offset_pos += %s * bias_val;
				}

				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				return !(
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.0 ||
					proj_coords.x > 1.0 ||
					proj_coords.y < 0.0 ||
					proj_coords.y > 1.0
				);
			}

			float sampleShadowProjection(int shadow_map_idx, vec3 proj_coords, float filter_radius_texels) {
				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));
				vec2 texel_size = 1.0 / shadow_size;
				float current_depth = proj_coords.z;
				float receiver_bias = getShadowReceiverPlaneBias(proj_coords.xy, current_depth, texel_size, filter_radius_texels);
				receiver_bias = max(receiver_bias, 0.00002);
				float visibility = 0.0;
				const vec2 POISSON_DISK[12] = vec2[12](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893),
					vec2( 0.507,  0.064),
					vec2( 0.896,  0.412),
					vec2(-0.322, -0.933),
					vec2(-0.792, -0.598)
				);

				for (int i = 0; i < 12; ++i) {
					vec2 offset = POISSON_DISK[i] * filter_radius_texels * texel_size;
					float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + offset).r;
					visibility += current_depth - receiver_bias > pcf_depth ? 0.0 : 1.0;
				}

				return visibility / 12.0;
			}

			float sampleShadowCascade(int cascade_idx, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= %s.shadows.cascade_count) return 1.0;

				int shadow_map_idx = %s.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectShadowMap(
					%s.shadows.light_space_matrices[cascade_idx],
					world_pos,
					normal,
					light_dir,
					%s.shadows.cascade_texel_world_sizes[cascade_idx],
					proj_coords
				)) {
					return 1.0;
				}

				return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleInsetShadow(vec3 world_pos, vec3 normal, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (%s.shadows.inset_shadow_map_index < 0) return false;

				vec3 proj_coords;

				if (!projectShadowMap(
					%s.shadows.inset_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					%s.shadows.inset_shadow_texel_world_size,
					proj_coords
				)) {
					return false;
				}

				shadow = sampleShadowProjection(%s.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float %s(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int cascade_idx = getCascadeIndex(world_pos);
				if (cascade_idx < 0) return 1.0;

				float dist = -(%s.view * vec4(world_pos, 1.0)).z;
				float shadow = sampleShadowCascade(cascade_idx, world_pos, normal, light_dir);

				if (cascade_idx < %s.shadows.cascade_count - 1) {
					float previous_split = cascade_idx > 0 ? %s.shadows.cascade_splits[cascade_idx - 1] : 0.0;
					float current_split = %s.shadows.cascade_splits[cascade_idx];
					float cascade_span = max(current_split - previous_split, 0.0001);
					float blend_band = max(cascade_span * 0.15, 8.0);
					float blend_start = current_split - blend_band;

					if (dist > blend_start) {
						float next_shadow = sampleShadowCascade(cascade_idx + 1, world_pos, normal, light_dir);
						float blend = clamp((dist - blend_start) / max(current_split - blend_start, 0.0001), 0.0, 1.0);
						shadow = mix(shadow, next_shadow, blend);
					}
				}

				if (%s.shadows.inset_shadow_map_index >= 0 && dist < %s.shadows.inset_shadow_distance) {
					float inset_shadow = 1.0;

					if (sampleInsetShadow(world_pos, normal, light_dir, inset_shadow)) {
						float inset_band = max(%s.shadows.inset_shadow_distance * 0.25, 4.0);
						float inset_blend = 1.0 - smoothstep(
							max(%s.shadows.inset_shadow_distance - inset_band, 0.0),
							%s.shadows.inset_shadow_distance,
							dist
						);
						shadow = mix(shadow, inset_shadow, inset_blend);
					}
				}

				return shadow;
			}
		]]
	):format(
		block_name,
		block_name,
		block_name,
		block_name,
		normal_expr,
		normal_expr,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		result_fn_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name
	)
end

return directional_shadows
