local Vec3 = import("goluwa/structs/vec3.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local directional_shadows = {}
directional_shadows.MAX_CASCADES = 4

function directional_shadows.GetPrimarySun(lights)
	lights = lights or render3d.GetLights()

	for i, light in ipairs(lights) do
		if light.Type == "light_sun" then return light, i - 1 end
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

	if sun and sun.Intensity ~= nil then return sun.Intensity end

	return atmosphere.GetSunIntensity()
end

function directional_shadows.GetPrimarySunColor(lights)
	lights = lights or render3d.GetLights()
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun and sun.Color then
		return Vec3(sun.Color.x or 1, sun.Color.y or 1, sun.Color.z or 1)
	end

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

	if not sun then return end

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
					if cascade_slot > directional_shadows.MAX_CASCADES then break end

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

-- GLSL fragment builders shared by GetMediumDirectionalShadowGLSL and
-- GetSurfaceDirectionalShadowGLSL. These run at shader-compile time, not per frame.
local POISSON_DISK_VALUES = [==[
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
]==]

local function getCascadeIndexGLSL(block_macro)
	local src = [==[
			int getCascadeIndex(vec3 world_pos) {
				float dist = -(@@BLOCK@@.view * vec4(world_pos, 1.0)).z;

				for (int i = 0; i < @@BLOCK@@.shadows.cascade_count; i++) {
					if (dist < @@BLOCK@@.shadows.cascade_splits[i]) {
						return i;
					}
				}

				return @@BLOCK@@.shadows.cascade_count - 1;
			}
]==]
	return (src:gsub("@@BLOCK@@", block_macro))
end

-- The cascade search loop, cascade blend band, and inset blend that both the
-- medium and surface shadow entry points share. `cascade_call` and `inset_call`
-- are GLSL call templates where "%s" is substituted with the cascade index
-- expression (for `inset_call`, "%s" is the out shadow variable).
local function shadowSearchBodyGLSL(block_macro, cascade_call, inset_call)
	local src = [==[
			int cascade_count = @@BLOCK@@.shadows.cascade_count;
			int cascade_idx = getCascadeIndex(world_pos);
			if (cascade_idx < 0) return 1.0;

			float dist = -(@@BLOCK@@.view * vec4(world_pos, 1.0)).z;
			// the split picks the cascade, but a zoomed or stale cascade may not
			// cover the point, in which case the next one is used
			float shadow = -1.0;

			for (; cascade_idx < cascade_count; cascade_idx++) {
				shadow = @@CASCADE_MAIN@@;
				if (shadow >= 0.0) break;
			}

			if (shadow < 0.0) return 1.0;

			if (cascade_idx < cascade_count - 1) {
				float previous_split = cascade_idx > 0 ? @@BLOCK@@.shadows.cascade_splits[cascade_idx - 1] : 0.0;
				float current_split = @@BLOCK@@.shadows.cascade_splits[cascade_idx];
				float cascade_span = max(current_split - previous_split, 0.0001);
				float blend_band = max(cascade_span * 0.15, 8.0);
				float blend_start = current_split - blend_band;

				if (dist > blend_start) {
					float next_shadow = @@CASCADE_NEXT@@;

					if (next_shadow >= 0.0) {
						float blend = clamp((dist - blend_start) / max(current_split - blend_start, 0.0001), 0.0, 1.0);
						shadow = mix(shadow, next_shadow, blend);
					}
				}
			}

			if (@@BLOCK@@.shadows.inset_shadow_map_index >= 0 && dist < @@BLOCK@@.shadows.inset_shadow_distance) {
				float inset_shadow = 1.0;

				if (@@INSET@@) {
					float inset_band = max(@@BLOCK@@.shadows.inset_shadow_distance * 0.25, 4.0);
					float inset_blend = 1.0 - smoothstep(
						max(@@BLOCK@@.shadows.inset_shadow_distance - inset_band, 0.0),
						@@BLOCK@@.shadows.inset_shadow_distance,
						dist
					);
					shadow = mix(shadow, inset_shadow, inset_blend);
				}
			}

			return shadow;
]==]
	src = (src:gsub("@@BLOCK@@", block_macro))
	src = (src:gsub("@@CASCADE_MAIN@@", string.format(cascade_call, "cascade_idx")))
	src = (src:gsub("@@CASCADE_NEXT@@", string.format(cascade_call, "cascade_idx + 1")))
	src = (src:gsub("@@INSET@@", string.format(inset_call, "inset_shadow")))
	return src
end

function directional_shadows.GetMediumDirectionalShadowGLSL(block_name, result_fn_name)
	result_fn_name = result_fn_name or "get_fog_sun_visibility"
	local header = "\t\t\t#define MEDIUM_DIRECTIONAL_SHADOW_BLOCK " .. block_name .. "\n" .. "\t\t\t#define MEDIUM_DIRECTIONAL_SHADOW_FN " .. result_fn_name .. "\n\n"
	local body = shadowSearchBodyGLSL(
		"MEDIUM_DIRECTIONAL_SHADOW_BLOCK",
		"sampleMediumShadowCascade(%s, world_pos, light_dir)",
		"sampleMediumInsetShadow(world_pos, light_dir, %s)"
	)
	return header .. getCascadeIndexGLSL("MEDIUM_DIRECTIONAL_SHADOW_BLOCK") .. [[

			bool projectMediumShadowMap(
				mat4 light_space_matrix,
				vec3 world_pos,
				vec3 light_dir,
				float texel_world_size,
				out vec3 proj_coords
			) {
				vec3 offset_pos = world_pos + light_dir * (texel_world_size * 2.0);
				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				return !(
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.002 ||
					proj_coords.x > 0.998 ||
					proj_coords.y < 0.002 ||
					proj_coords.y > 0.998
				);
			}

			float sampleMediumShadowProjection(int shadow_map_idx, vec3 proj_coords, float filter_radius_texels) {
				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));
				vec2 texel_size = 1.0 / shadow_size;
				float current_depth = proj_coords.z;
				float receiver_bias = 0.00002;
				float visibility = 0.0;
				const vec2 POISSON_DISK[12] = vec2[12](
					]] .. POISSON_DISK_VALUES .. [[
				);

				for (int i = 0; i < 12; ++i) {
					vec2 offset = POISSON_DISK[i] * filter_radius_texels * texel_size;
					float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + offset).r;
					visibility += current_depth - receiver_bias > pcf_depth ? 0.0 : 1.0;
				}

				return visibility / 12.0;
			}

			// returns -1.0 when the cascade does not cover the point
			float sampleMediumShadowCascade(int cascade_idx, vec3 world_pos, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_count) return -1.0;

				int shadow_map_idx = MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return -1.0;

				vec3 proj_coords;

				if (!projectMediumShadowMap(
					MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.light_space_matrices[cascade_idx],
					world_pos,
					light_dir,
					MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_texel_world_sizes[cascade_idx],
					proj_coords
				)) {
					return -1.0;
				}

				return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleMediumInsetShadow(vec3 world_pos, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index < 0) return false;
				vec3 proj_coords;


				if (!projectMediumShadowMap(
					MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_light_space_matrix,
					world_pos,
					light_dir,
					MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_texel_world_size,
					proj_coords
				)) {
					return false;
				}
				shadow = sampleMediumShadowProjection(MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float MEDIUM_DIRECTIONAL_SHADOW_FN(vec3 world_pos, vec3 light_dir) {
				if (get_fog_sun_horizon_visibility(light_dir) <= 0.0001) {
					return 0.0;
				}

				if (MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_count <= 0 || MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.shadow_map_indices[0] < 0) {
					return 1.0;
				}

				]] .. body .. [[
			}

				#undef MEDIUM_DIRECTIONAL_SHADOW_FN
				#undef MEDIUM_DIRECTIONAL_SHADOW_BLOCK
		]]
