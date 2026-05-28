local commands = import("goluwa/commands.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local show_voxel_debug = false
local selected_clipmap_index = 0
local voxel_debug_pipelines = {}
local current_debug_render_clipmap_index = 1
local current_debug_exclusion_bounds = nil
local voxel_dump_watch_enabled = false
local voxel_dump_watch_last_signature = nil
local current_debug_volume_kind = "scene"
local DEBUG_VOLUME_KINDS = {"scene", "normals"}
local DEBUG_VOXEL_MAX_STEP_FACTOR = 2
local get_command_clipmap_index
local debug_pipeline_state = {
	clipmap_index = 0,
	resolution = 1,
	voxel_size = 1,
	world_span = 1,
	clipmap_origin = Vec3(0, 0, 0),
	exclude_valid = 0,
	exclude_min = Vec3(0, 0, 0),
	exclude_max = Vec3(0, 0, 0),
	volume_valid = 0,
	max_steps = 1,
	view_mode = 0,
	occupancy_threshold = 0.01,
	overlay_alpha = 1,
}

local function get_debug_volume_kind_label()
	if current_debug_volume_kind == "normals" then return "normals" end
	return "scene"
end

local function get_debug_volume_kind_mode()
	if current_debug_volume_kind == "normals" then return 1 end
	return 0
end

local function get_debug_volume_origin(voxelizer, clipmap)
	if not clipmap then return Vec3(0, 0, 0) end
	if voxelizer and voxelizer.GetClipmapLightingOrigin then
		return voxelizer.GetClipmapLightingOrigin(clipmap.index) or clipmap.origin
	end

	return clipmap.origin
end

local function cycle_debug_volume_kind()
	for i, kind in ipairs(DEBUG_VOLUME_KINDS) do
		if kind == current_debug_volume_kind then
			current_debug_volume_kind = DEBUG_VOLUME_KINDS[(i % #DEBUG_VOLUME_KINDS) + 1]
			return
		end
	end

	current_debug_volume_kind = DEBUG_VOLUME_KINDS[1]
end

local function is_shift_down()
	return input.IsKeyDown("left_shift") or
		input.IsKeyDown("right_shift") or
		input.IsKeyDown("shift")
end

local function is_control_down()
	return 
		input.IsKeyDown("left_control") or
		input.IsKeyDown("left_super") or
		input.IsKeyDown("right_control") or
		input.IsKeyDown("control")
end

local function get_voxelizer()
	if not render3d.GetSceneVoxelizer then return nil end

	return render3d.GetSceneVoxelizer()
end

local function format_vec3(vec)
	if not vec then return "<nil>" end

	return string.format("(%.3f, %.3f, %.3f)", vec.x or 0, vec.y or 0, vec.z or 0)
end

local function format_pending_range(range)
	if not range then return "idle" end

	return string.format(
		"start=%d end=%d next=%d dir=%d",
		range.start_slice or -1,
		range.end_slice or -1,
		range.next_slice or -1,
		range.direction or 0
	)
end

local function format_axis_counts(values)
	if not values then return "x=0 y=0 z=0" end

	return string.format(
		"x=%d y=%d z=%d",
		values.x or 0,
		values.y or 0,
		values.z or 0
	)
end

local function dump_voxel_debug_state(index)
	local voxelizer = get_voxelizer()

	if not voxelizer or not voxelizer.GetClipmapDebugInfo then
		print("Voxel debug: voxelizer debug info unavailable")
		return
	end

	index = get_command_clipmap_index(index)
	local info = voxelizer.GetClipmapDebugInfo(index)

	if not info then
		print("Voxel debug: no clipmap state for index " .. tostring(index))
		return
	end

	print("Voxel debug clipmap " .. tostring(index))
	print("  camera        " .. format_vec3(info.camera_position))
	print("  latest origin " .. format_vec3(info.latest_origin) .. " stride=" .. string.format("%.3f", info.snap_stride or 0))
	print("  active origin " .. format_vec3(info.origin) .. " offset_voxels=" .. format_vec3(info.active_to_latest_voxels))
	print("  build origin  " .. format_vec3(info.build_origin) .. " offset_voxels=" .. format_vec3(info.build_to_latest_voxels))
	print(
		"  sampled       " .. tostring(info.sampled_source or "active") ..
			" origin=" .. format_vec3(info.sampled_origin) ..
			" offset_voxels=" .. format_vec3(info.sampled_to_latest_voxels)
	)
	print(
		"  targets       active=" .. tostring(info.active_target_id or "nil") ..
			" v=" .. tostring(info.active_content_version or 0) ..
			" build=" .. tostring(info.build_target_id or "nil") ..
			" v=" .. tostring(info.build_content_version or 0) ..
			" sampled=" .. tostring(info.sampled_target_id or "nil") ..
			" v=" .. tostring(info.sampled_content_version or 0)
	)
	print(
		"  handoff       mode=" .. tostring(info.last_handoff_mode or "none") ..
			" origin=" .. format_vec3(info.last_handoff_origin or Vec3(0, 0, 0)) ..
			" active_v=" .. tostring(info.last_handoff_active_version or 0) ..
			" build_v=" .. tostring(info.last_handoff_build_version or 0) ..
			" rescheduled=" .. tostring(info.last_handoff_rescheduled)
	)
	print("  delta voxels  " .. format_vec3(info.delta))
	print(
		"  flags         dirty=" .. tostring(info.dirty) ..
			" full=" .. tostring(info.full_rebuild) ..
			" building=" .. tostring(info.building_into_scroll) ..
			" scroll_ready=" .. tostring(info.build_scroll_ready) ..
			" valid=" .. tostring(info.has_valid_data) ..
			" pending_clear=" .. tostring(info.pending_clear) ..
			" pending_scroll=" .. tostring(info.pending_scroll)
	)
	print("  dirty slabs   " .. format_axis_counts(info.dirty_slabs) .. "  budget=" .. tostring(info.build_slice_budget or 0))
	print("  pending count " .. format_axis_counts(info.pending_counts))
	print("  pending x     " .. format_pending_range(info.pending_ranges and info.pending_ranges.x or nil))
	print("  pending y     " .. format_pending_range(info.pending_ranges and info.pending_ranges.y or nil))
	print("  pending z     " .. format_pending_range(info.pending_ranges and info.pending_ranges.z or nil))
end

local function dump_voxel_camera_mapping(index)
	local voxelizer = get_voxelizer()

	if not voxelizer or not voxelizer.WorldToVoxel or not voxelizer.VoxelToWorld then
		print("Voxel debug: voxelizer mapping helpers unavailable")
		return
	end

	index = get_command_clipmap_index(index)
	local camera = render3d.GetCamera and render3d.GetCamera() or nil

	if not camera or not camera.GetPosition then
		print("Voxel debug: camera unavailable")
		return
	end

	local camera_position = camera:GetPosition()
	local mapping = voxelizer.WorldToVoxel(index, camera_position)

	if not mapping then
		print("Voxel debug: no mapping available for clipmap " .. tostring(index))
		return
	end

	local voxel_center = voxelizer.VoxelToWorld(index, mapping.voxel)
	local local_offset = Vec3(
		camera_position.x - voxel_center.x,
		camera_position.y - voxel_center.y,
		camera_position.z - voxel_center.z
	)

	print("Voxel camera mapping clipmap " .. tostring(index))
	print("  camera        " .. format_vec3(camera_position))
	print("  voxel index   " .. format_vec3(mapping.voxel))
	print("  fractional    " .. format_vec3(mapping.fractional))
	print("  voxel center  " .. format_vec3(voxel_center))
	print("  local offset  " .. format_vec3(local_offset))
	print("  inside        " .. tostring(mapping.inside))
end

local function get_voxel_debug_signature(index)
	local voxelizer = get_voxelizer()

	if not voxelizer or not voxelizer.GetClipmapDebugInfo then return nil end

	local info = voxelizer.GetClipmapDebugInfo(index)

	if not info then return nil end

	return table.concat({
		string.format("%.3f", info.camera_position.x),
		string.format("%.3f", info.camera_position.y),
		string.format("%.3f", info.camera_position.z),
		string.format("%.3f", info.latest_origin.x),
		string.format("%.3f", info.latest_origin.y),
		string.format("%.3f", info.latest_origin.z),
		string.format("%.3f", info.origin.x),
		string.format("%.3f", info.origin.y),
		string.format("%.3f", info.origin.z),
		string.format("%.3f", info.build_origin.x),
		string.format("%.3f", info.build_origin.y),
		string.format("%.3f", info.build_origin.z),
		tostring(info.dirty),
		tostring(info.building_into_scroll),
	}, "|")
end

local function clamp_selected_clipmap_index(voxelizer)
	local count = voxelizer and voxelizer.clipmap_count or 0

	if count <= 0 then
		selected_clipmap_index = 0
		return nil
	end

	if selected_clipmap_index == nil or selected_clipmap_index < 0 or selected_clipmap_index > count then
		selected_clipmap_index = 0
	end

	return selected_clipmap_index
end

local function get_selected_clipmap_data(index_override)
	local voxelizer = get_voxelizer()

	if not voxelizer then return nil, nil, nil end

	clamp_selected_clipmap_index(voxelizer)
	local count = voxelizer.clipmap_count or 0
	local clipmap_index = index_override

	if clipmap_index == nil then clipmap_index = current_debug_render_clipmap_index or selected_clipmap_index or 1 end

	if clipmap_index == 0 and count > 0 then clipmap_index = 1 end

	if not clipmap_index or clipmap_index < 1 or clipmap_index > count then return voxelizer, nil, nil end

	local clipmap = voxelizer.GetClipmap(clipmap_index)
	local axis_targets = nil

	if clipmap then
		if voxelizer.GetClipmapLightingAxisTarget then
			axis_targets = {
				x = voxelizer.GetClipmapLightingAxisTarget(clipmap_index, "x"),
				y = voxelizer.GetClipmapLightingAxisTarget(clipmap_index, "y"),
				z = voxelizer.GetClipmapLightingAxisTarget(clipmap_index, "z"),
			}
		elseif clipmap.resources then
			axis_targets = clipmap.resources.axis_targets
		end
	end

	if
		not axis_targets or
		not axis_targets.x or
		not axis_targets.y or
		not axis_targets.z
	then
		return voxelizer, clipmap_index, clipmap
	end

	return voxelizer, clipmap_index, clipmap, axis_targets
end

local function get_display_clipmap_label(voxelizer)
	clamp_selected_clipmap_index(voxelizer)

	if selected_clipmap_index == 0 then return "all" end

	return tostring(selected_clipmap_index or 1)
end

get_command_clipmap_index = function(index)
	local voxelizer = get_voxelizer()

	if not voxelizer then return 1 end

	local count = voxelizer.clipmap_count or 0
	local resolved = index ~= nil and math.max(math.floor(index), 1) or selected_clipmap_index or 1

	if resolved == 0 then resolved = 1 end

	if count > 0 then resolved = math.clamp(resolved, 1, count) end

	return resolved
end

local function get_fallback_volume_descriptor()
	local fallback = render.GetErrorTexture()
	return fallback:GetView(), render.CreateSampler(fallback:GetSamplerConfig())
end

local function get_voxel_volume_descriptor(axis_name, clipmap_index)
	return function()
		local _, _, _, axis_targets = get_selected_clipmap_data(clipmap_index)
		local target = axis_targets and axis_targets[axis_name]

		if target and target.sample_view and target.sampler then
			return {target.sample_view, target.sampler}
		end

		local fallback_view, fallback_sampler = get_fallback_volume_descriptor()
		return {fallback_view, fallback_sampler}
	end
end

local function get_voxel_debug_target_signature(clipmap_index)
	local _, resolved_index, _, axis_targets = get_selected_clipmap_data(clipmap_index)
	local parts = {get_debug_volume_kind_label(), tostring(resolved_index or 0)}

	for _, axis_name in ipairs({"x", "y", "z"}) do
		local target = axis_targets and axis_targets[axis_name] or nil
		parts[#parts + 1] = tostring(target and target.sample_view or false)
		parts[#parts + 1] = tostring(target and target.sampler or false)
	end

	return table.concat(parts, "|")
end

local function invalidate_voxel_debug_pipeline()
	for _, pipeline in pairs(voxel_debug_pipelines) do
		if pipeline and pipeline.Remove then pipeline:Remove() end
	end

	voxel_debug_pipelines = {}
end

local function update_pipeline_state()
	local voxelizer, clipmap_index, clipmap, axis_targets = get_selected_clipmap_data(current_debug_render_clipmap_index)
	debug_pipeline_state.clipmap_index = clipmap_index or 0
	debug_pipeline_state.volume_valid = 0
	debug_pipeline_state.exclude_valid = 0

	if not clipmap or not axis_targets then
		debug_pipeline_state.resolution = 1
		debug_pipeline_state.voxel_size = 1
		debug_pipeline_state.world_span = 1
		debug_pipeline_state.max_steps = 1
		debug_pipeline_state.clipmap_origin.x = 0
		debug_pipeline_state.clipmap_origin.y = 0
		debug_pipeline_state.clipmap_origin.z = 0
		debug_pipeline_state.exclude_min.x = 0
		debug_pipeline_state.exclude_min.y = 0
		debug_pipeline_state.exclude_min.z = 0
		debug_pipeline_state.exclude_max.x = 0
		debug_pipeline_state.exclude_max.y = 0
		debug_pipeline_state.exclude_max.z = 0
		return voxelizer, clipmap_index, clipmap, axis_targets
	end

	debug_pipeline_state.resolution = math.max(clipmap.resolution or 1, 1)
	debug_pipeline_state.voxel_size = math.max(clipmap.voxel_size or 1, 0.001)
	debug_pipeline_state.world_span = math.max(clipmap.world_span or debug_pipeline_state.voxel_size, debug_pipeline_state.voxel_size)
	debug_pipeline_state.max_steps = math.max(math.floor(debug_pipeline_state.resolution * DEBUG_VOXEL_MAX_STEP_FACTOR), 1)
	debug_pipeline_state.volume_valid = 1
	debug_pipeline_state.view_mode = get_debug_volume_kind_mode()
	local debug_origin = get_debug_volume_origin(voxelizer, clipmap)
	debug_pipeline_state.clipmap_origin.x = debug_origin.x
	debug_pipeline_state.clipmap_origin.y = debug_origin.y
	debug_pipeline_state.clipmap_origin.z = debug_origin.z

	if current_debug_exclusion_bounds then
		debug_pipeline_state.exclude_valid = 1
		debug_pipeline_state.exclude_min.x = current_debug_exclusion_bounds.min_x
		debug_pipeline_state.exclude_min.y = current_debug_exclusion_bounds.min_y
		debug_pipeline_state.exclude_min.z = current_debug_exclusion_bounds.min_z
		debug_pipeline_state.exclude_max.x = current_debug_exclusion_bounds.max_x
		debug_pipeline_state.exclude_max.y = current_debug_exclusion_bounds.max_y
		debug_pipeline_state.exclude_max.z = current_debug_exclusion_bounds.max_z
	end

	return voxelizer, clipmap_index, clipmap, axis_targets
end

local function draw_stats_block(voxelizer, x, y)
	local debug_state = voxelizer and voxelizer.GetDebugState and voxelizer.GetDebugState() or nil
	local stats = debug_state and debug_state.frame_stats or nil
	local clipmap_info = voxelizer and voxelizer.GetClipmapDebugInfo and voxelizer.GetClipmapDebugInfo(get_command_clipmap_index()) or nil
	local block_height = clipmap_info and 278 or 150

	if not stats then return end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55)
	gfx.DrawRoundedRect(x, y, 356, block_height, 6)
	render2d.SetColor(1, 1, 1, 1)
	fonts.SetFont(fonts.GetDefaultFont())
	fonts.GetFont():DrawText(string.format("Voxel clipmaps: %d", debug_state.clipmap_count or 0), x + 8, y + 8)
	fonts.GetFont():DrawText(
		string.format(
			"Updated: %d  Full: %d  Incremental: %d",
			stats.updated_clipmaps or 0,
			stats.full_rebuilds or 0,
			stats.incremental_rebuilds or 0
		),
		x + 8,
		y + 28
	)
	fonts.GetFont():DrawText(
		string.format(
			"Build: %d clipmaps  %d axes  %d slices",
			stats.voxel_build_clipmaps or 0,
			stats.voxel_build_axes or 0,
			stats.voxel_build_slices or 0
		),
		x + 8,
		y + 48
	)
	fonts.GetFont():DrawText(
		string.format(
			"Geometry: %d visuals  %d entries",
			stats.voxel_visuals or 0,
			stats.voxel_entries or 0
		),
		x + 8,
		y + 68
	)
	fonts.GetFont():DrawText(
		string.format(
			"Scroll copy: %d inline  %d fallback  %d submits  %d waits",
			stats.voxel_scroll_inline_clipmaps or 0,
			stats.voxel_scroll_submit_clipmaps or 0,
			stats.voxel_scroll_submissions or 0,
			stats.voxel_scroll_submit_waits or 0
		),
		x + 8,
		y + 88
	)
	fonts.GetFont():DrawText("Clipmap focus: " .. get_display_clipmap_label(voxelizer), x + 8, y + 108)
	fonts.GetFont():DrawText("View: " .. get_debug_volume_kind_label() .. " perspective voxel raymarch", x + 8, y + 128)

	if clipmap_info then
		local status = clipmap_info.build_scroll_ready and
			"Build in progress; showing scrolled build volume" or
			(clipmap_info.building_into_scroll and
				"Build in progress; showing committed active volume" or
				"Showing committed active volume")
		local lag = clipmap_info.active_to_latest_voxels or Vec3(0, 0, 0)
		local build_lag = clipmap_info.build_to_latest_voxels or Vec3(0, 0, 0)
		local sampled_lag = clipmap_info.sampled_to_latest_voxels or Vec3(0, 0, 0)
		fonts.GetFont():DrawText(status, x + 8, y + 144)
		fonts.GetFont():DrawText(
			string.format("Active lag voxels: (%.0f, %.0f, %.0f)", lag.x or 0, lag.y or 0, lag.z or 0),
			x + 8,
			y + 162
		)
		fonts.GetFont():DrawText(
			string.format("Build lag voxels:  (%.0f, %.0f, %.0f)", build_lag.x or 0, build_lag.y or 0, build_lag.z or 0),
			x + 8,
			y + 180
		)
		fonts.GetFont():DrawText(
			string.format(
				"Sampled: %s lag=(%.0f, %.0f, %.0f)",
				tostring(clipmap_info.sampled_source or "active"),
				sampled_lag.x or 0,
				sampled_lag.y or 0,
				sampled_lag.z or 0
			),
			x + 8,
			y + 198
		)
		fonts.GetFont():DrawText(
			string.format(
				"Dirty slabs: x=%d y=%d z=%d  Pending: x=%d y=%d z=%d",
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.x or 0,
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.y or 0,
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.z or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.x or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.y or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.z or 0
			),
			x + 8,
			y + 216
		)
		fonts.GetFont():DrawText(
			string.format(
				"Budget: %d  Flags: scroll_ready=%s pending_scroll=%s",
				clipmap_info.build_slice_budget or 0,
				tostring(clipmap_info.build_scroll_ready),
				tostring(clipmap_info.pending_scroll)
			),
			x + 8,
			y + 234
		)
	end

	fonts.GetFont():DrawText("F3: toggle  Shift+F3: all/clipmap  Ctrl+F3: scene/normals", x + 8, y + (clipmap_info and 250 or 142))
end

local function ensure_voxel_debug_pipeline(clipmap_index)
	local target_signature = get_voxel_debug_target_signature(clipmap_index)
	local cached = voxel_debug_pipelines[target_signature]

	if cached then return cached end

	local pipeline = EasyPipeline.New{
		name = "debug_voxel_visualizer",
		dont_create_framebuffers = true,
		fragment = {
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					set_index = 2,
					args = get_voxel_volume_descriptor("x", clipmap_index),
				},
				{
					type = "combined_image_sampler",
					binding_index = 1,
					set_index = 2,
					args = get_voxel_volume_descriptor("y", clipmap_index),
				},
				{
					type = "combined_image_sampler",
					binding_index = 2,
					set_index = 2,
					args = get_voxel_volume_descriptor("z", clipmap_index),
				},
			},
			uniform_buffers = {
				{
					name = "voxel_debug_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						{"volume_valid", "int"},
						{"clipmap_index", "int"},
						{"clipmap_origin", "vec3"},
						{"exclude_valid", "int"},
						{"exclude_min", "vec3"},
						{"exclude_max", "vec3"},
						{"resolution", "int"},
						{"voxel_size", "float"},
						{"world_span", "float"},
						{"max_steps", "int"},
						{"view_mode", "int"},
						{"occupancy_threshold", "float"},
						{"overlay_alpha", "float"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						update_pipeline_state()
						block.volume_valid = debug_pipeline_state.volume_valid
						block.clipmap_index = debug_pipeline_state.clipmap_index
						debug_pipeline_state.clipmap_origin:CopyToFloatPointer(block.clipmap_origin)
						block.exclude_valid = debug_pipeline_state.exclude_valid
						debug_pipeline_state.exclude_min:CopyToFloatPointer(block.exclude_min)
						debug_pipeline_state.exclude_max:CopyToFloatPointer(block.exclude_max)
						block.resolution = debug_pipeline_state.resolution
						block.voxel_size = debug_pipeline_state.voxel_size
						block.world_span = debug_pipeline_state.world_span
						block.max_steps = debug_pipeline_state.max_steps
						block.view_mode = debug_pipeline_state.view_mode
						block.occupancy_threshold = debug_pipeline_state.occupancy_threshold
						block.overlay_alpha = debug_pipeline_state.overlay_alpha
						return block
					end,
				},
			},
			custom_declarations = [[
			layout(set = 2, binding = 0) uniform sampler2DArray x_voxel_volume;
			layout(set = 2, binding = 1) uniform sampler2DArray y_voxel_volume;
			layout(set = 2, binding = 2) uniform sampler2DArray z_voxel_volume;
			]],
			shader = [[
			]] .. screen_reconstruct.GetWorldRayGLSL("voxel_debug_data", {function_name = "get_world_ray"}) .. [[
			layout(location = 0) out vec4 frag_color;

			bool intersect_aabb(vec3 ray_origin, vec3 ray_dir, vec3 bounds_min, vec3 bounds_max, out float t_min, out float t_max) {
				vec3 inv_dir = 1.0 / max(abs(ray_dir), vec3(1e-6)) * sign(ray_dir);
				vec3 t0 = (bounds_min - ray_origin) * inv_dir;
				vec3 t1 = (bounds_max - ray_origin) * inv_dir;
				vec3 tsmaller = min(t0, t1);
				vec3 tbigger = max(t0, t1);
				t_min = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
				t_max = min(min(tbigger.x, tbigger.y), tbigger.z);
				return t_max >= max(t_min, 0.0);
			}

			bool voxel_in_bounds(ivec3 voxel) {
				return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, ivec3(voxel_debug_data.resolution)));
			}

			bool point_in_exclusion(vec3 world_pos) {
				if (voxel_debug_data.exclude_valid == 0) return false;
				return all(greaterThanEqual(world_pos, voxel_debug_data.exclude_min)) && all(lessThanEqual(world_pos, voxel_debug_data.exclude_max));
			}

			vec3 safe_ray_sign(vec3 ray_dir) {
				return mix(vec3(-1.0), vec3(1.0), greaterThanEqual(ray_dir, vec3(0.0)));
			}

			ivec3 world_to_voxel(vec3 world_pos) {
				vec3 min_corner = voxel_debug_data.clipmap_origin - vec3(voxel_debug_data.world_span * 0.5);
				vec3 local_pos = (world_pos - min_corner) / max(voxel_debug_data.voxel_size, 1e-6);
				return ivec3(floor(local_pos));
			}

			vec4 sample_layer(int tex_index, ivec3 coord) {
				if (tex_index == 0) return texelFetch(x_voxel_volume, coord, 0);
				if (tex_index == 1) return texelFetch(y_voxel_volume, coord, 0);
				return texelFetch(z_voxel_volume, coord, 0);
			}

			vec4 sample_voxel_axes(ivec3 voxel) {
				int max_index = voxel_debug_data.resolution - 1;
				vec4 sx = sample_layer(0, ivec3(max_index - voxel.z, max_index - voxel.y, voxel.x));
				vec4 sy = sample_layer(1, ivec3(max_index - voxel.x, voxel.z, voxel.y));
				vec4 sz = sample_layer(2, ivec3(max_index - voxel.x, max_index - voxel.y, voxel.z));
				float occupancy = max(sx.a, max(sy.a, sz.a));
				vec3 color = vec3(0.0);
				float contributors = 0.0;

				if (sx.a >= voxel_debug_data.occupancy_threshold) {
					color += sx.rgb;
					contributors += 1.0;
				}

				if (sy.a >= voxel_debug_data.occupancy_threshold) {
					color += sy.rgb;
					contributors += 1.0;
				}

				if (sz.a >= voxel_debug_data.occupancy_threshold) {
					color += sz.rgb;
					contributors += 1.0;
				}

				if (contributors > 0.0) color /= contributors;
				return vec4(color, occupancy);
			}

			vec4 sample_voxel_neighborhood(ivec3 voxel) {
				vec4 center = sample_voxel_axes(voxel);

				if (center.a >= voxel_debug_data.occupancy_threshold) {
					return center;
				}

				vec3 accum = vec3(0.0);
				float total_weight = 0.0;

				for (int axis = 0; axis < 3; axis++) {
					for (int direction = -1; direction <= 1; direction += 2) {
						ivec3 offset = ivec3(0);
						offset[axis] = direction;
						ivec3 coord = voxel + offset;

						if (!voxel_in_bounds(coord)) continue;

						vec4 sample_color = sample_voxel_axes(coord);

						if (sample_color.a < voxel_debug_data.occupancy_threshold) continue;

						accum += sample_color.rgb;
						total_weight += 1.0;
					}
				}

				if (total_weight <= 0.0) return vec4(0.0);

				return vec4(accum / total_weight, 1.0);
			}

			float get_voxel_occupancy(ivec3 voxel) {
				if (!voxel_in_bounds(voxel)) return 0.0;
				return sample_voxel_axes(voxel).a;
			}

			vec3 estimate_voxel_normal(ivec3 voxel) {
				float x0 = get_voxel_occupancy(voxel - ivec3(1, 0, 0));
				float x1 = get_voxel_occupancy(voxel + ivec3(1, 0, 0));
				float y0 = get_voxel_occupancy(voxel - ivec3(0, 1, 0));
				float y1 = get_voxel_occupancy(voxel + ivec3(0, 1, 0));
				float z0 = get_voxel_occupancy(voxel - ivec3(0, 0, 1));
				float z1 = get_voxel_occupancy(voxel + ivec3(0, 0, 1));
				vec3 gradient = vec3(x1 - x0, y1 - y0, z1 - z0);
				float len2 = dot(gradient, gradient);

				if (len2 <= 1e-6) return vec3(0.0, 1.0, 0.0);

				return normalize(-gradient);
			}

			void main() {
				if (voxel_debug_data.volume_valid == 0) {
					frag_color = vec4(0.0);
					return;
				}

				vec3 ray_origin = voxel_debug_data.camera_position.xyz;
				vec3 ray_dir = get_world_ray();
				vec3 half_span = vec3(voxel_debug_data.world_span * 0.5);
				vec3 bounds_min = voxel_debug_data.clipmap_origin - half_span;
				vec3 bounds_max = voxel_debug_data.clipmap_origin + half_span;
				float t_min;
				float t_max;

				if (!intersect_aabb(ray_origin, ray_dir, bounds_min, bounds_max, t_min, t_max)) {
					frag_color = vec4(0.0);
					return;
				}

				float entry_epsilon = max(voxel_debug_data.voxel_size * 1e-3, 1e-4);
				float t = min(max(t_min, 0.0) + entry_epsilon, t_max);
				vec3 entry_pos = clamp(ray_origin + ray_dir * t, bounds_min, bounds_max - vec3(1e-5));
				ivec3 voxel = world_to_voxel(entry_pos);
				vec3 min_corner = voxel_debug_data.clipmap_origin - vec3(voxel_debug_data.world_span * 0.5);
				vec3 ray_sign = safe_ray_sign(ray_dir);
				ivec3 step_dir = ivec3(ray_sign);
				vec3 inv_abs_ray = 1.0 / max(abs(ray_dir), vec3(1e-6));
				vec3 voxel_min = min_corner + vec3(voxel) * voxel_debug_data.voxel_size;
				vec3 voxel_max = voxel_min + vec3(voxel_debug_data.voxel_size);
				vec3 next_boundary = mix(voxel_min, voxel_max, greaterThan(ray_sign, vec3(0.0)));
				vec3 t_max_axis = vec3(t) + abs(next_boundary - entry_pos) * inv_abs_ray;
				vec3 t_delta = vec3(voxel_debug_data.voxel_size) * inv_abs_ray;

				for (int i = 0; i < 1024; i++) {
					if (i >= voxel_debug_data.max_steps || t > t_max || !voxel_in_bounds(voxel)) break;
					vec3 voxel_center = voxel_min + vec3(voxel_debug_data.voxel_size * 0.5);

					if (point_in_exclusion(voxel_center)) {
						int step_axis = 0;
						float next_t = t_max_axis.x;

						if (t_max_axis.y < next_t) {
							next_t = t_max_axis.y;
							step_axis = 1;
						}

						if (t_max_axis.z < next_t) {
							next_t = t_max_axis.z;
							step_axis = 2;
						}

						t = next_t;
						t_max_axis[step_axis] += t_delta[step_axis];
						voxel[step_axis] += step_dir[step_axis];
						voxel_min = min_corner + vec3(voxel) * voxel_debug_data.voxel_size;
						continue;
					}

					if (voxel_in_bounds(voxel)) {
						vec4 sample_color = sample_voxel_neighborhood(voxel);

						if (sample_color.a >= voxel_debug_data.occupancy_threshold) {
							if (voxel_debug_data.view_mode == 1) {
								vec3 normal = estimate_voxel_normal(voxel);
								frag_color = vec4(normal * 0.5 + 0.5, voxel_debug_data.overlay_alpha);
							} else {
								frag_color = vec4(sample_color.rgb, voxel_debug_data.overlay_alpha);
							}
							return;
						}
					}

					int step_axis = 0;
					float next_t = t_max_axis.x;

					if (t_max_axis.y < next_t) {
						next_t = t_max_axis.y;
						step_axis = 1;
					}

					if (t_max_axis.z < next_t) {
						next_t = t_max_axis.z;
						step_axis = 2;
					}

					t = next_t;
					t_max_axis[step_axis] += t_delta[step_axis];
					voxel[step_axis] += step_dir[step_axis];
					voxel_min = min_corner + vec3(voxel) * voxel_debug_data.voxel_size;
				}

				frag_color = vec4(0.0);
			}
		]],
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
		ColorWriteMask = {"r", "g", "b", "a"},
	}
	voxel_debug_pipelines[target_signature] = pipeline
	return pipeline
end

local function get_debug_clipmap_exclusion_bounds(voxelizer, clipmap_index)
	if clipmap_index <= 1 then return nil end

	local finer = voxelizer.GetClipmap and voxelizer.GetClipmap(clipmap_index - 1) or nil

	if not finer then return nil end

	local finer_origin = get_debug_volume_origin(voxelizer, finer)
	local finer_half_span = (finer.world_span or 0) * 0.5
	return {
		min_x = finer_origin.x - finer_half_span,
		min_y = finer_origin.y - finer_half_span,
		min_z = finer_origin.z - finer_half_span,
		max_x = finer_origin.x + finer_half_span,
		max_y = finer_origin.y + finer_half_span,
		max_z = finer_origin.z + finer_half_span,
	}
end

local function draw_voxel_debug_clipmap(voxelizer, clipmap_index)
	current_debug_render_clipmap_index = clipmap_index
	current_debug_exclusion_bounds = selected_clipmap_index == 0 and get_debug_clipmap_exclusion_bounds(voxelizer, clipmap_index) or nil
	local pipeline = ensure_voxel_debug_pipeline(clipmap_index)
	pipeline:SetSamplerConfig(render.GetSamplerFilterConfig())
	pipeline:Draw(render.GetCommandBuffer())
end

event.AddListener("Draw3DForwardOverlay", "debug_voxel_visualizer", function()
	if not show_voxel_debug then return end

	local voxelizer = get_voxelizer()

	if not voxelizer or not voxelizer.IsEnabled or not voxelizer:IsEnabled() then
		return
	end

	clamp_selected_clipmap_index(voxelizer)

	if selected_clipmap_index == 0 then
		for clipmap_index = voxelizer.clipmap_count, 1, -1 do
			draw_voxel_debug_clipmap(voxelizer, clipmap_index)
		end
	else
		draw_voxel_debug_clipmap(voxelizer, selected_clipmap_index)
	end

	current_debug_exclusion_bounds = nil
end)

event.AddListener("Draw2D", "debug_voxel_targets", function(cmd, dt)
	local voxelizer = get_voxelizer()

	if not voxelizer or not voxelizer.IsEnabled or not voxelizer:IsEnabled() then
		return
	end

	local window = system.GetWindow()

	if not window then return end

	if not show_voxel_debug then return end

	local display_index = selected_clipmap_index == 0 and 1 or selected_clipmap_index
	local _, clipmap_index, clipmap, axis_targets = get_selected_clipmap_data(display_index)

	if not clipmap or not axis_targets then
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.55)
		gfx.DrawRoundedRect(10, 10, 320, 58, 6)
		render2d.SetColor(1, 1, 1, 1)
		fonts.SetFont(fonts.GetDefaultFont())
		fonts.GetFont():DrawText("Voxel debug: no voxel targets allocated yet", 18, 20)
		draw_stats_block(voxelizer, 10, 78)
		return
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55)
	gfx.DrawRoundedRect(10, 10, 332, 74, 6)
	render2d.SetColor(1, 1, 1, 1)
	fonts.SetFont(fonts.GetDefaultFont())
	fonts.GetFont():DrawText("Voxel debug " .. get_debug_volume_kind_label() .. " clipmap " .. get_display_clipmap_label(voxelizer), 18, 18)
	fonts.GetFont():DrawText(
		string.format(
			"Resolution %d  Voxel %.3f  Span %.3f",
			clipmap.resolution or 0,
			clipmap.voxel_size or 0,
			clipmap.world_span or 0
		),
		18,
		38
	)
	fonts.GetFont():DrawText("Rendering current clipmap as perspective voxel overlay", 18, 58)
	draw_stats_block(voxelizer, 10, 94)

	if voxel_dump_watch_enabled then
		local signature = get_voxel_debug_signature(get_command_clipmap_index())

		if signature and signature ~= voxel_dump_watch_last_signature then
			voxel_dump_watch_last_signature = signature
			dump_voxel_debug_state(get_command_clipmap_index())
		end
	end
end)

