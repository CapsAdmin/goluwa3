local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local voxel_debug = library()
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
	return input.IsKeyDown("left_control") or
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

	return string.format("x=%d y=%d z=%d", values.x or 0, values.y or 0, values.z or 0)
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
	print(
		"  latest origin " .. format_vec3(info.latest_origin) .. " stride=" .. string.format("%.3f", info.snap_stride or 0)
	)
	print(
		"  active origin " .. format_vec3(info.origin) .. " offset_voxels=" .. format_vec3(info.active_to_latest_voxels)
	)
	print(
		"  build origin  " .. format_vec3(info.build_origin) .. " offset_voxels=" .. format_vec3(info.build_to_latest_voxels)
	)
	print(
		"  sampled       " .. tostring(info.sampled_source or "active") .. " origin=" .. format_vec3(info.sampled_origin) .. " offset_voxels=" .. format_vec3(info.sampled_to_latest_voxels)
	)
	print(
		"  targets       active=" .. tostring(info.active_target_id or "nil") .. " v=" .. tostring(info.active_content_version or 0) .. " build=" .. tostring(info.build_target_id or "nil") .. " v=" .. tostring(info.build_content_version or 0) .. " sampled=" .. tostring(info.sampled_target_id or "nil") .. " v=" .. tostring(info.sampled_content_version or 0)
	)
	print(
		"  handoff       mode=" .. tostring(info.last_handoff_mode or "none") .. " origin=" .. format_vec3(info.last_handoff_origin or Vec3(0, 0, 0)) .. " active_v=" .. tostring(info.last_handoff_active_version or 0) .. " build_v=" .. tostring(info.last_handoff_build_version or 0) .. " rescheduled=" .. tostring(info.last_handoff_rescheduled)
	)
	print("  delta voxels  " .. format_vec3(info.delta))
	print(
		"  flags         dirty=" .. tostring(info.dirty) .. " full=" .. tostring(info.full_rebuild) .. " building=" .. tostring(info.building_into_scroll) .. " scroll_ready=" .. tostring(info.build_scroll_ready) .. " valid=" .. tostring(info.has_valid_data) .. " pending_clear=" .. tostring(info.pending_clear) .. " pending_scroll=" .. tostring(info.pending_scroll)
	)
	print(
		"  dirty slabs   " .. format_axis_counts(info.dirty_slabs) .. "  budget=" .. tostring(info.build_slice_budget or 0)
	)
	print("  pending count " .. format_axis_counts(info.pending_counts))
	print(
		"  pending x     " .. format_pending_range(info.pending_ranges and info.pending_ranges.x or nil)
	)
	print(
		"  pending y     " .. format_pending_range(info.pending_ranges and info.pending_ranges.y or nil)
	)
	print(
		"  pending z     " .. format_pending_range(info.pending_ranges and info.pending_ranges.z or nil)
	)
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

	return table.concat(
		{
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
		},
		"|"
	)
end

