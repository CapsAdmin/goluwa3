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
-- neighbouring depth pixels. Per axis the side whose depth continues the
-- surface best is used, so a silhouette doesn't mix in the surface behind it.
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
				ivec2 pl = clamp(p - ivec2(1, 0), ivec2(0), max_p);
				ivec2 pr = clamp(p + ivec2(1, 0), ivec2(0), max_p);
				ivec2 pd = clamp(p - ivec2(0, 1), ivec2(0), max_p);
				ivec2 pu = clamp(p + ivec2(0, 1), ivec2(0), max_p);
				float dl = texelFetch(TEXTURE(%s.depth_tex), pl, 0).r;
				float dr = texelFetch(TEXTURE(%s.depth_tex), pr, 0).r;
				float dd = texelFetch(TEXTURE(%s.depth_tex), pd, 0).r;
				float du = texelFetch(TEXTURE(%s.depth_tex), pu, 0).r;
				vec2 texel = 1.0 / vec2(depth_size);
				vec3 dx = abs(dr - depth) < abs(depth - dl) ?
					%s((vec2(pr) + 0.5) * texel, dr) - world_pos :
					world_pos - %s((vec2(pl) + 0.5) * texel, dl);
				vec3 dy = abs(du - depth) < abs(depth - dd) ?
					%s((vec2(pu) + 0.5) * texel, du) - world_pos :
					world_pos - %s((vec2(pd) + 0.5) * texel, dd);
				vec3 n = cross(dx, dy);
				float len_sq = dot(n, n);

				if (len_sq < 1e-20) return fallback;

				n *= inversesqrt(len_sq);
				return dot(n, V) < 0.0 ? -n : n;
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
		world_pos_function,
		world_pos_function,
		world_pos_function
	)
end

return screen_reconstruct
