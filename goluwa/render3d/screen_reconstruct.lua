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

return screen_reconstruct