local function clamp_selected_clipmap_index(voxelizer)
	local count = voxelizer and voxelizer.clipmap_count or 0

	if count <= 0 then
		selected_clipmap_index = 0
		return nil
	end

	if
		selected_clipmap_index == nil or
		selected_clipmap_index < 0 or
		selected_clipmap_index > count
	then
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

	if clipmap_index == nil then
		clipmap_index = current_debug_render_clipmap_index or selected_clipmap_index or 1
	end

	if clipmap_index == 0 and count > 0 then clipmap_index = 1 end

	if not clipmap_index or clipmap_index < 1 or clipmap_index > count then
		return voxelizer, nil, nil
	end

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
	local clipmap_info = voxelizer and
		voxelizer.GetClipmapDebugInfo and
		voxelizer.GetClipmapDebugInfo(get_command_clipmap_index()) or
		nil
	local block_height = clipmap_info and 278 or 150

	if not stats then return end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55)
	render2d.DrawRoundedRect(x, y, 356, block_height, 6)
	local white = Color(1, 1, 1, 1)
	render2d.DrawText{
		text = string.format("Voxel clipmaps: %d", debug_state.clipmap_count or 0),
		x = x + 8,
		y = y + 8,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Updated: %d  Full: %d  Incremental: %d",
			stats.updated_clipmaps or 0,
			stats.full_rebuilds or 0,
			stats.incremental_rebuilds or 0
		),
		x = x + 8,
		y = y + 28,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Build: %d clipmaps  %d axes  %d slices",
			stats.voxel_build_clipmaps or 0,
			stats.voxel_build_axes or 0,
			stats.voxel_build_slices or 0
		),
		x = x + 8,
		y = y + 48,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Geometry: %d visuals  %d entries",
			stats.voxel_visuals or 0,
			stats.voxel_entries or 0
		),
		x = x + 8,
		y = y + 68,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Scroll copy: %d inline  %d fallback  %d submits  %d waits",
			stats.voxel_scroll_inline_clipmaps or 0,
			stats.voxel_scroll_submit_clipmaps or 0,
			stats.voxel_scroll_submissions or 0,
			stats.voxel_scroll_submit_waits or 0
		),
		x = x + 8,
		y = y + 88,
		foreground_color = white,
	}
	render2d.DrawText{
		text = "Clipmap focus: " .. get_display_clipmap_label(voxelizer),
		x = x + 8,
		y = y + 108,
		foreground_color = white,
	}
	render2d.DrawText{
		text = "View: " .. get_debug_volume_kind_label() .. " perspective voxel raymarch",
		x = x + 8,
		y = y + 128,
		foreground_color = white,
	}

	if clipmap_info then
		local status = clipmap_info.build_scroll_ready and
			"Build in progress; showing scrolled build volume" or
			(
				clipmap_info.building_into_scroll and
				"Build in progress; showing committed active volume" or
				"Showing committed active volume"
			)
		local lag = clipmap_info.active_to_latest_voxels or Vec3(0, 0, 0)
		local build_lag = clipmap_info.build_to_latest_voxels or Vec3(0, 0, 0)
		local sampled_lag = clipmap_info.sampled_to_latest_voxels or Vec3(0, 0, 0)
		render2d.DrawText{text = status, x = x + 8, y = y + 144, foreground_color = white, softness = 0}
		render2d.DrawText{
			text = string.format("Active lag voxels: (%.0f, %.0f, %.0f)", lag.x or 0, lag.y or 0, lag.z or 0),
			x = x + 8,
			y = y + 162,
			foreground_color = white,
		}
		render2d.DrawText{
			text = string.format(
				"Build lag voxels:  (%.0f, %.0f, %.0f)",
				build_lag.x or 0,
				build_lag.y or 0,
				build_lag.z or 0
			),
			x = x + 8,
			y = y + 180,
			foreground_color = white,
		}
		render2d.DrawText{
			text = string.format(
				"Sampled: %s lag=(%.0f, %.0f, %.0f)",
				tostring(clipmap_info.sampled_source or "active"),
				sampled_lag.x or 0,
				sampled_lag.y or 0,
				sampled_lag.z or 0
			),
			x = x + 8,
			y = y + 198,
			foreground_color = white,
		}
		render2d.DrawText{
			text = string.format(
				"Dirty slabs: x=%d y=%d z=%d  Pending: x=%d y=%d z=%d",
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.x or 0,
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.y or 0,
				clipmap_info.dirty_slabs and clipmap_info.dirty_slabs.z or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.x or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.y or 0,
				clipmap_info.pending_counts and clipmap_info.pending_counts.z or 0
			),
			x = x + 8,
			y = y + 216,
			foreground_color = white,
		}
		render2d.DrawText{
			text = string.format(
				"Budget: %d  Flags: scroll_ready=%s pending_scroll=%s",
				clipmap_info.build_slice_budget or 0,
				tostring(clipmap_info.build_scroll_ready),
				tostring(clipmap_info.pending_scroll)
			),
			x = x + 8,
			y = y + 234,
			foreground_color = white,
		}
	end

	render2d.DrawText{
		text = "F3: toggle  Shift+F3: all/clipmap  Ctrl+F3: scene/normals",
		x = x + 8,
		y = y + (clipmap_info and 250 or 142),
		foreground_color = white,
	}
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
		ColorWriteMask = "rgba",
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
	current_debug_exclusion_bounds = selected_clipmap_index == 0 and
		get_debug_clipmap_exclusion_bounds(voxelizer, clipmap_index) or
		nil
	local pipeline = ensure_voxel_debug_pipeline(clipmap_index)
	pipeline:Draw(render.GetCommandBuffer())
end

function voxel_debug.DrawForwardOverlay()
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
end

