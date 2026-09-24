local screen_reconstruct = {}

function screen_reconstruct.GetWorldPosGLSL(block_name, options)
	options = options or {}
	local function_name = options.function_name or "get_world_pos"
	local uv_expr = options.uv_expr or "in_uv"
	local depth_name = options.depth_name or "depth"
	return (
		[[
			vec3 %s(float %s) {
				vec4 clip_pos = vec4(%s * 2.0 - 1.0, %s, 1.0);
				vec4 view_pos = %s.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (%s.inv_view * view_pos).xyz;
			}
	]]
	):format(function_name, depth_name, uv_expr, depth_name, block_name, block_name)
end

function screen_reconstruct.GetWorldPosFromUVGLSL(block_name, options)
	options = options or {}
	local function_name = options.function_name or "get_world_pos"
	local uv_name = options.uv_name or "uv"
	local depth_name = options.depth_name or "depth"
	return (
		[[
			vec3 %s(vec2 %s, float %s) {
				vec4 clip_pos = vec4(%s * 2.0 - 1.0, %s, 1.0);
				vec4 view_pos = %s.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				return (%s.inv_view * view_pos).xyz;
			}
	]]
	):format(function_name, uv_name, depth_name, uv_name, depth_name, block_name, block_name)
end

function screen_reconstruct.GetWorldRayGLSL(block_name, options)
	options = options or {}
	local function_name = options.function_name or "get_world_ray"
	local uv_expr = options.uv_expr or "in_uv"
	return (
		[[
			vec3 %s() {
				vec4 clip_pos = vec4(%s * 2.0 - 1.0, 1.0, 1.0);
				vec4 view_pos = %s.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (%s.inv_view * vec4(view_pos.xyz, 1.0)).xyz;
				return normalize(world_pos - %s.camera_position.xyz);
			}
	]]
	):format(function_name, uv_expr, block_name, block_name, block_name)
end

function screen_reconstruct.GetViewRayFromUVGLSL(block_name, options)
	options = options or {}
	local function_name = options.function_name or "get_view_ray"
	local uv_name = options.uv_name or "uv"
	return (
		[[
			vec3 %s(vec2 %s) {
				vec4 near_clip_pos = vec4(%s * 2.0 - 1.0, 0.0, 1.0);
				vec4 far_clip_pos = vec4(%s * 2.0 - 1.0, 1.0, 1.0);
				vec4 near_view_pos = %s.inv_projection * near_clip_pos;
				vec4 far_view_pos = %s.inv_projection * far_clip_pos;
				near_view_pos /= near_view_pos.w;
				far_view_pos /= far_view_pos.w;
				vec3 view_dir = far_view_pos.xyz - near_view_pos.xyz;
				return normalize(mat3(%s.inv_view) * view_dir);
			}
	]]
	):format(function_name, uv_name, uv_name, uv_name, block_name, block_name, block_name)
end

-- the surface's own normal (ignoring normal maps), from the positions of the
-- neighbouring depth pixels. Depth is linear in screen space across a plane, so
-- per axis the side whose two pixels extrapolate best to this one's depth is on
-- this surface, and a silhouette doesn't mix in the surface behind it. When
-- neither side does, like the ground in a one pixel gap between grass blades,
-- there is nothing to take a normal from and the fallback is used.
-- needs a world pos from (uv, depth) function, see GetWorldPosFromUVGLSL
function screen_reconstruct.GetGeometricNormalGLSL(block_name, options)
	options = options or {}
	local function_name = options.function_name or "get_geometric_normal"
	local world_pos_function = options.world_pos_function or "get_world_pos_at"
	return (
		[[
			vec3 %s(ivec2 p, vec3 world_pos, float depth, vec3 V, vec3 fallback) {
				ivec2 depth_size = textureSize(TEXTURE(%s.depth_tex), 0);
				ivec2 max_p = depth_size - 1;
				vec2 texel = 1.0 / vec2(depth_size);
				vec3 steps[2];

				for (int axis = 0; axis < 2; axis++) {
					ivec2 o = axis == 0 ? ivec2(1, 0) : ivec2(0, 1);
					ivec2 p1 = clamp(p + o, ivec2(0), max_p);
					ivec2 n1 = clamp(p - o, ivec2(0), max_p);
					float d1 = texelFetch(TEXTURE(%s.depth_tex), p1, 0).r;
					float d2 = texelFetch(TEXTURE(%s.depth_tex), clamp(p + 2 * o, ivec2(0), max_p), 0).r;
					float e1 = texelFetch(TEXTURE(%s.depth_tex), n1, 0).r;
					float e2 = texelFetch(TEXTURE(%s.depth_tex), clamp(p - 2 * o, ivec2(0), max_p), 0).r;
					float positive_error = abs(2.0 * d1 - d2 - depth);
					float negative_error = abs(2.0 * e1 - e2 - depth);
					bool positive = positive_error < negative_error;

					// the tolerance is relative to the step itself, so it holds at any
					// distance, plus the rounding of depths near 1
					if (min(positive_error, negative_error) > 0.25 * abs((positive ? d1 : e1) - depth) + 4e-7) return fallback;

					steps[axis] = positive ?
						%s((vec2(p1) + 0.5) * texel, d1) - world_pos :
						world_pos - %s((vec2(n1) + 0.5) * texel, e1);
				}

				vec3 n = cross(steps[0], steps[1]);
				float len_sq = dot(n, n);

				if (len_sq < 1e-20) return fallback;

				n *= inversesqrt(len_sq);
				n = dot(n, V) < 0.0 ? -n : n;
				// two pixels of a blade in front can still line up with this one by
				// chance. no normal map bends a surface this far from its geometry
				return dot(n, fallback) < 0.5 ? fallback : n;
			}
	]]
	):format(
		function_name,
		block_name,
		block_name,
		block_name,
		block_name,
		block_name,
		world_pos_function,
		world_pos_function
	)
end

return screen_reconstruct
