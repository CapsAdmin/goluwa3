local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local directional_shadows = {}
directional_shadows.MAX_CASCADES = 4

function directional_shadows.GetPrimarySun(lights)
	for i, light in ipairs(lights) do
		if light.Type == "light_sun" then return light, i - 1 end
	end

	return nil, -1
end

function directional_shadows.GetPrimarySunDirection(lights)
	local sun_dir = Vec3(0, 1, 0)
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then sun_dir = sun.Owner.transform:GetRotation():GetBackward() end

	return sun_dir
end

function directional_shadows.GetPrimarySunIlluminance(lights)
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then return sun:GetPhotometricAmount() end

	return atmosphere.GetSunIlluminance()
end

function directional_shadows.GetPrimarySunColor(lights)
	local sun = directional_shadows.GetPrimarySun(lights)

	if sun then return Vec3(sun.Color.r, sun.Color.g, sun.Color.b) end

	return Vec3(1, 1, 1)
end

do
	local CLEAR_SUN_RADIUS_TAN = math.tan(atmosphere.SUN_ANGULAR_RADIUS)
	local OVERCAST_SUN_RADIUS_TAN = math.tan(math.rad(6))
	local FULL_SPREAD_DIFFUSION = 0.6

	function directional_shadows.GetSunAngularRadiusTan()
		local t = math.clamp(clouds.GetSunDiffusion() / FULL_SPREAD_DIFFUSION, 0, 1)
		return math.lerp(t * t * (3 - 2 * t), CLEAR_SUN_RADIUS_TAN, OVERCAST_SUN_RADIUS_TAN)
	end
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
		{"sun_angular_radius_tan", "float"},
		unpack(clouds.GetShadowBlockLayout()),
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
	shadow_block.sun_angular_radius_tan = directional_shadows.GetSunAngularRadiusTan()
	clouds.WriteShadowBlock(self, shadow_block)

	for i = 0, 15 do
		shadow_block.inset_light_space_matrix[i] = 0
	end

	if not sun then return end

	local cascade_slot = 1
	local sun_entity = sun.Owner

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map:IsEnabled() and shadow_map.light == sun_entity then
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