function voxel_debug.DrawHUD()
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
		render2d.DrawRoundedRect(10, 10, 320, 58, 6)
		render2d.DrawText{
			text = "Voxel debug: no voxel targets allocated yet",
			x = 18,
			y = 20,
			softness = 0,
		}
		draw_stats_block(voxelizer, 10, 78)
		return
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55)
	render2d.DrawRoundedRect(10, 10, 332, 74, 6)
	render2d.DrawText{
		text = "Voxel debug " .. get_debug_volume_kind_label() .. " clipmap " .. get_display_clipmap_label(voxelizer),
		x = 18,
		y = 18,
	}
	render2d.DrawText{
		text = string.format(
			"Resolution %d  Voxel %.3f  Span %.3f",
			clipmap.resolution or 0,
			clipmap.voxel_size or 0,
			clipmap.world_span or 0
		),
		x = 18,
		y = 38,
	}
	render2d.DrawText{
		text = "Rendering current clipmap as perspective voxel overlay",
		x = 18,
		y = 58,
		softness = 0,
	}
	draw_stats_block(voxelizer, 10, 94)

	if voxel_dump_watch_enabled then
		local signature = get_voxel_debug_signature(get_command_clipmap_index())

		if signature and signature ~= voxel_dump_watch_last_signature then
			voxel_dump_watch_last_signature = signature
			dump_voxel_debug_state(get_command_clipmap_index())
		end
	end
end

function voxel_debug.HandleKeyInput(key, press)
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
end

function voxel_debug.DumpState(index)
	dump_voxel_debug_state(index)
end

function voxel_debug.DumpCameraMapping(index)
	dump_voxel_camera_mapping(index)
end

function voxel_debug.ToggleDumpWatch()
	voxel_dump_watch_enabled = not voxel_dump_watch_enabled
	voxel_dump_watch_last_signature = nil
	print("Voxel debug watch: " .. (voxel_dump_watch_enabled and "ON" or "OFF"))

	if voxel_dump_watch_enabled then
		dump_voxel_debug_state(get_command_clipmap_index())
	end
end

function voxel_debug.DumpGIState()
	logf(
		"[voxel_gi] enabled=%s active=%s occlusion=%s frame=%d clipmaps=%d\n",
		tostring(voxel_gi.enabled),
		tostring(voxel_gi.IsActive()),
		tostring(voxel_gi.occlusion_enabled),
		voxel_gi.frame,
		voxel_gi.clipmap_count or 0
	)

	for i, cascade in ipairs(voxel_gi.cascades) do
		logf(
			"[voxel_gi] cascade %d spacing=%.2f origin=(%d %d %d) probe_base=%d\n",
			i,
			cascade.spacing,
			cascade.grid_origin.x,
			cascade.grid_origin.y,
			cascade.grid_origin.z,
			cascade.probe_base
		)
	end

	for i, info in ipairs(voxel_gi.clip_info or {}) do
		logf(
			"[voxel_gi] clipmap %d valid=%s origin=(%.1f %.1f %.1f) voxel=%.2f span=%.1f res=%d\n",
			i,
			tostring(info.valid),
			info.origin.x,
			info.origin.y,
			info.origin.z,
			info.voxel_size or 0,
			info.world_span or 0,
			info.resolution or 0
		)
	end
end

local function half_to_float(h)
	local sign = bit.band(bit.rshift(h, 15), 1)
	local exponent = bit.band(bit.rshift(h, 10), 31)
	local mantissa = bit.band(h, 1023)
	local value

	if exponent == 0 then
		value = mantissa * 2 ^ -24
	elseif exponent == 31 then
		value = math.huge
	else
		value = (1 + mantissa / 1024) * 2 ^ (exponent - 15)
	end

	return sign == 1 and -value or value
end