end

function directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, result_fn_name, options)
	result_fn_name = result_fn_name or "calculateShadow"
	options = options or {}
	local normal_expr = options.normal_expr or "normal"
	local header = (
			"\t\t\t#define DIRECTIONAL_SHADOW_BLOCK " .. block_name .. "\n" .. "\t\t\t#define DIRECTIONAL_SHADOW_FN " .. result_fn_name .. "\n" .. "\t\t\t#define DIRECTIONAL_SHADOW_NORMAL " .. normal_expr .. "\n\n"
		)
	local body = shadowSearchBodyGLSL(
		"DIRECTIONAL_SHADOW_BLOCK",
		"sampleShadowCascade(%s, world_pos, normal, light_dir)",
		"sampleInsetShadow(world_pos, normal, light_dir, %s)"
	)
	return header .. [[
			const vec2 SHADOW_POISSON_DISK[12] = vec2[12](
				]] .. POISSON_DISK_VALUES .. [[
			);
	]] .. getCascadeIndexGLSL("DIRECTIONAL_SHADOW_BLOCK") .. [[

			bool projectShadowMap(
				mat4 light_space_matrix,
				vec3 world_pos,
				vec3 normal,
				vec3 light_dir,
				float texel_world_size,
				out vec3 proj_coords
			) {
				vec3 offset_pos = world_pos;
				float light_offset = texel_world_size;

				if (dot(normal, normal) > 1e-6) {
					float cos_theta = clamp(dot(DIRECTIONAL_SHADOW_NORMAL, light_dir), 0.0, 1.0);
					float sin_theta = sqrt(1.0 - cos_theta * cos_theta);
					float tan_theta = min(sin_theta / max(cos_theta, 0.05), 4.0);
					offset_pos += DIRECTIONAL_SHADOW_NORMAL * (texel_world_size * sin_theta);
					light_offset += texel_world_size * 0.5 * tan_theta;
				}

				offset_pos += (light_dir * light_offset)*0.25;
				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;
				return !(
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.002 ||
					proj_coords.x > 0.998 ||
					proj_coords.y < 0.002 ||
					proj_coords.y > 0.998
				);
			}

			float sampleShadowProjection(int shadow_map_idx, vec3 proj_coords, float filter_radius_texels) {
				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));
				vec2 texel_size = 1.0 / shadow_size;
				float current_depth = proj_coords.z;
				float receiver_bias = 0;
				float visibility = 0.0;

				for (int i = 0; i < 12; ++i) {
					vec2 offset = SHADOW_POISSON_DISK[i] * filter_radius_texels * texel_size;
					float pcf_depth = texture(TEXTURE(shadow_map_idx), proj_coords.xy + offset).r;
					visibility += current_depth - receiver_bias > pcf_depth ? 0.0 : 1.0;
				}

				return visibility / 12.0;
			}

			// returns -1.0 when the cascade does not cover the point
			float sampleShadowCascade(int cascade_idx, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_count) return -1.0;

				int shadow_map_idx = DIRECTIONAL_SHADOW_BLOCK.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return -1.0;

				vec3 proj_coords;

				if (!projectShadowMap(
					DIRECTIONAL_SHADOW_BLOCK.shadows.light_space_matrices[cascade_idx],
					world_pos,
					normal,
					light_dir,
					DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_texel_world_sizes[cascade_idx],
					proj_coords
				)) {
					return -1.0;
				}

				return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleInsetShadow(vec3 world_pos, vec3 normal, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index < 0) return false;

				vec3 proj_coords;

				if (!projectShadowMap(
					DIRECTIONAL_SHADOW_BLOCK.shadows.inset_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_texel_world_size,
					proj_coords
				)) {
					return false;
				}

				shadow = sampleShadowProjection(DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float DIRECTIONAL_SHADOW_FN(vec3 world_pos, vec3 normal, vec3 light_dir) {
				]] .. body .. [[
			}

				#undef DIRECTIONAL_SHADOW_NORMAL
				#undef DIRECTIONAL_SHADOW_FN
				#undef DIRECTIONAL_SHADOW_BLOCK
		]]
end

function directional_shadows.GetLocalDirectionalShadowGLSL(block_name)
	return (
			[[
		float calculateLocalDirectionalShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
			int shadow_map_idx = ]] .. block_name .. [[.shadows.local_directional_shadow_map_index;

			if (shadow_map_idx < 0) return 1.0;

			vec3 proj_coords;

			if (!projectShadowMap(
				]] .. block_name .. [[.shadows.local_directional_light_space_matrix,
				world_pos,
				normal,
				light_dir,
				]] .. block_name .. [[.shadows.local_directional_shadow_texel_world_size,
				proj_coords
			)) {
				return 1.0;
			}

			return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
		}
		]]
		)
end

return directional_shadows