local function shadowSearchBodyGLSL(block_macro, cascade_call, inset_call)
	local src = [==[
			int cascade_count = @@BLOCK@@.shadows.cascade_count;
			int cascade_idx = getCascadeIndex(world_pos);
			if (cascade_idx < 0) return 1.0;

			float dist = -(@@BLOCK@@.view * vec4(world_pos, 1.0)).z;
			float inset_distance = @@BLOCK@@.shadows.inset_shadow_distance;

			// the inset takes over completely closer than its blend band, the cascades would be
			// looked up for nothing
			if (@@BLOCK@@.shadows.inset_shadow_map_index >= 0 && dist <= max(inset_distance - max(inset_distance * 0.25, 4.0), 0.0)) {
				float inset_shadow = 1.0;

				if (@@INSET@@) {
					shadow_texel_world_size = @@BLOCK@@.shadows.cascade_texel_world_sizes[cascade_idx];
					return inset_shadow;
				}
			}

			// the split picks the cascade, but a zoomed or stale cascade may not
			// cover the point, in which case the next one is used
			float shadow = -1.0;

			for (; cascade_idx < cascade_count; cascade_idx++) {
				shadow = @@CASCADE_MAIN@@;
				if (shadow >= 0.0) break;
			}

			if (shadow < 0.0) return 1.0;

			shadow_texel_world_size = @@BLOCK@@.shadows.cascade_texel_world_sizes[cascade_idx];

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
						shadow_texel_world_size = @@BLOCK@@.shadows.cascade_texel_world_sizes[cascade_idx + 1];
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
	return header .. clouds.GetShadowGLSL("MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows") .. getCascadeIndexGLSL("MEDIUM_DIRECTIONAL_SHADOW_BLOCK") .. [[
			// the texel size of the coarsest cascade the last lookup used
			float shadow_texel_world_size = 0.0;


			// no offset towards the light like a surface needs against acne: it
			// would carry points near a wall through it into the light
			bool projectMediumShadowMap(mat4 light_space_matrix, vec3 world_pos, out vec3 proj_coords) {
				vec4 light_space_pos = light_space_matrix * vec4(world_pos, 1.0);
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
					float pcf_depth = textureLod(TEXTURE(shadow_map_idx), proj_coords.xy + offset, 0.0).r;
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

				if (!projectMediumShadowMap(MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.light_space_matrices[cascade_idx], world_pos, proj_coords)) {
					return -1.0;
				}

				return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			bool sampleMediumInsetShadow(vec3 world_pos, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index < 0) return false;
				vec3 proj_coords;


				if (!projectMediumShadowMap(MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_light_space_matrix, world_pos, proj_coords)) {
					return false;
				}
				shadow = sampleMediumShadowProjection(MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index, proj_coords, 1.0);
				return true;
			}

			float ]] .. result_fn_name .. [[_without_clouds(vec3 world_pos, vec3 light_dir) {
				if (MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_count <= 0 || MEDIUM_DIRECTIONAL_SHADOW_BLOCK.shadows.shadow_map_indices[0] < 0) {
					return 1.0;
				}

				]] .. body .. [[
			}

			float MEDIUM_DIRECTIONAL_SHADOW_FN(vec3 world_pos, vec3 light_dir) {
				if (get_fog_sun_horizon_visibility(light_dir) <= 0.0001) {
					return 0.0;
				}

				float cloud_shadow = get_cloud_shadow(world_pos);

				if (cloud_shadow <= 0.0001) return 0.0;

				return cloud_shadow * ]] .. result_fn_name .. [[_without_clouds(world_pos, light_dir);
			}

				#undef MEDIUM_DIRECTIONAL_SHADOW_FN
				#undef MEDIUM_DIRECTIONAL_SHADOW_BLOCK
		]]
end

local SHADOW_PROJECTION_GLSL = [[
			float get_shadow_facing(vec3 normal, vec3 light_dir) {
				return smoothstep(0.0, 0.1, dot(normal, light_dir));
			}

			// percentage closer soft shadows: the penumbra is the distance to the blockers times the
			// tangent of the sun's angular radius, which clouds widen from a disc into a glow
			const float SOFT_SHADOW_MAX_BLOCKER_DISTANCE = 30.0;
			const float SOFT_SHADOW_MAX_TEXELS = 32.0;

			// returns -1.0 when the penumbra is no wider than the regular filter
			float sampleSoftShadowMap(
				int shadow_map_idx,
				vec3 proj_coords,
				vec2 shadow_size,
				float texel_world_size,
				float depth_per_meter,
				float tan_slope,
				vec3 world_pos,
				float filter_radius_texels,
				float sun_radius_tan,
				float noise_phase
			) {
				float search_texels = min(sun_radius_tan * SOFT_SHADOW_MAX_BLOCKER_DISTANCE / texel_world_size, SOFT_SHADOW_MAX_TEXELS);

				if (search_texels <= filter_radius_texels) return -1.0;

				// a rotation per point turns the banding of the few taps into grain. the point's bits are hashed,
				// a hash of a linear function of the position draws diagonal streaks. the phase turns it every
				// frame, so a temporal antialiasing averages different taps
				uvec3 bits = floatBitsToUint(world_pos) * 1664525u + 1013904223u;
				bits.x += bits.y * bits.z;
				bits.y += bits.z * bits.x;
				bits.z += bits.x * bits.y;
				bits ^= bits >> 16u;
				bits.x += bits.y * bits.z;
				float angle = (float(bits.x >> 8u) / 16777216.0 + noise_phase) * 6.2831853;
				mat2 rotation = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));
				// how much deeper a tilted receiver is at a tap this many meters away, so it doesn't shadow itself
				float tolerance_per_meter = tan_slope * depth_per_meter;
				const vec2 SEARCH[5] = vec2[5](vec2(0.0), vec2(0.7, 0.0), vec2(-0.7, 0.0), vec2(0.0, 0.7), vec2(0.0, -0.7));
				float blocker_sum = 0.0;
				float blocker_count = 0.0;

				for (int i = 0; i < 5; i++) {
					vec2 offset = rotation * SEARCH[i] * search_texels;
					float tolerance = length(offset) * texel_world_size * tolerance_per_meter;
					vec4 depths = textureGather(TEXTURE(shadow_map_idx), proj_coords.xy + offset / shadow_size, 0);
					vec4 blocker = vec4(lessThan(depths, vec4(proj_coords.z - tolerance)));
					blocker_sum += dot(blocker, depths);
					blocker_count += dot(blocker, vec4(1.0));
				}

				// nothing found, but a blocker thinner than the taps can still be there
				if (blocker_count <= 0.0) return -1.0;

				float blocker_distance = (proj_coords.z - blocker_sum / blocker_count) / depth_per_meter;
				float radius_texels = min(blocker_distance * sun_radius_tan / texel_world_size, SOFT_SHADOW_MAX_TEXELS);

				if (radius_texels <= filter_radius_texels) return -1.0;

				const vec2 POISSON_DISK[12] = vec2[12](
					]] .. POISSON_DISK_VALUES .. [[
				);
				float visibility = 0.0;

				for (int i = 0; i < 12; i++) {
					vec2 offset = rotation * POISSON_DISK[i] * radius_texels;
					float tolerance = length(offset) * texel_world_size * tolerance_per_meter;
					vec2 st = (proj_coords.xy + offset / shadow_size) * shadow_size - 0.5;
					vec2 f = fract(st);
					vec4 depths = textureGather(TEXTURE(shadow_map_idx), (floor(st) + 1.0) / shadow_size, 0);
					vec4 lit = step(vec4(proj_coords.z - tolerance), depths);
					visibility += mix(mix(lit.w, lit.z, f.x), mix(lit.x, lit.y, f.x), f.y);
				}

				return visibility / 12.0;
			}

			// returns -1.0 when the map does not cover the point
			float sampleShadowMap(
				int shadow_map_idx,
				mat4 light_space_matrix,
				float texel_world_size,
				vec3 world_pos,
				vec3 normal,
				vec3 light_dir,
				float filter_radius_texels,
				float sun_radius_tan,
				float noise_phase
			) {
				float n_dot_l = clamp(dot(normal, light_dir), 0.0, 1.0);
				float slope = sqrt(1.0 - n_dot_l * n_dot_l);
				vec3 depth_row = vec3(light_space_matrix[0].z, light_space_matrix[1].z, light_space_matrix[2].z);
				float depth_step_world = 2.0 / (65535.0 * max(length(depth_row), 1e-8));
				vec3 offset_pos = world_pos +
					normal * (texel_world_size * (0.5 + 1.5 * slope) * filter_radius_texels) +
					light_dir * max(texel_world_size, depth_step_world);
				vec4 light_space_pos = light_space_matrix * vec4(offset_pos, 1.0);
				vec3 proj_coords = light_space_pos.xyz / light_space_pos.w;
				proj_coords.xy = proj_coords.xy * 0.5 + 0.5;

				if (
					proj_coords.z > 1.0 ||
					proj_coords.z < 0.0 ||
					proj_coords.x < 0.002 ||
					proj_coords.x > 0.998 ||
					proj_coords.y < 0.002 ||
					proj_coords.y > 0.998
				) {
					return -1.0;
				}

				vec2 shadow_size = vec2(textureSize(TEXTURE(shadow_map_idx), 0));

				if (sun_radius_tan > 0.0) {
					float soft = sampleSoftShadowMap(
						shadow_map_idx,
						proj_coords,
						shadow_size,
						texel_world_size,
						max(length(depth_row), 1e-8),
						min(slope / max(n_dot_l, 0.2), 5.0),
						world_pos,
						filter_radius_texels,
						sun_radius_tan,
						noise_phase
					);

					if (soft >= 0.0) return soft;
				}

				// 2x2 bilinear PCF lookups spread over the filter radius, a tent
				// about two texels wide at radius 1
				float visibility = 0.0;

				for (int j = 0; j < 2; ++j) {
					for (int i = 0; i < 2; ++i) {
						vec2 st = (proj_coords.xy + (vec2(i, j) - 0.5) * filter_radius_texels / shadow_size) * shadow_size - 0.5;
						vec2 f = fract(st);
						vec4 depths = textureGather(TEXTURE(shadow_map_idx), (floor(st) + 1.0) / shadow_size, 0);
						vec4 lit = step(vec4(proj_coords.z), depths);
						visibility += mix(mix(lit.w, lit.z, f.x), mix(lit.x, lit.y, f.x), f.y);
					}
				}

				return visibility * 0.25;
			}
	]]

function directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, result_fn_name)
	result_fn_name = result_fn_name or "calculateShadow"
	local header = (
			"\t\t\t#define DIRECTIONAL_SHADOW_BLOCK " .. block_name .. "\n" .. "\t\t\t#define DIRECTIONAL_SHADOW_FN " .. result_fn_name .. "\n\n"
		)
	local body = shadowSearchBodyGLSL(
		"DIRECTIONAL_SHADOW_BLOCK",
		"sampleShadowCascade(%s, world_pos, normal, light_dir)",
		"sampleInsetShadow(world_pos, normal, light_dir, %s)"
	)
	return header .. clouds.GetShadowGLSL("DIRECTIONAL_SHADOW_BLOCK.shadows") .. getCascadeIndexGLSL("DIRECTIONAL_SHADOW_BLOCK") .. "\n" .. SHADOW_PROJECTION_GLSL .. [[
			// the texel size of the coarsest cascade the last lookup used
			float shadow_texel_world_size = 0.0;


			// returns -1.0 when the cascade does not cover the point
			float sampleShadowCascade(int cascade_idx, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (cascade_idx < 0 || cascade_idx >= DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_count) return -1.0;

				int shadow_map_idx = DIRECTIONAL_SHADOW_BLOCK.shadows.shadow_map_indices[cascade_idx];
				if (shadow_map_idx < 0) return -1.0;

				return sampleShadowMap(
					shadow_map_idx,
					DIRECTIONAL_SHADOW_BLOCK.shadows.light_space_matrices[cascade_idx],
					DIRECTIONAL_SHADOW_BLOCK.shadows.cascade_texel_world_sizes[cascade_idx],
					world_pos,
					normal,
					light_dir,
					1.0,
					DIRECTIONAL_SHADOW_BLOCK.shadows.sun_angular_radius_tan,
					DIRECTIONAL_SHADOW_BLOCK.shadows.noise_phase
				);
			}

			bool sampleInsetShadow(vec3 world_pos, vec3 normal, vec3 light_dir, out float shadow) {
				shadow = 1.0;
				if (DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index < 0) return false;

				float result = sampleShadowMap(
					DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_map_index,
					DIRECTIONAL_SHADOW_BLOCK.shadows.inset_light_space_matrix,
					DIRECTIONAL_SHADOW_BLOCK.shadows.inset_shadow_texel_world_size,
					world_pos,
					normal,
					light_dir,
					1.0,
					DIRECTIONAL_SHADOW_BLOCK.shadows.sun_angular_radius_tan,
					DIRECTIONAL_SHADOW_BLOCK.shadows.noise_phase
				);

				if (result < 0.0) return false;

				shadow = result;
				return true;
			}

			float calculateShadowUnfaded(vec3 world_pos, vec3 normal, vec3 light_dir) {
				]] .. body .. [[
			}

			// normal offsets the lookup. fading out towards the terminator is left to the
			// caller (get_shadow_facing), with a smooth normal: the geometric normal of a
			// tessellated surface would fade it triangle by triangle
			float DIRECTIONAL_SHADOW_FN(vec3 world_pos, vec3 normal, vec3 light_dir) {
				float shadow = calculateShadowUnfaded(world_pos, normal, light_dir);


				return shadow;
			}

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

			float shadow = sampleShadowMap(
				shadow_map_idx,
				]] .. block_name .. [[.shadows.local_directional_light_space_matrix,
				]] .. block_name .. [[.shadows.local_directional_shadow_texel_world_size,
				world_pos,
				normal,
				light_dir,
				2.0,
				0.0,
				0.0
			);

			return shadow < 0.0 ? 1.0 : shadow;
		}
		]]
		)
end

return directional_shadows