-- Reads back a cascade's atlases and returns a function that decodes one
-- probe: offset, enabled, mean radiance and the visibility mean toward a
-- direction. Slow, for debugging only.
function voxel_debug.ReadGIProbes(cascade_index)
	local cascade = voxel_gi.cascades[cascade_index or 1]

	if not cascade then return nil end

	local irradiance = cascade.irradiance:Download()
	local visibility = cascade.visibility:Download()
	local info = cascade.info:Download()
	local irr_pixels = ffi.cast("uint16_t*", irradiance.pixels)
	local vis_pixels = ffi.cast("uint16_t*", visibility.pixels)
	local info_pixels = ffi.cast("uint16_t*", info.pixels)
	local tile = voxel_gi.IRRADIANCE_OCT_SIZE
	local vis_tile = voxel_gi.VISIBILITY_OCT_SIZE
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}

	local function oct_encode(x, y, z)
		local l = math.abs(x) + math.abs(y) + math.abs(z)
		x, y, z = x / l, y / l, z / l
		local px, py = x, y

		if z < 0 then
			px = (1 - math.abs(y)) * (x >= 0 and 1 or -1)
			py = (1 - math.abs(x)) * (y >= 0 and 1 or -1)
		end

		return px * 0.5 + 0.5, py * 0.5 + 0.5
	end

	return function(gx, gy, gz)
		local sx, sy, sz = gx % counts[1], gy % counts[2], gz % counts[3]
		local tile_x, tile_y = sx, sy * counts[3] + sz
		local info_index = (tile_y * info.width + tile_x) * 4
		local probe = {
			grid = Vec3(gx, gy, gz),
			position = Vec3(gx * cascade.spacing, gy * cascade.spacing, gz * cascade.spacing),
			offset = Vec3(
				half_to_float(info_pixels[info_index]),
				half_to_float(info_pixels[info_index + 1]),
				half_to_float(info_pixels[info_index + 2])
			),
			enabled = half_to_float(info_pixels[info_index + 3]) > 0.0,
			backface_fraction = math.abs(
				half_to_float(info_pixels[info_index + 3]) > 0 and
					half_to_float(info_pixels[info_index + 3]) - 1 or
					half_to_float(info_pixels[info_index + 3])
			),
		}
		local r, g, b = 0, 0, 0

		for ty = 0, tile - 1 do
			for tx = 0, tile - 1 do
				local index = ((tile_y * tile + ty) * irradiance.width + tile_x * tile + tx) * 4
				r = r + half_to_float(irr_pixels[index])
				g = g + half_to_float(irr_pixels[index + 1])
				b = b + half_to_float(irr_pixels[index + 2])
			end
		end

		probe.mean_radiance = Vec3(r / (tile * tile), g / (tile * tile), b / (tile * tile))

		function probe.irradiance(x, y, z)
			local u, v = oct_encode(x, y, z)
			local tx = math.min(math.floor(u * tile), tile - 1)
			local ty = math.min(math.floor(v * tile), tile - 1)
			local index = ((tile_y * tile + ty) * irradiance.width + tile_x * tile + tx) * 4
			return Vec3(
				half_to_float(irr_pixels[index]),
				half_to_float(irr_pixels[index + 1]),
				half_to_float(irr_pixels[index + 2])
			)
		end

		function probe.visibility(x, y, z)
			local u, v = oct_encode(x, y, z)
			local tx = math.min(math.floor(u * vis_tile), vis_tile - 1)
			local ty = math.min(math.floor(v * vis_tile), vis_tile - 1)
			local index = ((tile_y * vis_tile + ty) * visibility.width + tile_x * vis_tile + tx) * 2
			return half_to_float(vis_pixels[index]), half_to_float(vis_pixels[index + 1])
		end

		return probe
	end
end