event.AddListener("KeyInput", "debug_voxel_targets_toggle", function(key, press)
	if not press or key ~= "f3" then return end

	if is_control_down() then
		cycle_debug_volume_kind()
		invalidate_voxel_debug_pipeline()
		print("Voxel debug volume: " .. get_debug_volume_kind_label())
		return
	end

	if is_shift_down() then
		local voxelizer = get_voxelizer()
		local count = voxelizer and voxelizer.clipmap_count or 0

		if count <= 0 then
			print("Voxel debug: no clipmaps")
			return
		end

		selected_clipmap_index = (selected_clipmap_index + 1) % (count + 1)
		show_voxel_debug = true
		invalidate_voxel_debug_pipeline()
		print("Voxel debug clipmap: " .. get_display_clipmap_label(voxelizer))
		return
	end

	show_voxel_debug = not show_voxel_debug
	if not show_voxel_debug then invalidate_voxel_debug_pipeline() end
	print("Voxel debug: " .. (show_voxel_debug and "ON" or "OFF"))
end)

commands.Add("voxel_dump_state=number[1]", function(index)
	dump_voxel_debug_state(index)
end)

commands.Add("voxel_dump_camera=number[1]", function(index)
	dump_voxel_camera_mapping(index)
end)

commands.Add("voxel_dump_watch", function()
	voxel_dump_watch_enabled = not voxel_dump_watch_enabled
	voxel_dump_watch_last_signature = nil
	print("Voxel debug watch: " .. (voxel_dump_watch_enabled and "ON" or "OFF"))

	if voxel_dump_watch_enabled then dump_voxel_debug_state(get_command_clipmap_index()) end
end)
