local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local radiance_cascades = import("goluwa/render3d/radiance_cascades.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local Color = import("goluwa/structs/color.lua")
local MAX_CLIPMAPS = voxel_gi.GetMaxClipmapCount()
local show_rc_debug = false
local rc_pipeline = nil
local BINDING_CASCADE_TEX = 0
local BINDING_UNIFORM = 1
local BINDING_VOLUME_0 = 2

local function get_cascade_0_texture()
	return function()
		local pipeline = render3d.pipelines["radiance_cascade_0"]

		if not pipeline then
			local fallback = render.GetErrorTexture()
			return fallback
		end

		return pipeline:GetFramebuffer(1):GetAttachment(1)
	end
end

local function get_volume_descriptor(index)
	return function()
		return voxel_gi.GetVolumeDescriptor(index, false)
	end
end

local function build_volume_declarations()
	local decls = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		decls[#decls + 1] = string.format(
			"layout(set = 0, binding = %d) uniform sampler2DArray rc_volume_%d;",
			BINDING_VOLUME_0 + i,
			i
		)
	end

	return table.concat(decls, "\n")
end

local function build_debug_shader()
	local probes = radiance_cascades.PROBES_PER_AXIS
	local dirs = radiance_cascades.DIRECTION_COUNT
	local lines = {}

	local function s(...)
		lines[#lines + 1] = ...
	end

	s(screen_reconstruct.GetWorldRayGLSL("rc_debug_data", {function_name = "get_world_ray"}))
	s("")
	s("layout(location = 0) out vec4 frag_color;")
	s("")
	s(string.format("const int RC_PROBES = %d;", probes))
	s(string.format("const int RC_DIRS = %d;", dirs))
	s("")
	s("vec3 rc_grid_origin() {")
	s(
		"    return floor((rc_debug_data.camera_position - vec3(rc_debug_data.extent)) / rc_debug_data.spacing) * rc_debug_data.spacing;"
	)
	s("}")
	s("")
	s("vec3 rc_probe_pos(ivec3 idx) {")
	s("    return rc_grid_origin() + (vec3(idx) + 0.5) * rc_debug_data.spacing;")
	s("}")
	s("")
	s("ivec2 rc_texel(ivec3 idx, int d) {")
	s("    return ivec2(idx.x + RC_PROBES * idx.y, idx.z * RC_DIRS + d);")
	s("}")
	s("")
	s("bool rc_clip_contains(int c, vec3 p) {")
	s("    vec3 d = abs(p - rc_debug_data.clip_origin[c].xyz);")
	s("    return all(lessThan(d, vec3(rc_debug_data.clip_params[c].x * 0.5)));")
	s("}")
	s("")
	s("vec4 rc_fetch_voxel(int c, ivec3 v) {")

	for i = 0, MAX_CLIPMAPS - 1 do
		s(string.format("    if (c == %d) return texelFetch(rc_volume_%d, v, 0);", i, i))
	end

	s("    return vec4(0.0);")
	s("}")
	s("")
	s("vec3 rc_displace(vec3 pos) {")
	s("    for (int c = 0; c < rc_debug_data.clipmap_count; c++) {")
	s("        if (!rc_clip_contains(c, pos)) continue;")
	s("        float vs = rc_debug_data.clip_origin[c].w;")
	s(
		"        vec3 min_c = rc_debug_data.clip_origin[c].xyz - vec3(rc_debug_data.clip_params[c].x * 0.5);"
	)
	s("        ivec3 v = ivec3(floor((pos - min_c) / vs));")
	s("        int res = int(rc_debug_data.clip_params[c].y + 0.5);")
	s(
		"        if (any(lessThan(v, ivec3(0))) || any(greaterThanEqual(v, ivec3(res)))) continue;"
	)
	s("        vec4 voxel = rc_fetch_voxel(c, v);")
	s("        if (voxel.a < 0.5) continue;")
	s("        return pos + vec3(0.0, vs * 0.5, 0.0);")
	s("    }")
	s("    return pos;")
	s("}")
	s("")
	s("void main() {")
	s("    vec3 ro = rc_debug_data.camera_position;")
	s("    vec3 rd = get_world_ray();")
	s("    vec3 origin = rc_grid_origin();")
	s("    float extent = rc_debug_data.extent;")
	s("    vec3 bounds_min = rc_debug_data.camera_position - vec3(extent);")
	s("    vec3 bounds_max = rc_debug_data.camera_position + vec3(extent);")
	s("")
	s("    vec3 inv_rd = 1.0 / max(abs(rd), vec3(1e-6));")
	s("    vec3 tmin = (bounds_min - ro) * inv_rd;")
	s("    vec3 tmax = (bounds_max - ro) * inv_rd;")
	s(
		"    float t_enter = max(max(min(tmin.x, tmax.x), min(tmin.y, tmax.y)), min(tmin.z, tmax.z));"
	)
	s(
		"    float t_exit = min(min(max(tmin.x, tmax.x), max(tmin.y, tmax.y)), max(tmin.z, tmax.z));"
	)
	s("")
	s("    if (t_exit < max(t_enter, 0.0)) {")
	s("        frag_color = vec4(0.0);")
	s("        return;")
	s("    }")
	s("")
	s("    float t = max(t_enter, 0.0);")
	s("    vec3 pos = ro + rd * t;")
	s("")
	s("    ivec3 cell = ivec3(floor((pos - origin) / rc_debug_data.spacing));")
	s("    vec3 step_dir = sign(rd);")
	s("    vec3 t_delta = rc_debug_data.spacing * inv_rd;")
	s("")
	s("    vec3 side = step(0.0, step_dir);")
	s("    vec3 t_step = origin + (vec3(cell) + side) * rc_debug_data.spacing;")
	s("    vec3 t_max = (t_step - ro) * inv_rd;")
	s("    t_max = max(t_max, 0.0001);")
	s("")
	s("    for (int i = 0; i < 128; i++) {")
	s("        if (t > t_exit) break;")
	s(
		"        if (cell.x < 0 || cell.y < 0 || cell.z < 0 || cell.x >= RC_PROBES || cell.y >= RC_PROBES || cell.z >= RC_PROBES) break;"
	)
	s("")
	s("        vec3 probe_center = rc_probe_pos(cell);")
	s("        vec3 displaced = rc_displace(probe_center);")
	s("        float disp_dist = length(displaced - probe_center);")
	s("        vec3 show_pos = (disp_dist > 0.01) ? displaced : probe_center;")
	s("        float t_closest = dot(show_pos - ro, rd);")
	s(
		"        float dist_to_probe = length(show_pos - (ro + rd * max(t_closest, 0.0)));"
	)
	s("")
	s(
		"        if (rc_debug_data.show_probes > 0.5 && dist_to_probe < rc_debug_data.probe_radius) {"
	)
	s("            float fade = 1.0 - dist_to_probe / rc_debug_data.probe_radius;")
	s("            if (disp_dist > 0.01) {")
	s(
		"                frag_color = vec4(1.0, 0.15, 0.1, fade * rc_debug_data.overlay_alpha);"
	)
	s("            } else {")
	s("                vec3 total = vec3(0.0);")
	s("                for (int d = 0; d < RC_DIRS; d++) {")
	s("                    total += texelFetch(cascade_tex, rc_texel(cell, d), 0).rgb;")
	s("                }")
	s(
		"                float luma = dot(total / float(RC_DIRS), vec3(0.2126, 0.7152, 0.0722));"
	)
	s("                vec3 probe_color = vec3(1.0, 0.9, 0.2) * (0.3 + luma * 0.7);")
	s(
		"                frag_color = vec4(probe_color, fade * rc_debug_data.overlay_alpha);"
	)
	s("            }")
	s("            return;")
	s("        }")
	s("")
	s("        if (t_max.x < t_max.y) {")
	s("            if (t_max.x < t_max.z) {")
	s("                t = t_max.x; t_max.x += t_delta.x; cell.x += int(step_dir.x);")
	s("            } else {")
	s("                t = t_max.z; t_max.z += t_delta.z; cell.z += int(step_dir.z);")
	s("            }")
	s("        } else {")
	s("            if (t_max.y < t_max.z) {")
	s("                t = t_max.y; t_max.y += t_delta.y; cell.y += int(step_dir.y);")
	s("            } else {")
	s("                t = t_max.z; t_max.z += t_delta.z; cell.z += int(step_dir.z);")
	s("            }")
	s("        }")
	s("        pos = ro + rd * t;")
	s("    }")
	s("")
	s("    frag_color = vec4(0.0);")
	s("}")
	return table.concat(lines, "\n")
end

local function ensure_pipeline()
	if rc_pipeline then return rc_pipeline end

	local desc_sets = {
		{
			type = "combined_image_sampler",
			binding_index = BINDING_CASCADE_TEX,
			set_index = 0,
			args = get_cascade_0_texture(),
		},
	}

	for i = 0, MAX_CLIPMAPS - 1 do
		desc_sets[#desc_sets + 1] = {
			type = "combined_image_sampler",
			binding_index = BINDING_VOLUME_0 + i,
			set_index = 0,
			args = get_volume_descriptor(i + 1),
		}
	end

	local custom_decl = string.format(
			"layout(set = 0, binding = %d) uniform sampler2D cascade_tex;\n",
			BINDING_CASCADE_TEX
		) .. build_volume_declarations()
	rc_pipeline = EasyPipeline.New{
		name = "debug_rc_probe_visualizer",
		dont_create_framebuffers = true,
		fragment = {
			descriptor_sets = desc_sets,
			uniform_buffers = {
				{
					name = "rc_debug_data",
					binding_index = BINDING_UNIFORM,
					block = {
						render3d.camera_block,
						{"extent", "float"},
						{"spacing", "float"},
						{"probes_per_axis", "int"},
						{"direction_count", "int"},
						{"probe_radius", "float"},
						{"overlay_alpha", "float"},
						{"show_probes", "int"},
						{"clipmap_count", "int"},
						{"clip_origin", "vec4", MAX_CLIPMAPS},
						{"clip_params", "vec4", MAX_CLIPMAPS},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.extent = radiance_cascades.VOLUME_EXTENT
						block.spacing = radiance_cascades.GetProbeSpacing()
						block.probes_per_axis = radiance_cascades.PROBES_PER_AXIS
						block.direction_count = radiance_cascades.DIRECTION_COUNT
						block.probe_radius = radiance_cascades.GetProbeSpacing() * 0.08
						block.overlay_alpha = 0.7
						block.show_probes = 1
						local clipmap_count = 0

						for i = 0, MAX_CLIPMAPS - 1 do
							local info = voxel_gi.GetClipmapInfo(i + 1)

							if info and info.valid then
								clipmap_count = i + 1
								block.clip_origin[i][0] = info.origin.x
								block.clip_origin[i][1] = info.origin.y
								block.clip_origin[i][2] = info.origin.z
								block.clip_origin[i][3] = info.voxel_size
								block.clip_params[i][0] = info.world_span
								block.clip_params[i][1] = info.resolution
								block.clip_params[i][2] = 1
								block.clip_params[i][3] = 0
							else
								block.clip_origin[i][0] = 0
								block.clip_origin[i][1] = 0
								block.clip_origin[i][2] = 0
								block.clip_origin[i][3] = 1
								block.clip_params[i][0] = 0
								block.clip_params[i][1] = 0
								block.clip_params[i][2] = 0
								block.clip_params[i][3] = 0
							end
						end

						block.clipmap_count = clipmap_count
						return block
					end,
				},
			},
			custom_declarations = custom_decl,
			shader = build_debug_shader(),
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = "rgba",
	}
	return rc_pipeline
end

local function draw_stats()
	local spacing = radiance_cascades.GetProbeSpacing()
	local probes = radiance_cascades.PROBES_PER_AXIS
	local lines = {
		"Radiance Cascades",
		string.format(
			"  %s  %d cascades  active=%s",
			radiance_cascades.BACKEND,
			radiance_cascades.CASCADE_COUNT,
			tostring(radiance_cascades.IsActive())
		),
		string.format(
			"  extent=%.0fm spacing=%.2fm probes=%d dirs=%d",
			radiance_cascades.VOLUME_EXTENT,
			spacing,
			probes,
			radiance_cascades.DIRECTION_COUNT
		),
		string.format(
			"  interval=%.3fm reach=%.1fm",
			radiance_cascades.GetBaseInterval(),
			radiance_cascades.GetBaseInterval() * radiance_cascades.INTERVAL_SCALE ^ (
					radiance_cascades.CASCADE_COUNT - 1
				)
		),
		"  yellow = normal  red = displaced",
		"F6 toggle",
	}
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.6)
	local h = 10 + #lines * 16
	render2d.DrawRoundedRect(10, 10, 360, h, 6)
	render2d.SetColor(1, 1, 1, 1)

	for i, line in ipairs(lines) do
		render2d.DrawText{text = line, x = 18, y = 18 + (i - 1) * 16, softness = 0}
	end
end

event.AddListener("Draw3DForwardOverlay", "debug_rc_probes", function()
	if not show_rc_debug then return end

	local pipeline = ensure_pipeline()
	pipeline:Draw(render.GetCommandBuffer())
end)



event.AddListener("Draw2D", "debug_rc_stats", function()
	if not show_rc_debug then return end

	draw_stats()
end)

event.AddListener("KeyInput", "debug_rc_toggle", function(key, press)
	if not press or key ~= "f6" then return end

	show_rc_debug = not show_rc_debug
	print("RC debug: " .. (show_rc_debug and "ON" or "OFF"))
end)

commands.Add("rc_debug=boolean", function(enabled)
	show_rc_debug = enabled ~= false
	print("RC debug: " .. (show_rc_debug and "ON" or "OFF"))
end)