-- Prints the resolved voxel color and normal around a world position
-- (clipmap 1, a column of voxels along y). Debugging only.
function voxel_debug.DumpGIVoxelColumn(position, half_height)
	local info = voxel_gi.clip_info and voxel_gi.clip_info[1]
	local resolved = voxel_gi.resolved[1]

	if not info or not info.valid or not resolved then return end

	local vs = info.voxel_size
	local min_x = info.origin.x - info.world_span * 0.5
	local min_y = info.origin.y - info.world_span * 0.5
	local min_z = info.origin.z - info.world_span * 0.5
	local vx = math.floor((position.x - min_x) / vs)
	local vz = math.floor((position.z - min_z) / vs)
	local y0 = math.floor((position.y - half_height - min_y) / vs)
	local y1 = math.floor((position.y + half_height - min_y) / vs)
	-- the resolved volume stores voxel (x, y, z) at pixel (x, y) of layer z
	local color = resolved.texture:Download{base_array_layer = vz}
	local normal = resolved.normal_texture:Download{base_array_layer = vz}
	local cp = ffi.cast("uint16_t*", color.pixels)
	local np = ffi.cast("uint8_t*", normal.pixels)
	-- occupancy is the flattened 2d copy the lighting pass marches through
	local occupancy = resolved.occupancy and resolved.occupancy:Download()
	local op = occupancy and ffi.cast("uint8_t*", occupancy.pixels)
	local tiles_x = resolved.tiles_x or 1

	for vy = y0, y1 do
		if vy >= 0 and vy < info.resolution then
			local ci = (vy * color.width + vx) * 4
			local ni = (vy * normal.width + vx) * 4
			local occ = -1

			if op then
				local ox = (vz % tiles_x) * info.resolution + vx
				local oy = math.floor(vz / tiles_x) * info.resolution + vy
				occ = op[oy * occupancy.width + ox] / 255
			end

			logf(
				"[voxel_gi] voxel (%d %d %d) y=[%.2f %.2f) occupancy=%.2f color=(%.2f %.2f %.2f a=%.2f) normal=(%.2f %.2f %.2f a=%.2f)\n",
				vx,
				vy,
				vz,
				min_y + vy * vs,
				min_y + (vy + 1) * vs,
				occ,
				half_to_float(cp[ci]),
				half_to_float(cp[ci + 1]),
				half_to_float(cp[ci + 2]),
				half_to_float(cp[ci + 3]),
				np[ni] / 255 * 2 - 1,
				np[ni + 1] / 255 * 2 - 1,
				np[ni + 2] / 255 * 2 - 1,
				np[ni + 3] / 255
			)
		end
	end
end

function voxel_debug.DumpGIProbesNear(position, radius, cascade_index)
	cascade_index = cascade_index or 1
	local cascade = voxel_gi.cascades[cascade_index]
	local read = voxel_debug.ReadGIProbes(cascade_index)

	if not read then return end

	local spacing = cascade.spacing
	local origin = cascade.grid_origin
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}

	for y = 0, counts[2] - 1 do
		for z = 0, counts[3] - 1 do
			for x = 0, counts[1] - 1 do
				local gx, gy, gz = origin.x + x, origin.y + y, origin.z + z
				local p = Vec3(gx * spacing, gy * spacing, gz * spacing)

				if (p - position):GetLength() <= radius then
					local probe = read(gx, gy, gz)
					local up = probe.irradiance(0, 1, 0)
					local down_mean = probe.visibility(0, -1, 0)
					local x_mean = probe.visibility(1, 0, 0)
					logf(
						"[voxel_gi] probe (%d %d %d) pos=(%.1f %.1f %.1f) offset=(%.2f %.2f %.2f) enabled=%s backface=%.2f mean=(%.3f %.3f %.3f) up=(%.3f %.3f %.3f) vis_down=%.2f vis_x=%.2f\n",
						gx,
						gy,
						gz,
						p.x,
						p.y,
						p.z,
						probe.offset.x,
						probe.offset.y,
						probe.offset.z,
						tostring(probe.enabled),
						probe.backface_fraction,
						probe.mean_radiance.x,
						probe.mean_radiance.y,
						probe.mean_radiance.z,
						up.x,
						up.y,
						up.z,
						down_mean,
						x_mean
					)
				end
			end
		end
	end
end

