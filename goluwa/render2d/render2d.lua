local ffi = require("ffi")
local utility = import("goluwa/utility.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Mesh = import("goluwa/render/mesh.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local RectBatch = import("goluwa/render2d/rect_batch.lua")
local render2d = library()

local function append_fields(base, extra)
	local out = {}

	for i, field in ipairs(base) do
		out[i] = {field[1], field[2], field[3], field[4]}
	end

	for i, field in ipairs(extra) do
		out[#out + 1] = {field[1], field[2], field[3], field[4]}
	end

	return out
end

local vertex_push_constant_fields = {
	{"projection_view_world", "mat4"},
}
local fragment_draw_constant_fields = {
	{"global_color", "vec4"},
	{"texture_index", "int"},
	{"sdf_texture_index", "int"},
	{"uv_offset", "vec2"},
	{"uv_scale", "vec2"},
	{"sdf_uv_bounds", "vec4"},
	{"flags", "int"},
	{"color_uv_offset", "vec2"},
	{"color_uv_scale", "vec2"},
	{"color_uv_rotation", "float"},
}
local fragment_shape_constant_fields = {
	{"blur", "vec2"},
	{"border_radius", "vec4"},
	{"outline_width", "float"},
	{"rect_size", "vec2"},
	{"sdf_threshold", "float"},
	{"sdf_texel_range", "float"},
	{"sdf_rect_size", "vec2"},
	{"sdf_bias", "float"},
	{"sdf_gamma", "float"},
	{"sdf_softness", "float"},
}
local fragment_patch_constant_fields = {
	{"nine_patch_x_count", "int"},
	{"nine_patch_y_count", "int"},
	{"nine_patch_x_stretch", "float", 6},
	{"nine_patch_y_stretch", "float", 6},
}
local fragment_constant_fields = append_fields(
	append_fields(fragment_draw_constant_fields, fragment_shape_constant_fields),
	fragment_patch_constant_fields
)
local rect_draw_state_tail_fields = {
	{"depth_mode_id", "int"},
	{"depth_write", "int"},
	{"stencil_mode_id", "int"},
	{"stencil_ref", "int"},
	{"scissor", "int", 4},
}
local RectDrawState = EasyPipeline.BuildFFIType(
	"scalar",
	"Render2DRectDrawState",
	append_fields(fragment_constant_fields, rect_draw_state_tail_fields)
)
local DEFAULT_BLEND_MODE = "alpha"
local DEFAULT_COLOR_WRITE_MASK = {"r", "g", "b", "a"}
local DEFAULT_DEPTH_MODE = "none"
local depth_mode_to_compare_op = {
	less = "less",
	lequal = "less_or_equal",
	equal = "equal",
	gequal = "greater_or_equal",
	greater = "greater",
	notequal = "not_equal",
	always = "always",
}
local depth_mode_ids = {
	none = 1,
	less = 2,
	lequal = 3,
	equal = 4,
	gequal = 5,
	greater = 6,
	notequal = 7,
	always = 8,
}
local depth_mode_names = {
	[1] = "none",
	[2] = "less",
	[3] = "lequal",
	[4] = "equal",
	[5] = "gequal",
	[6] = "greater",
	[7] = "notequal",
	[8] = "always",
}
local stencil_mode_ids = {
	none = 1,
	write = 2,
	mask_write = 3,
	mask_test = 4,
	mask_decrement = 5,
	test = 6,
	test_inverse = 7,
	greater = 8,
}
local stencil_mode_names = {
	[1] = "none",
	[2] = "write",
	[3] = "mask_write",
	[4] = "mask_test",
	[5] = "mask_decrement",
	[6] = "test",
	[7] = "test_inverse",
	[8] = "greater",
}
local bind_mesh_immediate
local capture_rect_draw_state
local restore_rect_draw_state
local draw_rect_immediate
local ensure_rect_batch_instance_buffer
local apply_scissor_to_command_buffer
render2d.state = {
	render = {
		fragment = {
			constants = RectDrawState(),
			constants_size = ffi.sizeof(RectDrawState),
			rect_size = {w = 0, h = 0, lw = 0, lh = 0},
			uv = {x = nil, y = nil, w = nil, h = nil, sx = nil, sy = nil},
			uv2 = {u1 = nil, v1 = nil, u2 = nil, v2 = nil},
			color_uv = {offset_x = 0, offset_y = 0, scale_x = 1, scale_y = 1, rotation = 0},
			alpha_multiplier = 1,
		},
		textures = {
			texture = nil,
			sdf_texture = nil,
		},
		pipeline = {
			blend = nil,
			depth = {mode = DEFAULT_DEPTH_MODE, write = false},
			stencil = {mode = "none", ref = 0},
			scissor = {x = 0, y = 0, w = 0, h = 0},
		},
		options = {
			clamp_border_radius = true,
			batched_rect_draws_enabled = true,
			rect_batch_mode = "instanced",
			computed_margin = 0,
			computed_margin_dirty = true,
			margin_override = nil,
		},
	},
	runtime = {
		batch = {
			state = RectBatch.New(),
			mode_ids = {
				immediate = 1,
				replay = 2,
				instanced = 3,
			},
			next_entry_slot = 1,
			next_world_matrix_slot = 1,
			next_draw_matrix_slot = 1,
			next_rect_draw_state_snapshot_slot = 1,
		},
		ids = {
			roots = {
				blend = {},
				pipeline = {},
				rect_batch_key = {},
			},
			current = {
				rect_batch_pipeline = nil,
			},
		},
		pipeline_state = {
			dirty = true,
			synced_pipeline = nil,
		},
		frame = {
			next_rect_batch_instance_buffer_slot = 1,
		},
		camera = {
			projection = Matrix44(),
			view = Matrix44(),
			viewport = Rect(0, 0, 512, 512),
			view_pos = Vec2(0, 0),
			view_zoom = Vec2(1, 1),
			view_angle = 0,
			world_matrix_stack = {Matrix44()},
			world_matrix_stack_pos = 1,
			projection_view = Matrix44(),
			projection_view_world = Matrix44(),
		},
		mesh = {
			last_bound = nil,
			last_cmd = nil,
		},
	},
}

local function reset_rect_batch_instance_frame_state()
	render2d.state.runtime.frame.next_rect_batch_instance_buffer_slot = 1
end

local function get_rect_batch_world_matrix(slot)
	render2d.rect_batch_world_matrices = render2d.rect_batch_world_matrices or {}
	local matrix = render2d.rect_batch_world_matrices[slot]

	if not matrix then
		matrix = Matrix44()
		render2d.rect_batch_world_matrices[slot] = matrix
	end

	return matrix
end

local function get_rect_batch_draw_matrix(slot)
	render2d.rect_batch_draw_matrices = render2d.rect_batch_draw_matrices or {}
	local matrix = render2d.rect_batch_draw_matrices[slot]

	if not matrix then
		matrix = Matrix44()
		render2d.rect_batch_draw_matrices[slot] = matrix
	end

	return matrix
end

local function get_rect_batch_entry(slot)
	render2d.rect_batch_entries = render2d.rect_batch_entries or {}
	local entry = render2d.rect_batch_entries[slot]

	if not entry then
		entry = {}
		render2d.rect_batch_entries[slot] = entry
	end

	return entry
end

local function get_rect_draw_state_snapshot(slot)
	render2d.rect_batch_state_snapshots = render2d.rect_batch_state_snapshots or {}
	local snapshot = render2d.rect_batch_state_snapshots[slot]

	if not snapshot then
		snapshot = RectDrawState()
		render2d.rect_batch_state_snapshots[slot] = snapshot
	end

	return snapshot
end

local function reset_rect_batch_matrix_pool_state()
	render2d.state.runtime.batch.next_entry_slot = 1
	render2d.state.runtime.batch.next_world_matrix_slot = 1
	render2d.state.runtime.batch.next_draw_matrix_slot = 1
	render2d.state.runtime.batch.next_rect_draw_state_snapshot_slot = 1
end

local function acquire_rect_batch_world_matrix()
	local batch_runtime = render2d.state.runtime.batch
	local slot = batch_runtime.next_world_matrix_slot
	batch_runtime.next_world_matrix_slot = slot + 1
	return get_rect_batch_world_matrix(slot)
end

local function acquire_rect_batch_draw_matrix()
	local batch_runtime = render2d.state.runtime.batch
	local slot = batch_runtime.next_draw_matrix_slot
	batch_runtime.next_draw_matrix_slot = slot + 1
	return get_rect_batch_draw_matrix(slot)
end

local function acquire_rect_batch_entry()
	local batch_runtime = render2d.state.runtime.batch
	local slot = batch_runtime.next_entry_slot
	batch_runtime.next_entry_slot = slot + 1
	return get_rect_batch_entry(slot)
end

local function assert_rect_batch_mode(mode, kind, allow_immediate)
	if
		not render2d.state.runtime.batch.mode_ids[mode] or
		(
			not allow_immediate and
			mode == "immediate"
		)
	then
		error("invalid " .. kind .. ": " .. tostring(mode), 2)
	end
end

function render2d.SetRectBatchMode(mode)
	assert_rect_batch_mode(mode, "rect batch mode", true)
	render2d.state.render.options.rect_batch_mode = mode
end

function render2d.GetRectBatchMode()
	return render2d.state.render.options.rect_batch_mode
end

utility.MakePushPopFunction(render2d, "RectBatchMode", 1)

local function build_rect_draw_matrix(base_world_matrix, x, y, w, h, a, ox, oy, margin, use_float, out_matrix)
	local projected = out_matrix or Matrix44()
	local qw = w + margin * 2
	local qh = h + margin * 2
	Matrix44.CopyTo(base_world_matrix, projected)

	if x and y then
		if use_float then
			projected:Translate(x - margin, y - margin, 0)
		else
			projected:Translate(math.ceil(x - margin), math.ceil(y - margin), 0)
		end
	end

	-- Fast path for text rendering: no rotation, no offset
	if not a and not ox then
		if w and h then
			if use_float then
				projected:Scale(qw, qh, 1)
			else
				projected:Scale(math.ceil(qw), math.ceil(qh), 1)
			end
		end

		projected:GetMultiplied(render2d.GetProjectionViewMatrix(), projected)
		return projected, qw, qh
	end

	if a then projected:Rotate(a, 0, 0, 1) end

	if ox then
		if use_float then
			projected:Translate(-ox, -oy, 0)
		else
			projected:Translate(math.ceil(-ox), math.ceil(-oy), 0)
		end
	end

	if w and h then
		if use_float then
			projected:Scale(qw, qh, 1)
		else
			projected:Scale(math.ceil(qw), math.ceil(qh), 1)
		end
	end

	projected:GetMultiplied(render2d.GetProjectionViewMatrix(), projected)
	return projected, qw, qh
end

local function build_rect_batch_key(state, w, h, margin, batch_mode)
	local batch_mode_id = render2d.state.runtime.batch.mode_ids[batch_mode] or 0
	local snapshot = state.rect_state_snapshot
	return table.intern_key(
		render2d.state.runtime.ids.roots.rect_batch_key,
		batch_mode_id,
		state.pipeline_state_id,
		state.blend_mode.batch_key,
		snapshot.nine_patch_x_count,
		snapshot.nine_patch_y_count,
		snapshot.nine_patch_x_stretch[0],
		snapshot.nine_patch_x_stretch[1],
		snapshot.nine_patch_x_stretch[2],
		snapshot.nine_patch_x_stretch[3],
		snapshot.nine_patch_x_stretch[4],
		snapshot.nine_patch_x_stretch[5],
		snapshot.nine_patch_y_stretch[0],
		snapshot.nine_patch_y_stretch[1],
		snapshot.nine_patch_y_stretch[2],
		snapshot.nine_patch_y_stretch[3],
		snapshot.nine_patch_y_stretch[4],
		snapshot.nine_patch_y_stretch[5],
		snapshot.depth_mode_id,
		snapshot.depth_write,
		snapshot.stencil_mode_id,
		snapshot.stencil_ref,
		snapshot.scissor[0],
		snapshot.scissor[1],
		snapshot.scissor[2],
		snapshot.scissor[3]
	)
end

local function get_rect_batch_instance_uv_transform(entry)
	local rect_state_snapshot = entry.state.rect_state_snapshot
	local off_x = rect_state_snapshot.uv_offset[0]
	local off_y = rect_state_snapshot.uv_offset[1]
	local scale_x = rect_state_snapshot.uv_scale[0]
	local scale_y = rect_state_snapshot.uv_scale[1]
	local margin = entry.margin or 0

	if margin > 0 and entry.w > 0 and entry.h > 0 then
		scale_x = scale_x * (entry.qw / entry.w)
		scale_y = scale_y * (entry.qh / entry.h)
		off_x = off_x - (margin / entry.w) * rect_state_snapshot.uv_scale[0]
		off_y = off_y - (margin / entry.h) * rect_state_snapshot.uv_scale[1]
	end

	return off_x, off_y, scale_x, scale_y
end

local rect_batch_fragment_passthrough_fields = {
	{
		name = "batch_global_color",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			ffi.copy(vertex.batch_global_color, rect_state_snapshot.global_color, ffi.sizeof("float") * 4)
			vertex.batch_global_color[3] = vertex.batch_global_color[3] * state.alpha_multiplier
		end,
		fragment_values = {
			{"draw.global_color", "batch_global_color", "in_batch_global_color"},
		},
	},
	{
		name = "batch_uv_transform",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(
			vertex,
			entry,
			state,
			rect_state_snapshot,
			uv_off_x,
			uv_off_y,
			uv_scale_x,
			uv_scale_y
		)
			vertex.batch_uv_transform[0] = uv_off_x
			vertex.batch_uv_transform[1] = uv_off_y
			vertex.batch_uv_transform[2] = uv_scale_x
			vertex.batch_uv_transform[3] = uv_scale_y
		end,
		fragment_values = {
			{"draw.uv_offset", "batch_uv_offset", "in_batch_uv_transform.xy"},
			{"draw.uv_scale", "batch_uv_scale", "in_batch_uv_transform.zw"},
		},
	},
	{
		name = "batch_shape_state",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_shape_state[0] = rect_state_snapshot.blur[0]
			vertex.batch_shape_state[1] = rect_state_snapshot.blur[1]
			vertex.batch_shape_state[2] = rect_state_snapshot.flags
			vertex.batch_shape_state[3] = 0
		end,
		fragment_values = {
			{"shape.blur", "batch_blur", "in_batch_shape_state.xy"},
			{"draw.flags", {"int", "batch_flags"}, "int(round(in_batch_shape_state.z))"},
		},
	},
	{
		name = "batch_border_radius",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			ffi.copy(vertex.batch_border_radius, rect_state_snapshot.border_radius, ffi.sizeof("float") * 4)
		end,
		fragment_values = {
			{"shape.border_radius", "batch_border_radius", "in_batch_border_radius"},
		},
	},
	{
		name = "batch_rect_geometry",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_rect_geometry[0] = entry.qw
			vertex.batch_rect_geometry[1] = entry.qh
			vertex.batch_rect_geometry[2] = entry.w
			vertex.batch_rect_geometry[3] = entry.h
		end,
		fragment_values = {
			{"shape.rect_size", "batch_rect_size", "in_batch_rect_geometry.xy"},
			{"shape.sdf_rect_size", "batch_sdf_rect_size", "in_batch_rect_geometry.zw"},
		},
	},
	{
		name = "batch_material_state",
		type = "vec3",
		format = "r32g32b32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_material_state[0] = rect_state_snapshot.sdf_threshold
			vertex.batch_material_state[1] = rect_state_snapshot.sdf_texel_range
			vertex.batch_material_state[2] = state.texture and
				render2d.rect_batch_pipeline:GetTextureIndex(state.texture) or
				-1
		end,
		fragment_values = {
			{"shape.sdf_threshold", "batch_sdf_threshold", "in_batch_material_state.x"},
			{"shape.sdf_texel_range", "batch_sdf_texel_range", "in_batch_material_state.y"},
			{
				"draw.texture_index",
				{"int", "batch_texture_index"},
				"int(round(in_batch_material_state.z))",
			},
		},
	},
	{
		name = "batch_sdf_texture_index",
		type = "float",
		format = "r32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_sdf_texture_index = state.sdf_texture and
				render2d.rect_batch_pipeline:GetTextureIndex(state.sdf_texture) or
				-1
		end,
		fragment_values = {
			{
				"draw.sdf_texture_index",
				{"int", "batch_sdf_texture_index"},
				"int(round(in_batch_sdf_texture_index))",
			},
		},
	},
	{
		name = "batch_color_uv_transform",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_color_uv_transform[0] = rect_state_snapshot.color_uv_offset[0]
			vertex.batch_color_uv_transform[1] = rect_state_snapshot.color_uv_offset[1]
			vertex.batch_color_uv_transform[2] = rect_state_snapshot.color_uv_scale[0]
			vertex.batch_color_uv_transform[3] = rect_state_snapshot.color_uv_scale[1]
		end,
		fragment_values = {
			{
				"draw.color_uv_offset",
				"batch_color_uv_transform",
				"in_batch_color_uv_transform.xy",
			},
			{"draw.color_uv_scale", "batch_color_uv_scale", "in_batch_color_uv_transform.zw"},
		},
	},
	{
		name = "batch_color_uv_rotation",
		type = "float",
		format = "r32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_color_uv_rotation = rect_state_snapshot.color_uv_rotation
		end,
		fragment_values = {
			{
				"draw.color_uv_rotation",
				"batch_color_uv_rotation",
				"in_batch_color_uv_rotation",
			},
		},
	},
	{
		name = "batch_outline_width",
		type = "float",
		format = "r32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_outline_width = rect_state_snapshot.outline_width
		end,
		fragment_values = {
			{"shape.outline_width", "batch_outline_width", "in_batch_outline_width"},
		},
	},
	{
		name = "batch_sdf_tuning",
		type = "vec3",
		format = "r32g32b32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_sdf_tuning[0] = rect_state_snapshot.sdf_bias
			vertex.batch_sdf_tuning[1] = rect_state_snapshot.sdf_gamma
			vertex.batch_sdf_tuning[2] = rect_state_snapshot.sdf_softness
		end,
		fragment_values = {
			{"shape.sdf_bias", "batch_sdf_bias", "in_batch_sdf_tuning.x"},
			{"shape.sdf_gamma", "batch_sdf_gamma", "in_batch_sdf_tuning.y"},
			{"shape.sdf_softness", "batch_sdf_softness", "in_batch_sdf_tuning.z"},
		},
	},
	{
		name = "batch_sdf_uv_bounds",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_sdf_uv_bounds[0] = rect_state_snapshot.sdf_uv_bounds[0]
			vertex.batch_sdf_uv_bounds[1] = rect_state_snapshot.sdf_uv_bounds[1]
			vertex.batch_sdf_uv_bounds[2] = rect_state_snapshot.sdf_uv_bounds[2]
			vertex.batch_sdf_uv_bounds[3] = rect_state_snapshot.sdf_uv_bounds[3]
		end,
		fragment_values = {
			{"draw.sdf_uv_bounds", "batch_sdf_uv_bounds", "in_batch_sdf_uv_bounds"},
		},
	},
}
local rect_batch_matrix_copy_size = ffi.sizeof("float") * 16

local function write_rect_batch_instance(vertex, entry)
	local matrix = entry.draw_matrix
	local state = entry.state
	local rect_state_snapshot = state.rect_state_snapshot
	local uv_off_x, uv_off_y, uv_scale_x, uv_scale_y = get_rect_batch_instance_uv_transform(entry)
	ffi.copy(vertex.pvw, matrix, rect_batch_matrix_copy_size)

	for _, field in ipairs(rect_batch_fragment_passthrough_fields) do
		field.write(
			vertex,
			entry,
			state,
			rect_state_snapshot,
			uv_off_x,
			uv_off_y,
			uv_scale_x,
			uv_scale_y
		)
	end
end

function render2d.GetBatchState()
	return render2d.state.runtime.batch.state
end

function render2d.HasPendingBatches()
	return render2d.state.runtime.batch.state:HasPending()
end

function render2d.MarkBatchesPending(count)
	return render2d.state.runtime.batch.state:MarkPending(count)
end

function render2d.ClearPendingBatches()
	render2d.state.runtime.batch.state:ClearPending()
	reset_rect_batch_matrix_pool_state()
end

function render2d.SaveBatchState()
	local batch = render2d.state.runtime.batch
	local state = batch.state
	return {
		pending_draws = state.pending_draws,
		segments = list.copy(state.segments),
	}
end

function render2d.RestoreBatchState(saved)
	local state = render2d.state.runtime.batch.state
	state.pending_draws = saved.pending_draws
	state.segments = saved.segments
end

function render2d.MarkPipelineStateDirty()
	render2d.state.runtime.pipeline_state.dirty = true
end

local function get_valid_blend_preset_error(mode_name)
	local valid_modes = {}

	for k in pairs(render2d.blend_modes) do
		table.insert(valid_modes, k)
	end

	table.sort(valid_modes)
	return "Invalid blend mode: " .. tostring(mode_name) .. ". Valid modes: " .. table.concat(valid_modes, ", ")
end

local function canonicalize_blend_mode_state(state)
	local blend = state.blend

	if blend == nil then
		blend = state.src_color_blend_factor ~= nil or
			state.dst_color_blend_factor ~= nil or
			state.color_blend_op ~= nil or
			state.src_alpha_blend_factor ~= nil or
			state.dst_alpha_blend_factor ~= nil or
			state.alpha_blend_op ~= nil
	end

	local color_write_mask = list.copy(state.color_write_mask or DEFAULT_COLOR_WRITE_MASK)
	local canonical_blend = blend == true
	local src_color_blend_factor = state.src_color_blend_factor or "one"
	local dst_color_blend_factor = state.dst_color_blend_factor or "zero"
	local color_blend_op = state.color_blend_op or "add"
	local src_alpha_blend_factor = state.src_alpha_blend_factor or "one"
	local dst_alpha_blend_factor = state.dst_alpha_blend_factor or "zero"
	local alpha_blend_op = state.alpha_blend_op or "add"
	return {
		blend = canonical_blend,
		src_color_blend_factor = src_color_blend_factor,
		dst_color_blend_factor = dst_color_blend_factor,
		color_blend_op = color_blend_op,
		src_alpha_blend_factor = src_alpha_blend_factor,
		dst_alpha_blend_factor = dst_alpha_blend_factor,
		alpha_blend_op = alpha_blend_op,
		color_write_mask = color_write_mask,
		batch_key = table.intern_key(
			render2d.state.runtime.ids.roots.blend,
			canonical_blend,
			src_color_blend_factor,
			dst_color_blend_factor,
			color_blend_op,
			src_alpha_blend_factor,
			dst_alpha_blend_factor,
			alpha_blend_op,
			color_write_mask[1],
			color_write_mask[2],
			color_write_mask[3],
			color_write_mask[4]
		),
	}
end

local function get_blend_preset_state(mode_name)
	mode_name = mode_name or DEFAULT_BLEND_MODE
	local preset = render2d.blend_modes[mode_name]

	if not preset then error(get_valid_blend_preset_error(mode_name), 3) end

	return canonicalize_blend_mode_state(preset)
end

local function sync_pipeline_state(force)
	local pipeline = render2d.GetActivePipeline()

	if
		not force and
		not render2d.state.runtime.pipeline_state.dirty and
		render2d.state.runtime.pipeline_state.synced_pipeline == pipeline
	then
		return
	end

	local blend_mode = render2d.state.render.pipeline.blend or
		get_blend_preset_state(DEFAULT_BLEND_MODE)
	local depth_state = render2d.state.render.pipeline.depth
	local stencil_state = render2d.state.render.pipeline.stencil
	local depth_mode_name = depth_state.mode or DEFAULT_DEPTH_MODE
	local depth_write = depth_state.write == true
	local stencil_mode_name = stencil_state.mode or "none"
	local stencil_ref = stencil_state.ref ~= nil and stencil_state.ref or 1
	local stencil_mode = render2d.stencil_modes[stencil_mode_name]
	local depth_compare_op = depth_mode_to_compare_op[depth_mode_name] or "always"
	local cmd = assert(render.GetCommandBuffer())

	do -- blend
		pipeline:SetBlend(blend_mode.blend)
		pipeline:SetSrcColorBlendFactor(blend_mode.src_color_blend_factor)
		pipeline:SetDstColorBlendFactor(blend_mode.dst_color_blend_factor)
		pipeline:SetColorBlendOp(blend_mode.color_blend_op)
		pipeline:SetSrcAlphaBlendFactor(blend_mode.src_alpha_blend_factor)
		pipeline:SetDstAlphaBlendFactor(blend_mode.dst_alpha_blend_factor)
		pipeline:SetAlphaBlendOp(blend_mode.alpha_blend_op)
		pipeline:SetColorWriteMask(stencil_mode.color_write_mask or blend_mode.color_write_mask)
	end

	pipeline:SetDepthTest(depth_mode_name ~= DEFAULT_DEPTH_MODE)
	pipeline:SetDepthWrite(depth_write)
	pipeline:SetDepthCompareOp(depth_compare_op)

	do -- stencil
		pipeline:SetStencilTest(stencil_mode.stencil_test)
		pipeline:SetFrontStencilFailOp(stencil_mode.front.fail_op)
		pipeline:SetFrontStencilPassOp(stencil_mode.front.pass_op)
		pipeline:SetFrontStencilDepthFailOp(stencil_mode.front.depth_fail_op)
		pipeline:SetFrontStencilCompareOp(stencil_mode.front.compare_op)
		pipeline:SetFrontStencilReference(stencil_ref)
		pipeline:SetFrontStencilCompareMask(0xFF)
		pipeline:SetFrontStencilWriteMask(0xFF)
		pipeline:SetBackStencilFailOp(stencil_mode.front.fail_op)
		pipeline:SetBackStencilPassOp(stencil_mode.front.pass_op)
		pipeline:SetBackStencilDepthFailOp(stencil_mode.front.depth_fail_op)
		pipeline:SetBackStencilCompareOp(stencil_mode.front.compare_op)
		pipeline:SetBackStencilReference(stencil_ref)
		pipeline:SetBackStencilCompareMask(0xFF)
		pipeline:SetBackStencilWriteMask(0xFF)
	end

	pipeline:Bind(cmd, render.GetCurrentFrame())
	render2d.state.runtime.pipeline_state.dirty = false
	render2d.state.runtime.pipeline_state.synced_pipeline = pipeline
end

local function get_render2d_fragment_constants_source()
	return render2d.state.render.fragment.constants
end

function render2d.FlushBatches(reason)
	local batch_state = render2d.state.runtime.batch.state

	if not batch_state:BeginFlush(reason) then return false end

	local batch_state = render2d.state.runtime.batch.state
	local saved_state = capture_rect_draw_state()
	local saved_batched_rect_draws_enabled = render2d.state.render.options.batched_rect_draws_enabled
	local saved_shader_override = render2d.shader_override
	local flushed_draws = 0
	local gpu_rect_draw_calls = 0
	local instanced_draws = 0
	local instanced_segments = 0
	local replay_draws = 0
	local max_segment_size = 0
	render2d.state.render.options.batched_rect_draws_enabled = false

	for _, segment in ipairs(batch_state.segments) do
		max_segment_size = math.max(max_segment_size, #segment.entries)

		if
			segment.kind == "rect" and
			segment.entries[1] and
			segment.entries[1].batch_mode == "instanced" and
			render2d.rect_batch_pipeline
		then
			local first = segment.entries[1]
			local instance_buffer = ensure_rect_batch_instance_buffer(render2d.state.runtime.frame.next_rect_batch_instance_buffer_slot, #segment.entries)
			local vertices = instance_buffer:GetVertices()
			render2d.state.runtime.frame.next_rect_batch_instance_buffer_slot = render2d.state.runtime.frame.next_rect_batch_instance_buffer_slot + 1

			for i, entry in ipairs(segment.entries) do
				write_rect_batch_instance(vertices[i - 1], entry)
			end

			instance_buffer:Upload()
			restore_rect_draw_state(first.state)
			render2d.shader_override = render2d.rect_batch_pipeline
			sync_pipeline_state(true)
			render2d.rect_mesh:BindInstanced(render.GetCommandBuffer(), {instance_buffer}, 0)
			render2d.UploadConstants(first.qw, first.qh, first.w, first.h)
			render2d.rect_mesh:DrawIndexed(render.GetCommandBuffer(), 6, #segment.entries, 0, 0, 0)
			gpu_rect_draw_calls = gpu_rect_draw_calls + 1
			instanced_draws = instanced_draws + #segment.entries
			instanced_segments = instanced_segments + 1
			render2d.shader_override = saved_shader_override
			render2d.state.runtime.mesh.last_bound = nil
			flushed_draws = flushed_draws + #segment.entries
		else
			for _, entry in ipairs(segment.entries) do
				restore_rect_draw_state(entry.state)
				draw_rect_immediate(
					entry.x,
					entry.y,
					entry.w,
					entry.h,
					entry.a,
					entry.ox,
					entry.oy,
					entry.margin,
					entry.use_float
				)
				gpu_rect_draw_calls = gpu_rect_draw_calls + 1
				replay_draws = replay_draws + 1
				flushed_draws = flushed_draws + 1
			end
		end
	end

	restore_rect_draw_state(saved_state)
	render2d.shader_override = saved_shader_override
	render2d.state.render.options.batched_rect_draws_enabled = saved_batched_rect_draws_enabled
	batch_state:FinishFlush(
		flushed_draws,
		{
			queued_draws = flushed_draws,
			queued_segments = #batch_state.segments,
			gpu_rect_draw_calls = gpu_rect_draw_calls,
			instanced_draws = instanced_draws,
			instanced_segments = instanced_segments,
			replay_draws = replay_draws,
			max_segment_size = max_segment_size,
		}
	)
	reset_rect_batch_matrix_pool_state()
	return flushed_draws > 0
end

render2d.blend_modes = {
	alpha = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	additive = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "add",
		src_alpha_blend_factor = "zero",
		dst_alpha_blend_factor = "one",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	multiply = {
		blend = true,
		src_color_blend_factor = "dst_color",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "dst_alpha",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	premultiplied = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	screen = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_color",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	subtract = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "reverse_subtract",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one",
		alpha_blend_op = "reverse_subtract",
		color_write_mask = {"r", "g", "b", "a"},
	},
	none = {
		blend = false,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
}

function render2d.Initialize()
	if render2d.pipeline then return end

	import("goluwa/render2d/render2d_extensions.lua")
	local config = {
		name = "render2d",
		dont_create_framebuffers = true,
		ConstantPlacement = {
			mode = "auto",
			fallback = "uniform_buffer",
		},
		RasterizationSamples = render.target:GetSamples(),
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			constants = {
				{
					name = "camera",
					storage = "push",
					block = vertex_push_constant_fields,
					write = function(self, block)
						block.projection_view_world = ffi.cast(block.projection_view_world, render2d.GetMatrix():GetFloatPointer())
					end,
				},
			},
			attributes = {
				{"pos", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"sample_uv", "vec2", "r32g32_sfloat"},
				{"color", "vec4", "r32g32b32a32_sfloat"},
			},
			shader = [[
				void main() {
					gl_Position = camera.projection_view_world * vec4(in_pos, 1.0);
					out_uv = in_uv;
					out_sample_uv = in_sample_uv;
					out_color = in_color;
				}
			]],
		},
		fragment = {
			constants = {
				{
					name = "draw",
					storage = "auto",
					prefer = "push",
					priority = 100,
					source = {
						get = get_render2d_fragment_constants_source,
						ctype = RectDrawState,
						field = "global_color",
					},
					block = fragment_draw_constant_fields,
					write = function(self, block)
						block.global_color[3] = block.global_color[3] * render2d.state.render.fragment.alpha_multiplier
						block.texture_index = render2d.state.render.textures.texture and
							self:GetTextureIndex(render2d.state.render.textures.texture) or
							-1
						block.sdf_texture_index = render2d.state.render.textures.sdf_texture and
							self:GetTextureIndex(render2d.state.render.textures.sdf_texture) or
							-1
						return block
					end,
				},
				{
					name = "shape",
					storage = "auto",
					prefer = "push",
					priority = 50,
					source = {
						get = get_render2d_fragment_constants_source,
						ctype = RectDrawState,
						field = "blur",
					},
					block = fragment_shape_constant_fields,
					write = function(self, block)
						block.rect_size[0] = render2d.state.render.fragment.rect_size.w
						block.rect_size[1] = render2d.state.render.fragment.rect_size.h
						block.sdf_rect_size[0] = render2d.state.render.fragment.rect_size.lw
						block.sdf_rect_size[1] = render2d.state.render.fragment.rect_size.lh
						return block
					end,
				},
				{
					name = "nine_patch",
					storage = "auto",
					prefer = "uniform_buffer",
					priority = 0,
					source = {
						get = get_render2d_fragment_constants_source,
						ctype = RectDrawState,
						field = "nine_patch_x_count",
					},
					block = fragment_patch_constant_fields,
				},
			},
			shader = render2d.BuildShaderFlags("draw.flags") .. "\n" .. [[
				float sd_rect(vec2 coords) {

					vec2 quad_size = shape.rect_size;
					vec2 logical_size = shape.sdf_rect_size;
					vec4 radius = shape.border_radius;

					float min_dim = min(logical_size.x, logical_size.y);
					if (FLAGS_CLAMP_BORDER_RADIUS != 0) {
						radius = clamp(radius, 0.0, min_dim * 0.5);
					}
					vec2 p = (coords - 0.5) * quad_size;
					vec2 b = logical_size * 0.5;

					float rad;
					if (p.x < 0.0 && p.y < 0.0) rad = radius.x;
					else if (p.x > 0.0 && p.y < 0.0) rad = radius.y;
					else if (p.x > 0.0 && p.y > 0.0) rad = radius.z;
					else rad = radius.w;

					vec2 sharp_q = abs(p) - b;
					float sharp_rect = min(max(sharp_q.x, sharp_q.y), 0.0) + length(max(sharp_q, vec2(0.0)));
					float half_dim = min_dim * 0.5;
					float full_dim = min_dim;

					if (rad < 0.0) {
						float concave = -rad;
						vec2 corner_sign = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
						vec2 edge_local = max(vec2(0.0), b - p * corner_sign);
						float span = max(concave, 0.0001);
						float sag = concave * 0.5;
						float edge_t_x = clamp(edge_local.x / span, 0.0, 1.0);
						float edge_t_y = clamp(edge_local.y / span, 0.0, 1.0);
						float edge_curve_x = 2.0 * sag * edge_t_x * (1.0 - edge_t_x);
						float edge_curve_y = 2.0 * sag * edge_t_y * (1.0 - edge_t_y);
						float horizontal_notch = max(
							max(-edge_local.x, edge_local.x - span),
							edge_local.y - edge_curve_x
						);
						float vertical_notch = max(
							max(-edge_local.y, edge_local.y - span),
							edge_local.x - edge_curve_y
						);
						return max(sharp_rect, max(-horizontal_notch, -vertical_notch));
					}

					float inset = min(rad, half_dim);
					vec2 q = abs(p) - b + inset;

					if (rad > full_dim && half_dim > 0.001) {
						float mirror_rad = max(0.0, full_dim * 2.0 - rad);
						float norm_rad = mirror_rad / max(half_dim, 0.0001);
						float exp_p = clamp(2.0 / max(norm_rad, 0.0001), 0.1, 200.0);
						vec2 corner = clamp(b - abs(p), vec2(0.0), vec2(half_dim));
						vec2 np = corner / max(half_dim, 0.0001);
						float lp = pow(pow(np.x, exp_p) + pow(np.y, exp_p), 1.0 / exp_p);
						float notch = (1.0 - lp) * half_dim-min(2, exp_p);
						return max(sharp_rect, notch);
					}

					if (q.x <= 0.0 || q.y <= 0.0) {
						return max(q.x, q.y) - inset;
					} else {
						if (inset < 0.001) return length(q);
						float norm_rad = rad / max(half_dim, 0.0001);
						float exp_p = clamp(2.0 / max(norm_rad, 0.0001), 0.1, 200.0);
						vec2 np = q / inset;
						float lp = pow(pow(np.x, exp_p) + pow(np.y, exp_p), 1.0 / exp_p);
						return (lp - 1.0) * inset;
					}
				}

				float map_nine_patch(float x, float tw, float sw, float stretch[6], int count) 
				{
					if (count == 0 || tw <= 0.0 || sw <= 0.0) return x / sw;
					
					float fixed_total = sw;
					float stretch_total_src = 0.0;
					for (int i = 0; i < 3; i++) {
						if (i >= count) break;
						float s = stretch[i*2];
						float e = stretch[i*2+1];
						stretch_total_src += (e - s);
					}
					fixed_total -= stretch_total_src;
					
					float stretch_total_tgt = max(0.0, tw - fixed_total);
					float k = (stretch_total_src > 0.0) ? (stretch_total_tgt / stretch_total_src) : 0.0;
					
					float curr_src = 0.0;
					float curr_tgt = 0.0;
					
					for (int i = 0; i < 3; i++) {
						if (i >= count) break;
						float s = stretch[i*2];
						float e = stretch[i*2+1];
						
						float fixed_size = s - curr_src;
						if (x < curr_tgt + fixed_size) {
							return (curr_src + (x - curr_tgt)) / sw;
						}
						curr_src += fixed_size;
						curr_tgt += fixed_size;
						
						float stretch_size_src = e - s;
						float stretch_size_tgt = stretch_size_src * k;
						if (x < curr_tgt + stretch_size_tgt) {
							float ratio = (k > 0.0) ? ((x - curr_tgt) / k) : 0.0;
							return (curr_src + ratio) / sw;
						}
						curr_src += stretch_size_src;
						curr_tgt += stretch_size_tgt;
					}
					
					return (curr_src + (x - curr_tgt)) / sw;
				}

				vec2 get_uv_color(vec2 coords) {
					vec2 uv = coords;

					if (draw.texture_index >= 0 && (nine_patch.nine_patch_x_count > 0 || nine_patch.nine_patch_y_count > 0)) {
						vec2 tex_size = vec2(textureSize(TEXTURE(draw.texture_index), 0));
						vec2 p_logical = (coords - 0.5) * shape.rect_size + shape.sdf_rect_size * 0.5;

						if (nine_patch.nine_patch_x_count > 0) {
							uv.x = map_nine_patch(p_logical.x, shape.sdf_rect_size.x, tex_size.x, nine_patch.nine_patch_x_stretch, nine_patch.nine_patch_x_count);
						}

						if (nine_patch.nine_patch_y_count > 0) {
							uv.y = map_nine_patch(p_logical.y, shape.sdf_rect_size.y, tex_size.y, nine_patch.nine_patch_y_stretch, nine_patch.nine_patch_y_count);
						}
					}

					vec2 color_uv = uv;
					vec2 centered = color_uv - 0.5;
					float c = cos(draw.color_uv_rotation);
					float s = sin(draw.color_uv_rotation);
					mat2 rot = mat2(c, -s, s, c);
					color_uv = rot * centered + 0.5;
					color_uv = color_uv * draw.color_uv_scale + draw.color_uv_offset;

					return color_uv;
				}

				vec2 get_uv_sdf(vec2 coords) {
					vec2 uv = coords;
					if (draw.sdf_texture_index != -1) {
						bool use_direct_sample_uv = (FLAGS_SAMPLE_UV & 1) != 0;
						uv = use_direct_sample_uv ? in_sample_uv : (in_sample_uv * draw.uv_scale + draw.uv_offset);
					}

					float bounds_left = min(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_right = max(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_top = min(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					float bounds_bottom = max(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					
					uv = clamp(uv, vec2(bounds_left, bounds_top), vec2(bounds_right, bounds_bottom));

					return uv;
				}
			
				float compute_blur_alpha(vec2 coords) {
					vec2 p = (coords - 0.5) * shape.rect_size;
					vec2 b = max(vec2(0.0), (shape.rect_size - shape.blur * 2.0) * 0.5);
					vec2 q = abs(p) - b;
					float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
					float max_blur = max(shape.blur.x, shape.blur.y);
					return smoothstep(max_blur, 0.0, dist);
				}

				float edge(float x) {
					float softness = shape.sdf_softness;
					return smoothstep(-softness, softness, x);
				}
					
				float compute_sdf_alpha(float d) {
					float alpha = edge(d);

					float outline = shape.outline_width;

					if (outline != 0) 
						alpha = sign(outline) * abs(edge(d + outline) - edge(d));

					return pow(max(alpha, 0.0), shape.sdf_gamma);
				}
				
				float median_of_three(vec3 s) {
					return max(min(s.r, s.g), min(max(s.r, s.g), s.b));
				}

				float read_raw_sdf(vec2 coords) {
					float d;
					if (FLAGS_MSDF != 0) {
						d = median_of_three(texture(TEXTURE(draw.sdf_texture_index), coords).rgb);
					} else {
						d = texture(TEXTURE(draw.sdf_texture_index), coords).r;
					}

					float bounds_left = min(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_right = max(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_top = min(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					float bounds_bottom = max(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					float x_fade = min(coords.x - bounds_left, bounds_right - coords.x)*5000;
					float y_fade = min(coords.y - bounds_top, bounds_bottom - coords.y)*5000;

					d *= clamp(x_fade*y_fade, 0, 1);
					return d;
				}
					
				float get_sdf(vec2 coords) {
					float a = 1;

					if (draw.sdf_texture_index != -1) {
						float range = shape.sdf_texel_range;
						float d = read_raw_sdf(coords);
						d *= range;
						d -= shape.sdf_threshold * range; 
						d += shape.sdf_bias * range;
						a = compute_sdf_alpha(d);
					} else if (shape.sdf_rect_size.x > 0.0 && shape.sdf_rect_size.y > 0.0) {
						float d = sd_rect(coords);
						d = shape.sdf_threshold - d;
						a = compute_sdf_alpha(d);
					}


					return a;
				}

				vec4 apply_swizzle(vec4 tex) {
					if (FLAGS_SWIZZLE == 1) return vec4(tex.rrr, 1.0);
					if (FLAGS_SWIZZLE == 2) return vec4(tex.ggg, 1.0);
					if (FLAGS_SWIZZLE == 3) return vec4(tex.bbb, 1.0);
					if (FLAGS_SWIZZLE == 4) return vec4(tex.aaa, 1.0);
					if (FLAGS_SWIZZLE == 5) return vec4(tex.rgb, 1.0);
					return tex;
				}

				vec4 sample_fragment_color(vec2 uv) {
					vec4 color = in_color * draw.global_color;

					if (draw.texture_index >= 0) {
						vec4 tex = texture(TEXTURE(draw.texture_index), uv);
						color *= apply_swizzle(tex);
					}

					return color;
				}
				
				void main() 
				{
					vec2 color_uv = get_uv_color(in_uv);
					out_color = sample_fragment_color(color_uv);
					
					vec2 sdf_uv = get_uv_sdf(in_uv);
					out_color.a *= get_sdf(sdf_uv);

					if (false && draw.sdf_texture_index != -1) {
						float range = shape.sdf_texel_range;
						float softness = 5;

						float d = read_raw_sdf(sdf_uv);
						d *= range;
						d -= shape.sdf_threshold * range; 
						d += shape.sdf_bias * range;
						d = smoothstep(-softness, softness, d);
						d = pow(max(d, 0.0), shape.sdf_gamma);
						
						out_color.rgb = vec3(d);
						out_color.a = 1;
					}
					if ((shape.blur.x > 0.0 || shape.blur.y > 0.0) && shape.sdf_rect_size.x <= 0.0) {
						//out_color.a *= compute_blur_alpha(in_uv);
					}

					if (out_color.a <= 0.0) discard;
				}
			]],
		},
		CullMode = "none",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
		DepthTest = false,
		DepthWrite = true,
		StencilTest = false,
		FrontStencilFailOp = "keep",
		FrontStencilPassOp = "keep",
		FrontStencilDepthFailOp = "keep",
		FrontStencilCompareOp = "always",
		BackStencilFailOp = "keep",
		BackStencilPassOp = "keep",
		BackStencilDepthFailOp = "keep",
		BackStencilCompareOp = "always",
	}
	render2d.pipeline = EasyPipeline.New(config)

	do
		local batch_instance_attributes = {
			{"pvw", "mat4"},
		}
		local batch_vertex_outputs = {
			{"uv", "vec2"},
			{"sample_uv", "vec2"},
			{"color", "vec4"},
		}
		local batch_fragment_adapters = {}

		for _, field in ipairs(rect_batch_fragment_passthrough_fields) do
			batch_instance_attributes[#batch_instance_attributes + 1] = {field.name, field.type, field.format}
			batch_vertex_outputs[#batch_vertex_outputs + 1] = {field.name, field.type}

			for _, field_value in ipairs(field.fragment_values) do
				batch_fragment_adapters[#batch_fragment_adapters + 1] = field_value
			end
		end

		render2d.rect_batch_pipeline = EasyPipeline.New{
			name = "render2d_rect_batch",
			dont_create_framebuffers = true,
			RasterizationSamples = render.target:GetSamples(),
			ColorFormat = render.target:GetColorFormat(),
			vertex = {
				bindings = {
					{
						binding = 0,
						input_rate = "vertex",
						attributes = config.vertex.attributes,
					},
					{
						binding = 1,
						input_rate = "instance",
						attributes = batch_instance_attributes,
					},
				},
				outputs = batch_vertex_outputs,
				passthrough = {
					position = "in_pvw * vec4(in_pos, 1.0)",
				},
			},
			fragment = {
				constants = config.fragment.constants,
				adapters = batch_fragment_adapters,
				shader = config.fragment.shader,
			},
			CullMode = config.CullMode,
			Blend = config.Blend,
			SrcColorBlendFactor = config.SrcColorBlendFactor,
			DstColorBlendFactor = config.DstColorBlendFactor,
			ColorBlendOp = config.ColorBlendOp,
			SrcAlphaBlendFactor = config.SrcAlphaBlendFactor,
			DstAlphaBlendFactor = config.DstAlphaBlendFactor,
			AlphaBlendOp = config.AlphaBlendOp,
			ColorWriteMask = config.ColorWriteMask,
			DepthTest = config.DepthTest,
			DepthWrite = config.DepthWrite,
			StencilTest = config.StencilTest,
			FrontStencilFailOp = config.FrontStencilFailOp,
			FrontStencilPassOp = config.FrontStencilPassOp,
			FrontStencilDepthFailOp = config.FrontStencilDepthFailOp,
			FrontStencilCompareOp = config.FrontStencilCompareOp,
			BackStencilFailOp = config.BackStencilFailOp,
			BackStencilPassOp = config.BackStencilPassOp,
			BackStencilDepthFailOp = config.BackStencilDepthFailOp,
			BackStencilCompareOp = config.BackStencilCompareOp,
		}
	end

	render2d.state.runtime.ids.current.rect_batch_pipeline = table.intern_key(render2d.state.runtime.ids.roots.pipeline, render2d.rect_batch_pipeline)

	render2d.pipeline:SetTextureSamplerConfigResolver(function()
		return render.GetSamplerFilterConfig()
	end)

	render2d.rect_batch_pipeline:SetTextureSamplerConfigResolver(function()
		return render.GetSamplerFilterConfig()
	end)

	render2d.ResetState()
	render2d.rect_mesh = render2d.CreateMesh(
		{
			{
				pos = Vec3(0, 1, 0),
				uv = Vec2(0, 0),
				sample_uv = Vec2(0, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(0, 0, 0),
				uv = Vec2(0, 1),
				sample_uv = Vec2(0, 1),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(1, 1, 0),
				uv = Vec2(1, 0),
				sample_uv = Vec2(1, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(1, 0, 0),
				uv = Vec2(1, 1),
				sample_uv = Vec2(1, 1),
				color = Color(1, 1, 1, 1),
			},
		},
		{0, 1, 2, 2, 1, 3}
	)
	ensure_rect_batch_instance_buffer = function(slot, capacity)
		render2d.rect_batch_instance_buffers = render2d.rect_batch_instance_buffers or {}
		local frame_index = render.GetCurrentFrame() or 1
		local frame_buffers = render2d.rect_batch_instance_buffers[frame_index]

		if not frame_buffers then
			frame_buffers = {}
			render2d.rect_batch_instance_buffers[frame_index] = frame_buffers
		end

		local current = frame_buffers[slot]

		if current and current:GetVertexCount() >= capacity then return current end

		if not render2d.rect_batch_instance_buffer_attributes then
			render2d.rect_batch_instance_buffer_attributes = {}

			for _, attribute in ipairs(render2d.rect_batch_pipeline.vertex_attributes) do
				if attribute.binding == 1 then
					render2d.rect_batch_instance_buffer_attributes[#render2d.rect_batch_instance_buffer_attributes + 1] = attribute
				end
			end
		end

		current = VertexBuffer.New(
			capacity,
			render2d.rect_batch_instance_buffer_attributes,
			string.format("render2d rect batch instance frame=%d slot=%d", frame_index, slot)
		)
		frame_buffers[slot] = current
		return current
	end
end

function render2d.ResetState()
	local constants = render2d.state.render.fragment.constants
	render2d.FlushBatches("reset_state")
	render2d.ClearPendingBatches()
	render2d.stencil_level = 0
	render2d.SetRectBatchMode("instanced")
	reset_rect_batch_instance_frame_state()
	render2d.SetTexture()
	render2d.SetSDFTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetUV()
	render2d.SetColorUVTransform()
	render2d.SetSwizzleMode(0)
	render2d.SetBlur(0)
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetOutlineWidth(0)
	render2d.SetUV2()
	constants.flags = 0
	render2d.SetClampBorderRadius(true)

	if true then
		constants.sdf_texel_range = 1
		constants.sdf_threshold = 0.48
		constants.sdf_bias = 0.0
		constants.sdf_gamma = 1.05
		constants.sdf_softness = 0.6
	else
		constants.sdf_texel_range = 1
		constants.sdf_threshold = 0.5
		constants.sdf_bias = 0
		constants.sdf_gamma = 0
		constants.sdf_softness = 0.5
	end

	constants.sdf_texture_index = -1
	constants.sdf_uv_bounds[0] = 0
	constants.sdf_uv_bounds[1] = 0
	constants.sdf_uv_bounds[2] = 1
	constants.sdf_uv_bounds[3] = 1
	constants.nine_patch_x_count = 0
	constants.nine_patch_y_count = 0

	for i = 0, 5 do
		constants.nine_patch_x_stretch[i] = 0
		constants.nine_patch_y_stretch[i] = 0
	end

	render2d.SetScreenSize(render.GetRenderImageSize():Unpack())
	render2d.SetScissor(0, 0, render2d.GetSize())
	render2d.SetBlendPreset("alpha")
	render2d.SetDepthMode(DEFAULT_DEPTH_MODE, false)
	render2d.SetStencilMode("none")
end

do
	do
		function render2d.SetColor(r, g, b, a)
			local constants = render2d.state.render.fragment.constants
			constants.global_color[0] = r
			constants.global_color[1] = g
			constants.global_color[2] = b

			if a then constants.global_color[3] = a end
		end

		function render2d.GetColor()
			local constants = render2d.state.render.fragment.constants
			return constants.global_color[0],
			constants.global_color[1],
			constants.global_color[2],
			constants.global_color[3]
		end

		utility.MakePushPopFunction(render2d, "Color", 4)
	end

	do
		do -- Flag definitions: single source of truth for all flag fields
			-- Each entry: { name, mask, shift }
			local FLAGS = {
				{name = "SWIZZLE", mask = 0xF, shift = 0},
				{name = "SAMPLE_UV", mask = 0xF, shift = 4},
				{name = "CLAMP_BORDER_RADIUS", mask = 0x1, shift = 8},
				{name = "MSDF", mask = 0x1, shift = 9},
			}

			-- Build getter/setter for each flag from the FLAGS table
			for _, flag_def in ipairs(FLAGS) do
				local name = flag_def.name
				local mask = flag_def.mask
				local shift = flag_def.shift

				local function make_setter(f)
					return function(value)
						local constants = render2d.state.render.fragment.constants
						local shifted_mask = bit.lshift(f.mask, f.shift)
						local other = bit.band(constants.flags, bit.bnot(shifted_mask))
						constants.flags = bit.bor(other, bit.lshift(bit.band(value, f.mask), f.shift))
					end
				end

				local function make_getter(f)
					return function()
						return bit.rshift(
							bit.band(render2d.state.render.fragment.constants.flags, bit.lshift(f.mask, f.shift)),
							f.shift
						)
					end
				end

				render2d["Set" .. name] = make_setter(flag_def)
				render2d["Get" .. name] = make_getter(flag_def)
			end

			-- Generate GLSL #define block for shaders
			function render2d.BuildShaderFlags(var_name)
				local lines = {}

				for _, flag_def in ipairs(FLAGS) do
					local mask = flag_def.mask
					local shift = flag_def.shift
					local define_name = "FLAGS_" .. flag_def.name
					local shifted_mask = bit.lshift(mask, shift)

					if shift == 0 then
						lines[#lines + 1] = "#define " .. define_name .. " (" .. var_name .. " & " .. mask .. ")"
					else
						lines[#lines + 1] = "#define " .. define_name .. " ((" .. var_name .. " & " .. shifted_mask .. ") >> " .. shift .. ")"
					end
				end

				return table.concat(lines, "\n")
			end
		end

		do
			-- Convenience wrappers for the public API
			function render2d.SetSwizzleMode(mode)
				if mode then
					render2d.SetSWIZZLE(mode)
					render2d.state.render.options.computed_margin_dirty = true
				end
			end

			function render2d.GetSwizzleMode()
				return render2d.GetSWIZZLE()
			end

			utility.MakePushPopFunction(render2d, "SwizzleMode", 1)
		end

		do
			function render2d.SetSampleUVMode(mode)
				render2d.SetSAMPLE_UV(mode or 0)
			end

			function render2d.GetSampleUVMode()
				return render2d.GetSAMPLE_UV()
			end

			utility.MakePushPopFunction(render2d, "SampleUVMode", 1)
		end

		do
			function render2d.SetSDFTexture(tex)
				render2d.state.render.textures.sdf_texture = tex

				if tex then
					render2d.GetActivePipeline():GetTextureIndex(tex, 1, render.GetSamplerFilterConfig())
				end

				render2d.state.render.options.computed_margin_dirty = true
			end

			function render2d.GetSDFTexture()
				return render2d.state.render.textures.sdf_texture
			end

			utility.MakePushPopFunction(render2d, "SDFTexture", 1)

			function render2d.SetSDFTexelRange(texel_range)
				render2d.state.render.fragment.constants.sdf_texel_range = texel_range
			end

			function render2d.GetSDFTexelRange()
				return render2d.state.render.fragment.constants.sdf_texel_range
			end

			utility.MakePushPopFunction(render2d, "SDFTexelRange", 1)
		end

		do
			function render2d.SetSDFThreshold(threshold)
				render2d.state.render.fragment.constants.sdf_threshold = threshold
			end

			function render2d.GetSDFThreshold()
				return render2d.state.render.fragment.constants.sdf_threshold
			end

			utility.MakePushPopFunction(render2d, "SDFThreshold", 1)

			function render2d.SetSDFBias(bias)
				render2d.state.render.fragment.constants.sdf_bias = bias
			end

			function render2d.GetSDFBias()
				return render2d.state.render.fragment.constants.sdf_bias
			end

			utility.MakePushPopFunction(render2d, "SDFBias", 1)

			function render2d.SetSDFGamma(gamma)
				render2d.state.render.fragment.constants.sdf_gamma = gamma
			end

			function render2d.GetSDFGamma()
				return render2d.state.render.fragment.constants.sdf_gamma
			end

			utility.MakePushPopFunction(render2d, "SDFGamma", 1)

			function render2d.SetSDFSoftness(softness)
				render2d.state.render.fragment.constants.sdf_softness = softness
				render2d.state.render.options.computed_margin_dirty = true
			end

			function render2d.GetSDFSoftness()
				return render2d.state.render.fragment.constants.sdf_softness
			end

			utility.MakePushPopFunction(render2d, "SDFSoftness", 1)
		end

		do
			function render2d.SetClampBorderRadius(enabled)
				local normalized = enabled == true
				render2d.state.render.options.clamp_border_radius = normalized
				render2d.SetCLAMP_BORDER_RADIUS(normalized and 1 or 0)
			end

			function render2d.GetClampBorderRadius()
				return render2d.state.render.options.clamp_border_radius
			end

			utility.MakePushPopFunction(render2d, "ClampBorderRadius", 1)
		end

		do
			function render2d.SetMSDFEnabled(enabled)
				render2d.state.render.options.msdf = enabled
				render2d.SetMSDF(enabled and 1 or 0)
			end

			function render2d.GetMSDFEnabled()
				return render2d.state.render.options.msdf
			end

			utility.MakePushPopFunction(render2d, "MSDFEnabled", 1)
		end

		do
			function render2d.SetBlur(x, y)
				local constants = render2d.state.render.fragment.constants
				constants.blur[0] = x or 0
				constants.blur[1] = y or x or 0
				render2d.state.render.options.computed_margin_dirty = true
			end

			function render2d.GetBlur()
				local constants = render2d.state.render.fragment.constants
				return constants.blur[0], constants.blur[1]
			end

			utility.MakePushPopFunction(render2d, "Blur", 2)
		end
	end

	do
		function render2d.SetBorderRadius(tl, tr, br, bl)
			if type(tl) == "table" then
				tr = tl[2]
				br = tl[3]
				bl = tl[4]
				tl = tl[1]
			end

			local constants = render2d.state.render.fragment.constants
			constants.border_radius[0] = tl or 0
			constants.border_radius[1] = tr or tl or 0
			constants.border_radius[2] = br or tl or 0
			constants.border_radius[3] = bl or tl or 0
		end

		function render2d.GetBorderRadius()
			local constants = render2d.state.render.fragment.constants
			return constants.border_radius[0],
			constants.border_radius[1],
			constants.border_radius[2],
			constants.border_radius[3]
		end

		utility.MakePushPopFunction(render2d, "BorderRadius", 4)
	end

	do
		function render2d.SetOutlineWidth(width)
			render2d.state.render.fragment.constants.outline_width = width or 0
			render2d.state.render.options.computed_margin_dirty = true
		end

		function render2d.GetOutlineWidth()
			return render2d.state.render.fragment.constants.outline_width
		end

		utility.MakePushPopFunction(render2d, "OutlineWidth", 1)
	end

	do
		function render2d.ClearNinePatch()
			local constants = render2d.state.render.fragment.constants
			constants.nine_patch_x_count = 0
			constants.nine_patch_y_count = 0

			for i = 0, 5 do
				constants.nine_patch_x_stretch[i] = 0
				constants.nine_patch_y_stretch[i] = 0
			end
		end

		function render2d.SetNinePatchTable(tbl)
			render2d.ClearNinePatch()

			if tbl.x_stretch then
				local count = math.max(#tbl.x_stretch, #tbl.y_stretch)
				count = math.min(count, 3)

				for i = 1, count do
					local x = tbl.x_stretch[i] or {0, 0}
					local y = tbl.y_stretch[i] or {0, 0}
					render2d.SetNinePatch(x[1], x[2], y[1], y[2], i - 1)
				end
			elseif tbl.stretch or tbl[1] then
				local s = tbl.stretch or tbl
				render2d.SetNinePatch(s[1] or 0, s[2] or 0, s[3] or 0, s[4] or 0, 0)
			end
		end

		function render2d.SetNinePatch(x1, y1, x2, y2, index)
			if type(x1) == "table" then
				render2d.SetNinePatchTable(x1.nine_patch or x1)
				return
			end

			if not x1 or not y1 or not x2 or not y2 then
				render2d.ClearNinePatch()
				return
			end

			index = index or 0
			local constants = render2d.state.render.fragment.constants
			constants.nine_patch_x_stretch[index * 2] = x1
			constants.nine_patch_x_stretch[index * 2 + 1] = y1
			constants.nine_patch_x_count = math.max(constants.nine_patch_x_count, index + 1)
			constants.nine_patch_y_stretch[index * 2] = x2
			constants.nine_patch_y_stretch[index * 2 + 1] = y2
			constants.nine_patch_y_count = math.max(constants.nine_patch_y_count, index + 1)
		end

		function render2d.GetNinePatch()
			local constants = render2d.state.render.fragment.constants
			return constants.nine_patch_x_stretch[0],
			constants.nine_patch_x_stretch[1],
			constants.nine_patch_y_stretch[0],
			constants.nine_patch_y_stretch[1]
		end
	end

	do
		function render2d.SetAlphaMultiplier(a)
			render2d.state.render.fragment.alpha_multiplier = a
		end

		function render2d.GetAlphaMultiplier()
			return render2d.state.render.fragment.alpha_multiplier
		end

		utility.MakePushPopFunction(render2d, "AlphaMultiplier", 1)
	end

	do
		function render2d.SetTexture(tex)
			render2d.state.render.textures.texture = tex
			-- Register texture with the pipeline BEFORE sync_pipeline_state is called.
			-- This ensures the descriptor set includes the texture when it's bound.
			local pipeline = render2d.GetActivePipeline()

			if pipeline and tex then
				pipeline:GetTextureIndex(tex, 1, render.GetSamplerFilterConfig())
			end
		end

		function render2d.GetTexture()
			return render2d.state.render.textures.texture
		end

		utility.MakePushPopFunction(render2d, "Texture", 1)
	end

	function render2d.SetBlendMode(mode_name, force, ...)
		local next_state

		if type(mode_name) == "table" then
			next_state = canonicalize_blend_mode_state(mode_name)
		else
			if select("#", ...) == 0 then
				error(
					"SetBlendMode expects a canonical blend state table or explicit blend factors; use SetBlendPreset for presets",
					2
				)
			end

			local dst_rgb, color_op, src_alpha, dst_alpha, alpha_op = force, ...
			next_state = canonicalize_blend_mode_state{
				blend = true,
				src_color_blend_factor = mode_name,
				dst_color_blend_factor = dst_rgb,
				color_blend_op = color_op,
				src_alpha_blend_factor = src_alpha or mode_name,
				dst_alpha_blend_factor = dst_alpha or dst_rgb,
				alpha_blend_op = alpha_op or color_op,
			}
		end

		render2d.state.render.pipeline.blend = next_state
		render2d.MarkPipelineStateDirty()
	end

	function render2d.SetBlendPreset(mode_name)
		local next_state = get_blend_preset_state(mode_name)
		render2d.state.render.pipeline.blend = next_state
		render2d.MarkPipelineStateDirty()
	end

	function render2d.GetBlendMode()
		return canonicalize_blend_mode_state(render2d.state.render.pipeline.blend)
	end

	do
		local stack = {}
		local i = 1

		function render2d.PushBlendMode(...)
			stack[i] = render2d.GetBlendMode()
			render2d.SetBlendMode(...)
			i = i + 1
		end

		function render2d.PushBlendPreset(mode_name)
			stack[i] = render2d.GetBlendMode()
			render2d.SetBlendPreset(mode_name)
			i = i + 1
		end

		function render2d.PopBlendMode()
			i = i - 1

			if i < 1 then error("stack underflow", 2) end

			render2d.SetBlendMode(stack[i])
		end
	end

	render2d.stencil_modes = {
		none = {
			stencil_test = false,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		write = { -- Simply write the reference value everywhere
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "replace",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {},
		},
		mask_write = { -- Increment level if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "increment_and_clamp",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {},
		},
		mask_test = { -- Pass if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		mask_decrement = { -- Decrement level if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "decrement_and_clamp",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {},
		},
		test = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		greater = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "greater",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		test_inverse = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "not_equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
	}

	do
		function render2d.SetDepthMode(mode_name, write)
			mode_name = mode_name or DEFAULT_DEPTH_MODE
			write = not not write

			if mode_name ~= DEFAULT_DEPTH_MODE and not depth_mode_to_compare_op[mode_name] then
				error("Invalid depth mode: " .. tostring(mode_name))
			end

			render2d.state.render.pipeline.depth.mode = mode_name
			render2d.state.render.pipeline.depth.write = write
			render2d.state.render.fragment.constants.depth_mode_id = depth_mode_ids[mode_name]
			render2d.state.render.fragment.constants.depth_write = write and 1 or 0
			render2d.MarkPipelineStateDirty()
		end

		function render2d.GetDepthMode()
			local state = render2d.state.render.pipeline.depth
			return state.mode, state.write
		end
	end

	do
		render2d.stencil_level = 0
		render2d._stencil_mask_stack = {}

		function render2d.SetStencilMode(mode_name, ref)
			if ref == nil then ref = render2d.state.render.pipeline.stencil.ref end

			-- Workaround: "greater" with reference 0 doesn't work correctly on some systems.
			-- Since ref=0 and unsigned stencil values, "greater" is equivalent to "not_equal".
			-- Map to test_inverse for reliability.
			if ref == 0 and mode_name == "greater" then mode_name = "test_inverse" end

			local mode = render2d.stencil_modes[mode_name]

			if not mode then error("Invalid stencil mode: " .. tostring(mode_name)) end

			render2d.state.render.pipeline.stencil.mode = mode_name
			render2d.state.render.pipeline.stencil.ref = ref
			render2d.state.render.fragment.constants.stencil_mode_id = stencil_mode_ids[mode_name]
			render2d.state.render.fragment.constants.stencil_ref = ref
			render2d.MarkPipelineStateDirty()
		end

		function render2d.GetStencilMode()
			local state = render2d.state.render.pipeline.stencil
			return state.mode, state.ref
		end

		function render2d.GetStencilReference()
			return render2d.state.render.pipeline.stencil.ref
		end

		function render2d.ClearStencil(val)
			if not render.GetCommandBuffer() then return end

			render2d.FlushBatches("clear_stencil")
			local old_mode, old_ref = render2d.GetStencilMode()
			local old_rect_batch_mode = render2d.GetRectBatchMode()
			local old_batched_rect_draws_enabled = render2d.state.render.options.batched_rect_draws_enabled
			render2d.state.render.options.batched_rect_draws_enabled = false
			render2d.SetRectBatchMode("immediate")
			render2d.stencil_level = 0
			render2d.SetStencilMode("write", val or 0)
			local sw, sh = render2d.GetSize()
			render2d.PushMatrix()
			render2d.SetWorldMatrix(Matrix44())
			render2d.DrawRect(0, 0, sw, sh)
			render2d.PopMatrix()
			render2d.SetRectBatchMode(old_rect_batch_mode)
			render2d.state.render.options.batched_rect_draws_enabled = old_batched_rect_draws_enabled
			render2d.SetStencilMode(old_mode, old_ref)
		end

		function render2d.PushStencilMask()
			local old_mode, old_ref = render2d.GetStencilMode()
			table.insert(render2d._stencil_mask_stack, {mode = old_mode, ref = old_ref})
			render2d.SetStencilMode("mask_write", render2d.stencil_level)
			render2d.stencil_level = render2d.stencil_level + 1
		end

		function render2d.BeginStencilTest()
			render2d.SetStencilMode("mask_test", render2d.stencil_level)
		end

		function render2d.PopStencilMask()
			render2d.stencil_level = render2d.stencil_level - 1
			local saved = table.remove(render2d._stencil_mask_stack)

			if saved then render2d.SetStencilMode(saved.mode, saved.ref) end
		end

		utility.MakePushPopFunction(render2d, "StencilMode", 1)
	end

	function render2d.SetBlendConstants(r, g, b, a)
		render2d.FlushBatches("set_blend_constants")
		render.GetCommandBuffer():SetBlendConstants(r, g, b, a)
	end

	apply_scissor_to_command_buffer = function(x, y, w, h)
		local cmd = render.GetCommandBuffer()

		if not cmd then return end

		local cmd_x, cmd_y, cmd_w, cmd_h = x, y, w, h

		if cmd_w == 0 or cmd_h == 0 then
			local screen_w, screen_h = render2d.GetSize()
			cmd_x = math.max(screen_w or 0, 0)
			cmd_y = math.max(screen_h or 0, 0)
			cmd_w = 1
			cmd_h = 1
		end

		cmd:SetScissor(cmd_x, cmd_y, cmd_w, cmd_h)
	end

	function render2d.SetScissor(x, y, w, h)
		x = x or 0
		y = y or 0
		w = w or 0
		h = h or 0

		if x < 0 then
			w = w + x
			x = 0
		end

		if y < 0 then
			h = h + y
			y = 0
		end

		w = math.max(w, 0)
		h = math.max(h, 0)
		render2d.state.render.pipeline.scissor.x = x
		render2d.state.render.pipeline.scissor.y = y
		render2d.state.render.pipeline.scissor.w = w
		render2d.state.render.pipeline.scissor.h = h
		render2d.state.render.fragment.constants.scissor[0] = x
		render2d.state.render.fragment.constants.scissor[1] = y
		render2d.state.render.fragment.constants.scissor[2] = w
		render2d.state.render.fragment.constants.scissor[3] = h
		apply_scissor_to_command_buffer(x, y, w, h)
	end

	do
		local stack = {}
		local clip_stack = {}
		local clip_axis_alignment_epsilon = 0.001
		local clip_projection_matrix = Matrix44()
		local use_scissor_clip_rect_fast_path = jit.os ~= "OSX"

		local function clip_point_to_screen(clip_matrix, screen_w, screen_h, px, py)
			local clip_x, clip_y = clip_matrix:TransformVectorUnpacked(px, py, 0)
			return (clip_x * 0.5 + 0.5) * screen_w, (clip_y * 0.5 + 0.5) * screen_h
		end

		local function project_clip_rect_to_screen(world_matrix, x, y, w, h)
			local screen_w, screen_h = render2d.GetSize()
			world_matrix:GetMultiplied(render2d.GetProjectionViewMatrix(), clip_projection_matrix)
			local tl_x, tl_y = clip_point_to_screen(clip_projection_matrix, screen_w, screen_h, x, y)
			local tr_x, tr_y = clip_point_to_screen(clip_projection_matrix, screen_w, screen_h, x + w, y)
			local br_x, br_y = clip_point_to_screen(clip_projection_matrix, screen_w, screen_h, x + w, y + h)
			local bl_x, bl_y = clip_point_to_screen(clip_projection_matrix, screen_w, screen_h, x, y + h)
			local axis_aligned = math.abs(tl_y - tr_y) <= clip_axis_alignment_epsilon and
				math.abs(bl_y - br_y) <= clip_axis_alignment_epsilon and
				math.abs(tl_x - bl_x) <= clip_axis_alignment_epsilon and
				math.abs(tr_x - br_x) <= clip_axis_alignment_epsilon
			local min_x = math.min(tl_x, tr_x, br_x, bl_x)
			local max_x = math.max(tl_x, tr_x, br_x, bl_x)
			local min_y = math.min(tl_y, tr_y, br_y, bl_y)
			local max_y = math.max(tl_y, tr_y, br_y, bl_y)
			return axis_aligned,
			math.floor(min_x),
			math.floor(min_y),
			math.ceil(max_x - min_x),
			math.ceil(max_y - min_y)
		end

		local function begin_clip_mask_draw(entry)
			local saved_state = capture_rect_draw_state()
			render2d.SetWorldMatrix(entry.world_matrix)
			render2d.SetTexture()
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetAlphaMultiplier(1)
			render2d.SetUV()
			render2d.SetSampleUVMode(0)
			render2d.SetSwizzleMode(0)
			render2d.SetSDFTexture()
			render2d.SetBlur(0)
			render2d.SetBorderRadius(0, 0, 0, 0)
			render2d.SetOutlineWidth(0)
			render2d.ClearNinePatch()
			return saved_state
		end

		local function draw_clip_mask(entry)
			local saved_state = begin_clip_mask_draw(entry)

			if entry.kind == "stencil_rect" then
				render2d.DrawRect(entry.x, entry.y, entry.w, entry.h)
			elseif entry.kind == "stencil_rounded_rect" then
				render2d.PushBorderRadius(entry.tl, entry.tr, entry.br, entry.bl)
				render2d.DrawRect(entry.x, entry.y, entry.w, entry.h)
				render2d.PopBorderRadius()
			elseif entry.kind == "stencil_shape" then
				entry.draw_callback()
			else
				restore_rect_draw_state(saved_state)
				error("unknown clip kind: " .. tostring(entry.kind), 2)
			end

			restore_rect_draw_state(saved_state)
		end

		local function push_stencil_clip(entry)
			render2d.PushStencilMask()
			draw_clip_mask(entry)
			render2d.BeginStencilTest()
			table.insert(clip_stack, entry)
		end

		function render2d.PushScissor(x, y, w, h)
			local current = stack[#stack]

			if current then
				local x2 = math.max(x, current.x)
				local y2 = math.max(y, current.y)
				local w2 = math.min(x + w, current.x + current.w) - x2
				local h2 = math.min(y + h, current.y + current.h) - y2
				x, y, w, h = x2, y2, math.max(0, w2), math.max(0, h2)
			end

			local data = {x = x, y = y, w = w, h = h}
			table.insert(stack, data)
			render2d.SetScissor(x, y, w, h)
		end

		function render2d.PopScissor()
			table.remove(stack)
			local current = stack[#stack]

			if current then
				render2d.SetScissor(current.x, current.y, current.w, current.h)
			else
				local sw, sh = render2d.GetSize()
				render2d.SetScissor(0, 0, sw or 0, sh or 0)
			end
		end

		function render2d.PushClipRect(x, y, w, h)
			local axis_aligned, scissor_x, scissor_y, scissor_w, scissor_h = project_clip_rect_to_screen(render2d.GetWorldMatrix(), x, y, w, h)

			if use_scissor_clip_rect_fast_path and axis_aligned then
				render2d.PushScissor(scissor_x, scissor_y, scissor_w, scissor_h)
				table.insert(clip_stack, {kind = "scissor"})
				return
			end

			push_stencil_clip{
				kind = "stencil_rect",
				world_matrix = render2d.GetWorldMatrix():Copy(),
				x = x,
				y = y,
				w = w,
				h = h,
			}
		end

		function render2d.PushClipRoundedRect(x, y, w, h, tl, tr, br, bl)
			if type(tl) == "table" then
				tr = tl[2]
				br = tl[3]
				bl = tl[4]
				tl = tl[1]
			end

			push_stencil_clip{
				kind = "stencil_rounded_rect",
				world_matrix = render2d.GetWorldMatrix():Copy(),
				x = x,
				y = y,
				w = w,
				h = h,
				tl = tl or 0,
				tr = tr or tl or 0,
				br = br or tl or 0,
				bl = bl or tl or 0,
			}
		end

		function render2d.PushClipShape(draw_callback)
			if type(draw_callback) ~= "function" then
				error("PushClipShape expects a draw callback", 2)
			end

			push_stencil_clip{
				kind = "stencil_shape",
				world_matrix = render2d.GetWorldMatrix():Copy(),
				draw_callback = draw_callback,
			}
		end

		function render2d.PopClip()
			local entry = table.remove(clip_stack)

			if not entry then error("Clip stack underflow", 2) end

			if entry.kind == "scissor" then
				render2d.PopScissor()
				return
			end

			render2d.SetStencilMode("mask_decrement", render2d.stencil_level)
			draw_clip_mask(entry)
			render2d.PopStencilMask()
		end
	end

	function render2d.UploadConstants(w, h, lw, lh)
		render2d.state.render.fragment.rect_size.w = w or 0
		render2d.state.render.fragment.rect_size.h = h or 0
		render2d.state.render.fragment.rect_size.lw = lw or w or 0
		render2d.state.render.fragment.rect_size.lh = lh or h or 0
		local pipeline = render2d.GetActivePipeline()

		if pipeline then pipeline:UploadConstants() end
	end
end

do -- mesh
	function render2d.CreateMesh(vertices, indices)
		return Mesh.New(render2d.pipeline:GetVertexAttributes(), vertices, indices, nil, nil, "render2d mesh")
	end

	local function ensure_draw_command_immediate()
		local cmd = render.GetCommandBuffer()
		sync_pipeline_state()
		return cmd
	end

	bind_mesh_immediate = function(mesh)
		local cmd = ensure_draw_command_immediate()

		if not cmd then return false end

		if
			render2d.state.runtime.mesh.last_cmd ~= cmd or
			render2d.state.runtime.mesh.last_bound ~= mesh
		then
			mesh:Bind(cmd, 0)
			render2d.state.runtime.mesh.last_bound = mesh
			render2d.state.runtime.mesh.last_cmd = cmd
		end

		return true
	end

	function render2d.BindMesh(mesh)
		render2d.FlushBatches("bind_mesh")
		return bind_mesh_immediate(mesh)
	end

	function render2d.DrawIndexedMesh(index_count, instance_count, first_index, vertex_offset, first_instance)
		render2d.FlushBatches("draw_indexed_mesh")
		local cmd = ensure_draw_command_immediate()

		if not cmd then return end

		cmd:DrawIndexed(
			index_count or index_buffer:GetIndexCount(),
			instance_count or 1,
			first_index or 0,
			vertex_offset or 0,
			first_instance or 0
		)
	end

	function render2d.DrawMesh(vertex_count, instance_count, first_vertex, first_instance)
		render2d.FlushBatches("draw_mesh")
		local cmd = ensure_draw_command_immediate()

		if not cmd then return end

		cmd:Draw(
			vertex_count or vertex_buffer:GetVertexCount(),
			instance_count or 1,
			first_vertex or 0,
			first_instance or 0
		)
	end
end

do -- uv
	do
		function render2d.SetUV(x, y, w, h, sx, sy)
			local constants = render2d.state.render.fragment.constants

			if not x then
				-- Reset to default (no transformation)
				constants.uv_offset[0] = 0
				constants.uv_offset[1] = 0
				constants.uv_scale[0] = 1
				constants.uv_scale[1] = 1
			else
				sx = sx or 1
				sy = sy or 1
				local y_transformed = -y - h
				-- Set UV offset and scale
				constants.uv_offset[0] = x / sx
				constants.uv_offset[1] = y_transformed / sy
				constants.uv_scale[0] = w / sx
				constants.uv_scale[1] = h / sy
			end

			render2d.state.render.fragment.uv.x = x
			render2d.state.render.fragment.uv.y = y
			render2d.state.render.fragment.uv.w = w
			render2d.state.render.fragment.uv.h = h
			render2d.state.render.fragment.uv.sx = sx
			render2d.state.render.fragment.uv.sy = sy
		end

		function render2d.GetUV()
			local uv = render2d.state.render.fragment.uv
			return uv.x, uv.y, uv.w, uv.h, uv.sx, uv.sy
		end

		utility.MakePushPopFunction(render2d, "UV", 6)
	end

	function render2d.GetUVTransform()
		local constants = render2d.state.render.fragment.constants
		return constants.uv_offset[0],
		constants.uv_offset[1],
		constants.uv_scale[0],
		constants.uv_scale[1]
	end

	do
		function render2d.SetSampleUVMode(mode)
			render2d.SetSAMPLE_UV(mode or 0)
		end

		function render2d.GetSampleUVMode()
			return render2d.GetSAMPLE_UV()
		end

		utility.MakePushPopFunction(render2d, "SampleUVMode", 1)
	end

	function render2d.SetUV2(u1, v1, u2, v2)
		u1 = u1 or 0
		v1 = v1 or 0
		u2 = u2 or 1
		v2 = v2 or 1
		-- Calculate offset and scale from UV coordinates
		local constants = render2d.state.render.fragment.constants
		constants.uv_offset[0] = u1
		constants.uv_offset[1] = v1
		constants.uv_scale[0] = u2 - u1
		constants.uv_scale[1] = v2 - v1
		render2d.state.render.fragment.uv2.u1 = u1
		render2d.state.render.fragment.uv2.v1 = v1
		render2d.state.render.fragment.uv2.u2 = u2
		render2d.state.render.fragment.uv2.v2 = v2
	end

	function render2d.GetUV2()
		local uv2 = render2d.state.render.fragment.uv2
		return uv2.u1, uv2.v1, uv2.u2, uv2.v2
	end

	utility.MakePushPopFunction(render2d, "UV2", 4)

	do
		function render2d.SetColorUVTransform(ox, oy, sx, sy, angle)
			local color_uv = render2d.state.render.fragment.color_uv
			local constants = render2d.state.render.fragment.constants
			color_uv.offset_x = ox or 0
			color_uv.offset_y = oy or 0
			color_uv.scale_x = sx or 1
			color_uv.scale_y = sy or sx or 1
			color_uv.rotation = angle or 0
			constants.color_uv_offset[0] = color_uv.offset_x
			constants.color_uv_offset[1] = color_uv.offset_y
			constants.color_uv_scale[0] = color_uv.scale_x
			constants.color_uv_scale[1] = color_uv.scale_y
			constants.color_uv_rotation = color_uv.rotation
		end

		function render2d.GetColorUVTransform()
			local color_uv = render2d.state.render.fragment.color_uv
			return color_uv.offset_x,
			color_uv.offset_y,
			color_uv.scale_x,
			color_uv.scale_y,
			color_uv.rotation
		end

		utility.MakePushPopFunction(render2d, "ColorUVTransform", 5)

		function render2d.SetColorUV(x, y, w, h, sx, sy)
			sx = sx or 1
			sy = sy or 1
			local color_uv = render2d.state.render.fragment.color_uv
			local constants = render2d.state.render.fragment.constants
			color_uv.offset_x = x / sx
			color_uv.offset_y = y / sy
			color_uv.scale_x = w / sx
			color_uv.scale_y = h / sy
			color_uv.rotation = 0
			constants.color_uv_offset[0] = color_uv.offset_x
			constants.color_uv_offset[1] = color_uv.offset_y
			constants.color_uv_scale[0] = color_uv.scale_x
			constants.color_uv_scale[1] = color_uv.scale_y
			constants.color_uv_rotation = 0
		end

		function render2d.GetColorUV()
			local color_uv = render2d.state.render.fragment.color_uv
			return color_uv.offset_x, color_uv.offset_y, color_uv.scale_x, color_uv.scale_y
		end

		utility.MakePushPopFunction(render2d, "ColorUV", 4)
	end
end

do -- camera
	local camera_state = render2d.state.runtime.camera

	local function update_proj_view()
		camera_state.projection_view = camera_state.view * camera_state.projection
	end

	local function update_projection()
		camera_state.projection:Identity()
		camera_state.projection:Ortho(
			camera_state.viewport.x,
			camera_state.viewport.w,
			camera_state.viewport.y,
			camera_state.viewport.h,
			-16000,
			16000
		)
		update_proj_view()
	end

	local function update_view()
		camera_state.view:Identity()
		local x, y = camera_state.viewport.w / 2, camera_state.viewport.h / 2
		camera_state.view:Translate(x, y, 0)
		camera_state.view:Rotate(camera_state.view_angle, 0, 0, 1)
		camera_state.view:Translate(-x, -y, 0)
		camera_state.view:Translate(camera_state.view_pos.x, camera_state.view_pos.y, 0)
		camera_state.view:Translate(x, y, 0)
		camera_state.view:Scale(camera_state.view_zoom.x, camera_state.view_zoom.y, 1)
		camera_state.view:Translate(-x, -y, 0)
		update_proj_view()
	end

	do
		function render2d.SetScreenSize(w, h)
			camera_state.viewport.w = w
			camera_state.viewport.h = h
			update_projection()
			update_view()
		end

		function render2d.GetScreenSize()
			return camera_state.viewport.w, camera_state.viewport.h
		end

		utility.MakePushPopFunction(render2d, "ScreenSize", 2)
	end

	function render2d.LoadIdentity()
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Identity()
	end

	function render2d.GetMatrix()
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:GetMultiplied(camera_state.projection_view, camera_state.projection_view_world)
		return camera_state.projection_view_world
	end

	function render2d.GetProjectionViewMatrix()
		return camera_state.projection_view
	end

	function render2d.PushWorldMatrix(dont_multiply)
		camera_state.world_matrix_stack_pos = camera_state.world_matrix_stack_pos + 1
		local mat = camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]

		if not mat then
			mat = Matrix44()
			camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos] = mat
		end

		if dont_multiply then
			mat:Identity()
		else
			Matrix44.CopyTo(camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos - 1], mat)
		end
	end

	function render2d.PopWorldMatrix()
		if camera_state.world_matrix_stack_pos > 1 then
			camera_state.world_matrix_stack_pos = camera_state.world_matrix_stack_pos - 1
		else
			error("Matrix stack underflow")
		end
	end

	function render2d.SetWorldMatrix(mat)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos] = mat:Copy()
	end

	function render2d.GetWorldMatrix()
		return camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]
	end

	function render2d.GetSize()
		return camera_state.viewport.w, camera_state.viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Translate(ceil(x), ceil(y or x), z or 0)
		end

		function render2d.Scale(w, h, z)
			camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Scale(ceil(w), ceil(h or w), z or 1)
		end
	end

	function render2d.Translatef(x, y, z)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Translate(x, y or x, z or 0)
	end

	function render2d.Rotate(a)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Rotate(a, 0, 0, 1)
	end

	function render2d.Scalef(w, h, z)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Scale(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Shear(x, y, 0)
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		render2d.PushWorldMatrix(dont_multiply)

		if x and y then render2d.Translate(x, y) end

		if a and h then
			render2d.Translate(w / 2, h / 2)
			render2d.Rotate(a)
			render2d.Translate(-w / 2, -h / 2)
		end

		if w then render2d.Scale(w, h) end
	end

	function render2d.PushMatrixf(x, y, w, h, a, dont_multiply)
		render2d.PushWorldMatrix(dont_multiply)

		if x and y then render2d.Translatef(x, y) end

		if a and h then
			render2d.Translatef(w / 2, h / 2)
			render2d.Rotate(a)
			render2d.Translatef(-w / 2, -h / 2)
		end

		if w then render2d.Scalef(w, h) end
	end

	render2d.PopMatrix = render2d.PopWorldMatrix
	render2d.PopMatrixf = render2d.PopWorldMatrix
end

local function can_batch_rect_draw()
	local batch_state = render2d.state.runtime.batch.state
	return render2d.state.render.options.batched_rect_draws_enabled and
		not batch_state.is_flushing and
		render.GetCommandBuffer() ~= nil and
		render2d.GetRectBatchMode() ~= "immediate" and
		not render2d.shader_override
end

capture_rect_draw_state = function(world_matrix, u1, v1, u2, v2)
	local batch_runtime = render2d.state.runtime.batch
	local slot = batch_runtime.next_rect_draw_state_snapshot_slot
	batch_runtime.next_rect_draw_state_snapshot_slot = slot + 1
	local rect_state_snapshot = get_rect_draw_state_snapshot(slot)
	ffi.copy(
		rect_state_snapshot,
		render2d.state.render.fragment.constants,
		render2d.state.render.fragment.constants_size
	)
	local resolved_world_matrix = world_matrix or Matrix44()
	local blend_mode = render2d.state.render.pipeline.blend

	if not blend_mode then
		blend_mode = get_blend_preset_state(DEFAULT_BLEND_MODE)
		render2d.state.render.pipeline.blend = blend_mode
	end

	if u1 ~= nil then
		rect_state_snapshot.uv_offset[0] = u1
		rect_state_snapshot.uv_offset[1] = v1
		rect_state_snapshot.uv_scale[0] = u2 - u1
		rect_state_snapshot.uv_scale[1] = v2 - v1
	end

	Matrix44.CopyTo(render2d.GetWorldMatrix(), resolved_world_matrix)
	return {
		rect_state_snapshot = rect_state_snapshot,
		world_matrix = resolved_world_matrix,
		texture = render2d.state.render.textures.texture,
		sdf_texture = render2d.state.render.textures.sdf_texture,
		blend_mode = blend_mode,
		pipeline_state_id = render2d.state.runtime.ids.current.rect_batch_pipeline,
		alpha_multiplier = render2d.state.render.fragment.alpha_multiplier,
	}
end
restore_rect_draw_state = function(state)
	ffi.copy(
		render2d.state.render.fragment.constants,
		state.rect_state_snapshot,
		render2d.state.render.fragment.constants_size
	)
	render2d.state.render.fragment.alpha_multiplier = state.alpha_multiplier
	render2d.state.render.textures.texture = state.texture
	render2d.state.render.textures.sdf_texture = state.sdf_texture
	-- Register textures with the pipeline BEFORE bind_mesh_immediate/sync_pipeline_state
	-- is called, so the descriptor set is updated with the correct textures.
	-- If we wait until UploadConstants (which calls GetTextureIndex), the descriptor set
	-- has already been bound and won't include the newly registered texture.
	local pipeline = render2d.GetActivePipeline()

	if pipeline then
		if state.texture then
			pipeline:GetTextureIndex(state.texture, 1, render.GetSamplerFilterConfig())
		end

		if state.sdf_texture then
			pipeline:GetTextureIndex(state.sdf_texture, 1, render.GetSamplerFilterConfig())
		end
	end

	render2d.state.render.pipeline.blend = state.blend_mode
	render2d.state.render.pipeline.depth.mode = depth_mode_names[state.rect_state_snapshot.depth_mode_id]
	render2d.state.render.pipeline.depth.write = state.rect_state_snapshot.depth_write == 1
	render2d.state.render.pipeline.stencil.mode = stencil_mode_names[state.rect_state_snapshot.stencil_mode_id]
	render2d.state.render.pipeline.stencil.ref = state.rect_state_snapshot.stencil_ref
	render2d.state.render.pipeline.scissor.x = state.rect_state_snapshot.scissor[0]
	render2d.state.render.pipeline.scissor.y = state.rect_state_snapshot.scissor[1]
	render2d.state.render.pipeline.scissor.w = state.rect_state_snapshot.scissor[2]
	render2d.state.render.pipeline.scissor.h = state.rect_state_snapshot.scissor[3]
	render2d.MarkPipelineStateDirty()
	apply_scissor_to_command_buffer(
		state.rect_state_snapshot.scissor[0],
		state.rect_state_snapshot.scissor[1],
		state.rect_state_snapshot.scissor[2],
		state.rect_state_snapshot.scissor[3]
	)
	Matrix44.CopyTo(state.world_matrix, render2d.GetWorldMatrix())
end

do
	local function invalidate_margin_cache()
		render2d.state.render.options.computed_margin_dirty = true
	end

	local function get_margin()
		local options = render2d.state.render.options

		if not options.computed_margin_dirty then return options.computed_margin end

		local constants = render2d.state.render.fragment.constants
		local content_m = math.abs(constants.outline_width)
		local swizzle = bit.band(constants.flags, 0xF)

		if render2d.state.render.textures.sdf_texture ~= nil or swizzle == 1 then
			content_m = content_m + math.max(constants.blur[0], constants.blur[1], constants.sdf_softness)
		end

		if
			constants.blur[0] > 0 or
			constants.blur[1] > 0 or
			constants.sdf_softness > 0 or
			content_m > 0
		then
			content_m = math.max(content_m, constants.blur[0], constants.blur[1], constants.sdf_softness)
		end

		local m = content_m

		if m > 0 then m = m + 1 end

		options.computed_margin = math.ceil(m)
		options.computed_margin_dirty = false
		return options.computed_margin
	end

	function render2d.GetMargin()
		return render2d.state.render.options.margin_override or get_margin()
	end

	function render2d.SetMargin(new_m)
		render2d.state.render.options.margin_override = new_m
		invalidate_margin_cache()
	end

	local function queue_rect_draw(use_float, x, y, w, h, a, ox, oy, max_m, u1, v1, u2, v2)
		local margin = render2d.GetMargin(w, h)
		local batch_mode = render2d.GetRectBatchMode()

		if max_m then margin = math.min(margin, max_m) end

		-- Set SDF UV bounds to original UV region before margin expansion
		local constants = render2d.state.render.fragment.constants
		constants.sdf_uv_bounds[0] = u1 or constants.uv_offset[0]
		constants.sdf_uv_bounds[1] = v1 or constants.uv_offset[1]
		constants.sdf_uv_bounds[2] = u2 or (constants.uv_offset[0] + constants.uv_scale[0])
		constants.sdf_uv_bounds[3] = v2 or (constants.uv_offset[1] + constants.uv_scale[1])
		local state = capture_rect_draw_state(acquire_rect_batch_world_matrix(), u1, v1, u2, v2)
		local draw_matrix, qw, qh = build_rect_draw_matrix(
			state.world_matrix,
			x,
			y,
			w,
			h,
			a,
			ox,
			oy,
			margin,
			use_float,
			acquire_rect_batch_draw_matrix()
		)
		local entry = acquire_rect_batch_entry()
		entry.batch_mode = batch_mode
		entry.use_float = use_float
		entry.x = x
		entry.y = y
		entry.w = w
		entry.h = h
		entry.a = a
		entry.ox = ox
		entry.oy = oy
		entry.qw = qw
		entry.qh = qh
		entry.margin = margin
		entry.draw_matrix = draw_matrix
		entry.state = state
		render2d.state.runtime.batch.state:Append("rect", build_rect_batch_key(state, w, h, margin, batch_mode), entry)
		return true
	end

	draw_rect_immediate = function(x, y, w, h, a, ox, oy, margin, use_float)
		local resolved_margin = margin or render2d.GetMargin(w, h)

		if not bind_mesh_immediate(render2d.rect_mesh) then return false end

		local constants = render2d.state.render.fragment.constants
		local old_off_x, old_off_y = constants.uv_offset[0], constants.uv_offset[1]
		local old_scale_x, old_scale_y = constants.uv_scale[0], constants.uv_scale[1]
		render2d.PushMatrix()

		if x and y then
			if use_float then
				render2d.Translatef(x - resolved_margin, y - resolved_margin)
			else
				render2d.Translate(x - resolved_margin, y - resolved_margin)
			end
		end

		if a then render2d.Rotate(a) end

		if ox then
			if use_float then
				render2d.Translatef(-ox, -oy)
			else
				render2d.Translate(-ox, -oy)
			end
		end

		local qw, qh = w + resolved_margin * 2, h + resolved_margin * 2

		if w and h then
			if use_float then
				render2d.Scalef(qw, qh)
			else
				render2d.Scale(qw, qh)
			end
		end

		if resolved_margin > 0 and w > 0 and h > 0 then
			constants.uv_scale[0] = old_scale_x * (qw / w)
			constants.uv_scale[1] = old_scale_y * (qh / h)
			constants.uv_offset[0] = old_off_x - (resolved_margin / w) * old_scale_x
			constants.uv_offset[1] = old_off_y - (resolved_margin / h) * old_scale_y
		end

		constants.sdf_uv_bounds[0] = old_off_x
		constants.sdf_uv_bounds[1] = old_off_y
		constants.sdf_uv_bounds[2] = old_off_x + old_scale_x
		constants.sdf_uv_bounds[3] = old_off_y + old_scale_y
		local cmd = render.GetCommandBuffer()
		render2d.UploadConstants(qw, qh, w, h)
		render2d.rect_mesh:DrawIndexed(cmd, 6)
		constants.uv_offset[0], constants.uv_offset[1] = old_off_x, old_off_y
		constants.uv_scale[0], constants.uv_scale[1] = old_scale_x, old_scale_y
		render2d.PopMatrix()
		return true
	end

	function render2d.DrawRect(x, y, w, h, a, ox, oy, max_m)
		if can_batch_rect_draw() then
			return queue_rect_draw(false, x, y, w, h, a, ox, oy, max_m)
		end

		return draw_rect_immediate(x, y, w, h, a, ox, oy, nil, false)
	end

	local function draw_rect_with_uv2(use_float, x, y, w, h, u1, v1, u2, v2, a, ox, oy, max_m)
		local constants = render2d.state.render.fragment.constants
		local result

		if can_batch_rect_draw() then
			result = queue_rect_draw(
				use_float,
				x,
				y,
				w,
				h,
				a,
				ox,
				oy,
				max_m,
				u1,
				v1,
				u2,
				v2
			)
		else
			local old_off_x, old_off_y = constants.uv_offset[0], constants.uv_offset[1]
			local old_scale_x, old_scale_y = constants.uv_scale[0], constants.uv_scale[1]
			constants.uv_offset[0] = u1
			constants.uv_offset[1] = v1
			constants.uv_scale[0] = u2 - u1
			constants.uv_scale[1] = v2 - v1
			result = draw_rect_immediate(x, y, w, h, a, ox, oy, nil, use_float)
			constants.uv_offset[0], constants.uv_offset[1] = old_off_x, old_off_y
			constants.uv_scale[0], constants.uv_scale[1] = old_scale_x, old_scale_y
		end

		return result
	end

	function render2d.DrawRectUV2(x, y, w, h, u1, v1, u2, v2, a, ox, oy, max_m)
		return draw_rect_with_uv2(false, x, y, w, h, u1, v1, u2, v2, a, ox, oy, max_m)
	end

	function render2d.DrawRectf(x, y, w, h, a, ox, oy, max_m)
		if can_batch_rect_draw() then
			return queue_rect_draw(true, x, y, w, h, a, ox, oy, max_m)
		end

		return draw_rect_immediate(x, y, w, h, a, ox, oy, nil, true)
	end

	function render2d.DrawRectUV2f(x, y, w, h, u1, v1, u2, v2, a, ox, oy, max_m)
		return draw_rect_with_uv2(true, x, y, w, h, u1, v1, u2, v2, a, ox, oy, max_m)
	end
end

function render2d.BindPipeline(force)
	sync_pipeline_state(force)
	-- Reset mesh binding cache since command buffer state was reset
	render2d.state.runtime.mesh.last_bound = nil
end

function render2d.GetActivePipeline()
	return render2d.shader_override or render2d.pipeline
end

render2d.SetColor(1, 1, 1, 1)
render2d.SetAlphaMultiplier(1)
render2d.SetSwizzleMode(0)
render2d.state.render.pipeline.blend = get_blend_preset_state("alpha")
render2d.state.runtime.pipeline_state.dirty = true

render.RegisterFlushCallback("render2d", function(reason)
	if reason == "begin_frame" then reset_rect_batch_instance_frame_state() end

	-- Don't flush on pop_command_buffer when there's no active command buffer.
	-- This happens during canvas switching: the old canvas is popped before
	-- the new canvas is pushed, so there's nothing to draw to.
	if reason == "pop_command_buffer" and not render.GetCommandBuffer() then
		return false
	end

	-- Don't flush when the active command buffer is not inside a render pass.
	-- This happens when temporary command buffers are pushed (e.g. SDF glyph
	-- loading) that record transfer/compute work outside of rendering.
	local cmd = render.GetCommandBuffer()

	if cmd and not cmd.is_rendering then return false end

	return render2d.FlushBatches(reason)
end)

event.AddListener("PostDraw", "draw_2d", function(dt)
	if not render2d.pipeline then return end -- not 2d initialized
	render2d.BindPipeline()
	event.Call("PreDraw2D", dt)
	event.Call("Draw2D", dt)
	render2d.FlushBatches("draw_2d")
end)

event.AddListener("WindowFramebufferResized", "render2d", function(wnd, size)
	if render.target:IsValid() and render.target.config.offscreen then return end

	render2d.SetScreenSize(size.x, size.y)
end)

if HOTRELOAD then
	render2d.pipeline = nil
	render2d.rect_batch_pipeline = nil
	render2d.state.runtime.ids.roots.pipeline = {}
	render2d.Initialize()
end

return render2d