-- Draws a small sphere per probe near the camera, colored by the probe's
-- mean stored radiance. Disabled probes are drawn dark red.
function voxel_debug.DrawGIDebugProbes()
	if not voxel_gi.debug_probes or not voxel_gi.IsActive() then return end

	local debug_draw = import("goluwa/debug_draw.lua")
	local cascade_index = voxel_gi.debug_probes_cascade or 1
	local cascade = voxel_gi.cascades[cascade_index]

	if not cascade then return end

	voxel_gi.debug_probe_frame = (voxel_gi.debug_probe_frame or 0) + 1

	if voxel_gi.debug_probe_frame % 10 ~= 1 then return end

	local irradiance = cascade.irradiance:Download()
	local info = cascade.info:Download()
	local irr_pixels = ffi.cast("uint16_t*", irradiance.pixels)
	local info_pixels = ffi.cast("uint16_t*", info.pixels)
	local tile = voxel_gi.IRRADIANCE_OCT_SIZE
	local atlas_width = irradiance.width
	local counts = {voxel_gi.PROBE_COUNT_X, voxel_gi.PROBE_COUNT_Y, voxel_gi.PROBE_COUNT_Z}
	local origin = cascade.grid_origin
	local spacing = cascade.spacing
	local camera_position = render3d.GetRenderCamera():GetPosition()
	local radius = voxel_gi.debug_probes_radius or (spacing * 8)
	local exposure = voxel_gi.debug_probes_exposure or 1
	local drawn = 0

	for y = 0, counts[2] - 1 do
		for z = 0, counts[3] - 1 do
			for x = 0, counts[1] - 1 do
				local gx, gy, gz = origin.x + x, origin.y + y, origin.z + z
				local px, py, pz = gx * spacing, gy * spacing, gz * spacing
				local dx, dy, dz = px - camera_position.x, py - camera_position.y, pz - camera_position.z

				if dx * dx + dy * dy + dz * dz < radius * radius then
					local sx, sy, sz = gx % counts[1], gy % counts[2], gz % counts[3]
					local tile_x, tile_y = sx, sy * counts[3] + sz
					local info_index = (tile_y * info.width + tile_x) * 4
					local ox = half_to_float(info_pixels[info_index])
					local oy = half_to_float(info_pixels[info_index + 1])
					local oz = half_to_float(info_pixels[info_index + 2])
					local enabled = half_to_float(info_pixels[info_index + 3]) > 0.0
					local r, g, b = 0, 0, 0

					for ty = 0, tile - 1 do
						for tx = 0, tile - 1 do
							local index = ((tile_y * tile + ty) * atlas_width + tile_x * tile + tx) * 4
							r = r + half_to_float(irr_pixels[index])
							g = g + half_to_float(irr_pixels[index + 1])
							b = b + half_to_float(irr_pixels[index + 2])
						end
					end

					local scale = exposure / (tile * tile)
					local color = enabled and
						Color(math.min(r * scale, 1), math.min(g * scale, 1), math.min(b * scale, 1), 1) or
						Color(0.4, 0, 0, 1)
					drawn = drawn + 1
					debug_draw.DrawSphere{
						id = "voxel_gi_probe_" .. cascade_index .. "_" .. sx .. "_" .. sy .. "_" .. sz,
						position = Vec3(px + ox, py + oy, pz + oz),
						radius = spacing * 0.08,
						color = color,
						emissive = color,
						ignore_z = true,
						translucent = true,
						double_sided = true,
						time = 2.0,
					}
				end
			end
		end
	end

	voxel_gi.debug_probes_drawn = drawn
end

function voxel_debug.SetGIDebugMode(mode)
	voxel_gi.debug_mode = mode
	logf("[voxel_gi] debug mode %d\n", mode)
end

function voxel_debug.SetGIProbeOverlay(enabled, cascade_index)
	voxel_gi.debug_probes = enabled
	voxel_gi.debug_probes_cascade = cascade_index
	logf(
		"[voxel_gi] probe overlay %s cascade %d\n",
		enabled and "enabled" or "disabled",
		cascade_index
	)
end

event.AddListener("Draw3DForwardOverlay", "debug_voxel_visualizer", function()
	voxel_debug.DrawForwardOverlay()
end)

event.AddListener("Draw2D", "debug_voxel_targets", function(cmd, dt)
	voxel_debug.DrawHUD()
end)

event.AddListener("KeyInput", "debug_voxel_targets_toggle", function(key, press)
	voxel_debug.HandleKeyInput(key, press)
end)

event.AddListener("Update", "debug_voxel_gi_probes", function()
	voxel_debug.DrawGIDebugProbes()
end)

commands.Add("voxel_dump_state=number[1]", function(index)
	voxel_debug.DumpState(index)
end)

commands.Add("voxel_dump_camera=number[1]", function(index)
	voxel_debug.DumpCameraMapping(index)
end)

commands.Add("voxel_dump_watch", function()
	voxel_debug.ToggleDumpWatch()
end)

commands.Add("voxel_gi_probes=boolean[true],number[1]", function(enabled, cascade_index)
	voxel_debug.SetGIProbeOverlay(enabled, cascade_index)
end)

commands.Add("voxel_gi_dump", function()
	voxel_debug.DumpGIState()
end)

commands.Add("voxel_gi_debug=number[1]", function(mode)
	voxel_debug.SetGIDebugMode(mode)
end)

return voxel_debug
