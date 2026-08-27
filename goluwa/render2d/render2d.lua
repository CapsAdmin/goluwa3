local ffi = require("ffi")
local utility = import("goluwa/utility.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local event = import("goluwa/event.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Mesh = import("goluwa/render/mesh.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Hash = import("goluwa/hash.lua")
local render2d = library()

local function concat_constant_fields(...)
	local out = {}

	for _, fields in ipairs({...}) do
		for _, field in ipairs(fields) do
			out[#out + 1] = {field[1], field[2], field[3], field[4]}
		end
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
	{"sdf_uv_offset", "vec2"},
	{"sdf_uv_scale", "vec2"},
	{"sdf_uv_bounds", "vec4"},
	{"flags", "int"},
	{"color_uv_offset", "vec2"},
	{"color_uv_scale", "vec2"},
	{"color_uv_rotation", "float"},
	{"light_color", "vec3"},
	{"ambient_color", "vec3"},
}
local fragment_shape_constant_fields = {
	{"border_radius", "vec4"},
	{"outline_width", "float"},
	{"rect_size", "vec2"},
	{"sdf_threshold", "float"},
	{"sdf_texel_range", "float"},
	{"sdf_rect_size", "vec2"},
	{"sdf_bias", "float"},
	{"sdf_gamma", "float"},
	{"sdf_softness", "float"},
	{"bevel_width", "float"},
	{"bevel_height", "float"},
	{"light_angle", "float"},
	{"light_shininess", "float"},
}
local fragment_patch_constant_fields = {
	{"nine_patch_x_count", "int"},
	{"nine_patch_y_count", "int"},
	{"nine_patch_x_stretch", "float", 6},
	{"nine_patch_y_stretch", "float", 6},
}
local rect_draw_state_tail_fields = {
	{"depth_mode_id", "int"},
	{"depth_write", "int"},
	{"stencil_mode_id", "int"},
	{"stencil_ref", "int"},
	{"scissor", "int", 4},
}
local fragment_constant_fields = concat_constant_fields(
	fragment_draw_constant_fields,
	fragment_shape_constant_fields,
	fragment_patch_constant_fields
)
local RectDrawState = EasyPipeline.BuildFFIType(
	"scalar",
	"Render2DRectDrawState",
	concat_constant_fields(fragment_constant_fields, rect_draw_state_tail_fields)
)
local constants_size = ffi.sizeof(RectDrawState)
local DEFAULT_BLEND_MODE = "alpha"
local DEFAULT_COLOR_WRITE_MASK = "rgba"
local DEFAULT_DEPTH_MODE = "none"
local depth_mode_ids, depth_mode_names, depth_mode_to_compare_op = {}, {}, {}

do
	local modes = {
		{"none"},
		{"less", "less"},
		{"lequal", "less_or_equal"},
		{"equal", "equal"},
		{"gequal", "greater_or_equal"},
		{"greater", "greater"},
		{"notequal", "not_equal"},
		{"always", "always"},
	}

	for id, mode in ipairs(modes) do
		depth_mode_ids[mode[1]] = id
		depth_mode_names[id] = mode[1]

		if mode[2] then depth_mode_to_compare_op[mode[1]] = mode[2] end
	end
end

local stencil_mode_names = {
	"none",
	"write",
	"mask_write",
	"mask_test",
	"mask_decrement",
	"test",
	"test_inverse",
	"greater",
}
local stencil_mode_ids = {}

for id, name in ipairs(stencil_mode_names) do
	stencil_mode_ids[name] = id
end

local function blend_preset(blend, src_color, dst_color, color_op, src_alpha, dst_alpha, alpha_op)
	return {
		blend = blend,
		src_color_blend_factor = src_color,
		dst_color_blend_factor = dst_color,
		color_blend_op = color_op,
		src_alpha_blend_factor = src_alpha,
		dst_alpha_blend_factor = dst_alpha,
		alpha_blend_op = alpha_op,
		color_write_mask = DEFAULT_COLOR_WRITE_MASK,
	}
end

render2d.blend_modes = {
	alpha = blend_preset(true, "src_alpha", "one_minus_src_alpha", "add", "one", "zero", "add"),
	additive = blend_preset(true, "src_alpha", "one", "add", "zero", "one", "add"),
	multiply = blend_preset(true, "dst_color", "zero", "add", "dst_alpha", "zero", "add"),
	premultiplied = blend_preset(true, "one", "one_minus_src_alpha", "add", "one", "one_minus_src_alpha", "add"),
	screen = blend_preset(true, "one", "one_minus_src_color", "add", "one", "one_minus_src_alpha", "add"),
	subtract = blend_preset(true, "src_alpha", "one", "reverse_subtract", "one", "one", "reverse_subtract"),
	none = blend_preset(false, "one", "zero", "add", "one", "zero", "add"),
}

local function stencil_mode(stencil_test, pass_op, compare_op, color_write_mask)
	return {
		stencil_test = stencil_test,
		front = {
			fail_op = "keep",
			pass_op = pass_op,
			depth_fail_op = "keep",
			compare_op = compare_op,
		},
		color_write_mask = color_write_mask or "",
	}
end

render2d.stencil_modes = {
	none = stencil_mode(false, "keep", "always", DEFAULT_COLOR_WRITE_MASK), -- no stencil, draw everything
	write = stencil_mode(true, "replace", "always"), -- simply write the reference value everywhere
	mask_write = stencil_mode(true, "increment_and_clamp", "equal"), -- increment level if it matches reference
	mask_test = stencil_mode(true, "keep", "equal", DEFAULT_COLOR_WRITE_MASK), -- pass if it matches reference
	mask_decrement = stencil_mode(true, "decrement_and_clamp", "equal"), -- decrement level if it matches reference
	test = stencil_mode(true, "keep", "equal", DEFAULT_COLOR_WRITE_MASK),
	greater = stencil_mode(true, "keep", "greater", DEFAULT_COLOR_WRITE_MASK),
	test_inverse = stencil_mode(true, "keep", "not_equal", DEFAULT_COLOR_WRITE_MASK),
}
render2d.state = {
	render = {
		fragment = {
			constants = RectDrawState(),
			rect_size = {w = 0, h = 0, lw = 0, lh = 0},
			color_uv = {x = 0, y = 0, w = 1, h = 1, r = 0},
			sdf_uv = {x = 0, y = 0, w = 1, h = 1},
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
			batched_rect_draws_enabled = true,
			rect_batch_mode = "instanced",
			computed_margin = 0,
			computed_margin_dirty = true,
			margin_override = nil,
		},
	},
	runtime = {
		batch = {
			state = {
				pending_draws = 0,
				is_flushing = false,
				segments = {},
			},
			mode_ids = {
				immediate = 1,
				replay = 2,
				instanced = 3,
			},
			next_entry_slot = 1,
			next_world_matrix_slot = 1,
			next_draw_matrix_slot = 1,
			next_rect_draw_state_snapshot_slot = 1,
			rect_state_version = 0,
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
-- Pooled per-frame scratch objects for queued rect draws. Slot counters reset each
-- flush, so pools grow at most to the biggest single frame and are reused after.
render2d.rect_batch_world_matrices = {}
render2d.rect_batch_draw_matrices = {}
render2d.rect_batch_entries = {}
render2d.rect_batch_state_snapshots = {}
render2d.rect_batch_instance_buffers = {}
local constants = render2d.state.render.fragment.constants
local fragment_state = render2d.state.render.fragment
local textures = render2d.state.render.textures
local pipeline_config = render2d.state.render.pipeline
local options = render2d.state.render.options
local batch_runtime = render2d.state.runtime.batch
local blend_key_interner = Hash.New()
local rect_key_interner = Hash.New()
local runtime_pipeline = render2d.state.runtime.pipeline_state
local frame_state = render2d.state.runtime.frame
local mesh_state = render2d.state.runtime.mesh
local camera_state = render2d.state.runtime.camera

local function reset_rect_batch_instance_frame_state()
	frame_state.next_rect_batch_instance_buffer_slot = 1
end

local function reset_rect_batch_matrix_pool_state()
	batch_runtime.next_entry_slot = 1
	batch_runtime.next_world_matrix_slot = 1
	batch_runtime.next_draw_matrix_slot = 1
	batch_runtime.next_rect_draw_state_snapshot_slot = 1
end

local function next_batch_rect_version()
	batch_runtime.rect_state_version = batch_runtime.rect_state_version + 1
end

function render2d.SetRectBatchMode(mode)
	assert(batch_runtime.mode_ids[mode])
	options.rect_batch_mode = mode
end

function render2d.GetRectBatchMode()
	return options.rect_batch_mode
end

utility.MakePushPopFunction(render2d, "RectBatchMode", 1)
local bind_mesh_immediate
local draw_rect_immediate
local apply_scissor_to_command_buffer
local float_size = ffi.sizeof("float")
local rect_batch_matrix_copy_size = float_size * 16
local vec_spec_by_component_count = {
	[1] = {type = "float", format = "r32_sfloat"},
	[3] = {type = "vec3", format = "r32g32b32_sfloat"},
	[4] = {type = "vec4", format = "r32g32b32a32_sfloat"},
}

-- Batched draws carry per-rect state as vertex attributes instead of push
-- constants. This entry just copies a field from the captured draw state.
local function snapshot_passthrough(name, snapshot_field, component_count, fragment_values, extra_write)
	local spec = vec_spec_by_component_count[component_count]
	return {
		name = name,
		type = spec.type,
		format = spec.format,
		write = function(vertex, entry, state, rect_state_snapshot)
			if component_count == 1 then
				vertex[name] = rect_state_snapshot[snapshot_field]
			else
				ffi.copy(vertex[name], rect_state_snapshot[snapshot_field], float_size * component_count)
			end

			if extra_write then extra_write(vertex, entry, state, rect_state_snapshot) end
		end,
		fragment_values = fragment_values,
	}
end

local rect_batch_fragment_passthrough_fields = {
	snapshot_passthrough(
		"batch_global_color",
		"global_color",
		4,
		{{"draw.global_color", "batch_global_color", "in_batch_global_color"}},
		function(vertex, entry, state)
			vertex.batch_global_color[3] = vertex.batch_global_color[3] * state.alpha_multiplier
		end
	),
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
			{"draw.sdf_uv_offset", "batch_uv_offset", "in_batch_uv_transform.xy"},
			{"draw.sdf_uv_scale", "batch_uv_scale", "in_batch_uv_transform.zw"},
		},
	},
	{
		name = "batch_shape_state",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_shape_state[0] = 0
			vertex.batch_shape_state[1] = 0
			vertex.batch_shape_state[2] = rect_state_snapshot.flags
			vertex.batch_shape_state[3] = 0
		end,
		fragment_values = {
			{"draw.flags", {"int", "batch_flags"}, "int(round(in_batch_shape_state.z))"},
		},
	},
	snapshot_passthrough(
		"batch_border_radius",
		"border_radius",
		4,
		{{"shape.border_radius", "batch_border_radius", "in_batch_border_radius"}}
	),
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
	snapshot_passthrough(
		"batch_color_uv_rotation",
		"color_uv_rotation",
		1,
		{
			{
				"draw.color_uv_rotation",
				"batch_color_uv_rotation",
				"in_batch_color_uv_rotation",
			},
		}
	),
	snapshot_passthrough(
		"batch_outline_width",
		"outline_width",
		1,
		{{"shape.outline_width", "batch_outline_width", "in_batch_outline_width"}}
	),
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
	snapshot_passthrough(
		"batch_sdf_uv_bounds",
		"sdf_uv_bounds",
		4,
		{{"draw.sdf_uv_bounds", "batch_sdf_uv_bounds", "in_batch_sdf_uv_bounds"}}
	),
}

function render2d.GetBatchState()
	return batch_runtime.state
end

function render2d.HasPendingBatches()
	return batch_runtime.state.pending_draws > 0
end

function render2d.MarkBatchesPending(count)
	batch_runtime.state.pending_draws = batch_runtime.state.pending_draws + (count or 1)
	return batch_runtime.state.pending_draws
end

function render2d.ClearPendingBatches()
	render2d.ClearPending()
	reset_rect_batch_matrix_pool_state()
end

function render2d.ClearPending()
	batch_runtime.state.pending_draws = 0
	table.clear(batch_runtime.state.segments)
end

function render2d.SaveBatchState()
	local state = batch_runtime.state
	return {
		pending_draws = state.pending_draws,
		segments = list.copy(state.segments),
	}
end

function render2d.RestoreBatchState(saved)
	local state = batch_runtime.state
	state.pending_draws = saved.pending_draws
	state.segments = saved.segments
end

function render2d.MarkPipelineStateDirty()
	runtime_pipeline.dirty = true
	next_batch_rect_version()
end

local function canonicalize_blend_mode_state(state)
	local blend = state.blend

	if blend == nil then
		blend = false

		for _, key in ipairs{
			"src_color_blend_factor",
			"dst_color_blend_factor",
			"color_blend_op",
			"src_alpha_blend_factor",
			"dst_alpha_blend_factor",
			"alpha_blend_op",
		} do
			if state[key] ~= nil then
				blend = true

				break
			end
		end
	end

	local result = {
		blend = blend,
		src_color_blend_factor = state.src_color_blend_factor or "one",
		dst_color_blend_factor = state.dst_color_blend_factor or "zero",
		color_blend_op = state.color_blend_op or "add",
		src_alpha_blend_factor = state.src_alpha_blend_factor or "one",
		dst_alpha_blend_factor = state.dst_alpha_blend_factor or "zero",
		alpha_blend_op = state.alpha_blend_op or "add",
		color_write_mask = state.color_write_mask or DEFAULT_COLOR_WRITE_MASK,
	}
	result.batch_key = blend_key_interner:intern{
		result.blend,
		result.src_color_blend_factor,
		result.dst_color_blend_factor,
		result.color_blend_op,
		result.src_alpha_blend_factor,
		result.dst_alpha_blend_factor,
		result.alpha_blend_op,
		result.color_write_mask,
	}
	return result
end

local function get_blend_preset_state(mode_name)
	mode_name = mode_name or DEFAULT_BLEND_MODE
	local preset = render2d.blend_modes[mode_name]

	if not preset then
		local valid_modes = {}

		for mode in pairs(render2d.blend_modes) do
			table.insert(valid_modes, mode)
		end

		table.sort(valid_modes)
		error(
			"Invalid blend mode: " .. tostring(mode_name) .. ". Valid modes: " .. table.concat(valid_modes, ", "),
			2
		)
	end

	return canonicalize_blend_mode_state(preset)
end

local function sync_pipeline_state(force)
	local pipeline = render2d.GetActivePipeline()

	if
		not force and
		not runtime_pipeline.dirty and
		runtime_pipeline.synced_pipeline == pipeline
	then
		return
	end

	local blend_mode = pipeline_config.blend or get_blend_preset_state(DEFAULT_BLEND_MODE)
	local depth_state = pipeline_config.depth
	local stencil_state = pipeline_config.stencil
	local stencil_mode_def = render2d.stencil_modes[stencil_state.mode or "none"]
	local depth_mode_name = depth_state.mode or DEFAULT_DEPTH_MODE
	local stencil_ref = stencil_state.ref ~= nil and stencil_state.ref or 1
	local cmd = assert(render.GetCommandBuffer())
	pipeline:SetBlend(blend_mode.blend)
	pipeline:SetSrcColorBlendFactor(blend_mode.src_color_blend_factor)
	pipeline:SetDstColorBlendFactor(blend_mode.dst_color_blend_factor)
	pipeline:SetColorBlendOp(blend_mode.color_blend_op)
	pipeline:SetSrcAlphaBlendFactor(blend_mode.src_alpha_blend_factor)
	pipeline:SetDstAlphaBlendFactor(blend_mode.dst_alpha_blend_factor)
	pipeline:SetAlphaBlendOp(blend_mode.alpha_blend_op)
	pipeline:SetColorWriteMask(stencil_mode_def.color_write_mask or blend_mode.color_write_mask)
	pipeline:SetDepthTest(depth_mode_name ~= DEFAULT_DEPTH_MODE)
	pipeline:SetDepthWrite(depth_state.write == true)
	pipeline:SetDepthCompareOp(depth_mode_to_compare_op[depth_mode_name] or "always")
	pipeline:SetStencilTest(stencil_mode_def.stencil_test)

	-- Front and back faces are always configured identically
	do
		pipeline:SetFrontStencilFailOp(stencil_mode_def.front.fail_op)
		pipeline:SetFrontStencilPassOp(stencil_mode_def.front.pass_op)
		pipeline:SetFrontStencilDepthFailOp(stencil_mode_def.front.depth_fail_op)
		pipeline:SetFrontStencilCompareOp(stencil_mode_def.front.compare_op)
		pipeline:SetFrontStencilReference(stencil_ref)
		pipeline:SetFrontStencilCompareMask(0xFF)
		pipeline:SetFrontStencilWriteMask(0xFF)
		--
		pipeline:SetBackStencilFailOp(stencil_mode_def.front.fail_op)
		pipeline:SetBackStencilPassOp(stencil_mode_def.front.pass_op)
		pipeline:SetBackStencilDepthFailOp(stencil_mode_def.front.depth_fail_op)
		pipeline:SetBackStencilCompareOp(stencil_mode_def.front.compare_op)
		pipeline:SetBackStencilReference(stencil_ref)
		pipeline:SetBackStencilCompareMask(0xFF)
		pipeline:SetBackStencilWriteMask(0xFF)
	end

	pipeline:Bind(cmd, render.GetCurrentFrame())
	runtime_pipeline.dirty = false
	runtime_pipeline.synced_pipeline = pipeline
end

local function get_render2d_fragment_constants_source()
	return constants
end

local batch_counter_fields = {
	"flushes",
	"queued_draws",
	"queued_segments",
	"gpu_draw_calls",
	"instanced_draws",
	"instanced_segments",
	"replay_draws",
	"max_segment_size",
}

local function new_batch_counters()
	local counters = {}

	for _, key in ipairs(batch_counter_fields) do
		counters[key] = 0
	end

	return counters
end

local function reset_batch_counters(target)
	target = target or new_batch_counters()

	for _, key in ipairs(batch_counter_fields) do
		target[key] = 0
	end

	return target
end

local function copy_batch_counters(dst, src)
	reset_batch_counters(dst)

	for _, key in ipairs(batch_counter_fields) do
		dst[key] = src[key]
	end

	return dst
end

function render2d.ResetBatchCounters()
	render2d.batch_counters = reset_batch_counters(render2d.batch_counters)
	render2d.last_batch_counters = reset_batch_counters(render2d.last_batch_counters)
	return render2d.last_batch_counters
end

function render2d.GetBatchCounters()
	render2d.last_batch_counters = render2d.last_batch_counters or new_batch_counters()
	return render2d.last_batch_counters
end

function render2d.GetLiveBatchCounters()
	render2d.batch_counters = render2d.batch_counters or new_batch_counters()
	return render2d.batch_counters
end

render2d.batch_counters = new_batch_counters()
render2d.last_batch_counters = new_batch_counters()

function render2d.FlushBatches(reason)
	do
		if batch_runtime.state.is_flushing then return false end

		if batch_runtime.state.pending_draws == 0 then return false end

		batch_runtime.state.is_flushing = true
	end

	local saved_state = render2d.CaptureRectDrawState()
	local saved_batched_rect_draws_enabled = options.batched_rect_draws_enabled
	local saved_shader_override = render2d.shader_override
	local batch_counters = (render.stats or render2d.enable_batch_recording) and render2d.GetLiveBatchCounters()
	options.batched_rect_draws_enabled = false

	for _, segment in ipairs(batch_runtime.state.segments) do
		if batch_counters then
			batch_counters.max_segment_size = math.max(batch_counters.max_segment_size, #segment.entries)
		end

		if
			segment.kind == "rect" and
			segment.entries[1] and
			segment.entries[1].batch_mode == "instanced" and
			render2d.rect_batch_pipeline
		then
			local first = segment.entries[1]
			local slot = frame_state.next_rect_batch_instance_buffer_slot
			local capacity = #segment.entries
			local frame_index = render.GetCurrentFrame() or 1
			local frame_buffers = render2d.rect_batch_instance_buffers[frame_index]

			if not frame_buffers then
				frame_buffers = {}
				render2d.rect_batch_instance_buffers[frame_index] = frame_buffers
			end

			local instance_buffer = frame_buffers[slot]

			if not instance_buffer or instance_buffer:GetVertexCount() < capacity then
				instance_buffer = VertexBuffer.New(
					capacity,
					render2d.rect_batch_instance_buffer_attributes,
					string.format("render2d rect batch instance frame=%d slot=%d", frame_index, slot)
				)
				frame_buffers[slot] = instance_buffer
			end

			local vertices = instance_buffer:GetVertices()
			frame_state.next_rect_batch_instance_buffer_slot = slot + 1

			for i, entry in ipairs(segment.entries) do
				local vertex = vertices[i - 1]
				local state = entry.state
				local rect_state_snapshot = state.rect_state_snapshot
				local off_x = rect_state_snapshot.sdf_uv_offset[0]
				local off_y = rect_state_snapshot.sdf_uv_offset[1]
				local scale_x = rect_state_snapshot.sdf_uv_scale[0]
				local scale_y = rect_state_snapshot.sdf_uv_scale[1]
				local margin = entry.margin or 0

				if margin > 0 and entry.w > 0 and entry.h > 0 then
					scale_x = scale_x * (entry.qw / entry.w)
					scale_y = scale_y * (entry.qh / entry.h)
					off_x = off_x - (margin / entry.w) * rect_state_snapshot.sdf_uv_scale[0]
					off_y = off_y - (margin / entry.h) * rect_state_snapshot.sdf_uv_scale[1]
				end

				ffi.copy(vertex.pvw, entry.draw_matrix, rect_batch_matrix_copy_size)

				for _, field in ipairs(rect_batch_fragment_passthrough_fields) do
					field.write(
						vertex,
						entry,
						state,
						rect_state_snapshot,
						off_x,
						off_y,
						scale_x,
						scale_y
					)
				end
			end

			instance_buffer:Upload()
			render2d.RestoreRectDrawState(first.state)
			render2d.shader_override = render2d.rect_batch_pipeline
			sync_pipeline_state(true)
			render2d.rect_mesh:BindInstanced(render.GetCommandBuffer(), {instance_buffer}, 0)
			render2d.UploadConstants(first.qw, first.qh, first.w, first.h)
			render2d.rect_mesh:DrawIndexed(render.GetCommandBuffer(), 6, #segment.entries, 0, 0, 0)
			render2d.shader_override = saved_shader_override
			mesh_state.last_bound = nil

			if batch_counters then
				batch_counters.gpu_draw_calls = batch_counters.gpu_draw_calls + 1
				batch_counters.queued_draws = batch_counters.queued_draws + #segment.entries
				batch_counters.instanced_segments = batch_counters.instanced_segments + 1
				batch_counters.instanced_draws = batch_counters.instanced_draws + #segment.entries
			end
		else
			for _, entry in ipairs(segment.entries) do
				render2d.RestoreRectDrawState(entry.state)
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

				if batch_counters then
					batch_counters.replay_draws = batch_counters.replay_draws + 1
					batch_counters.gpu_draw_calls = batch_counters.gpu_draw_calls + 1
					batch_counters.queued_draws = batch_counters.queued_draws + 1
				end
			end
		end
	end

	render2d.RestoreRectDrawState(saved_state)
	render2d.shader_override = saved_shader_override
	options.batched_rect_draws_enabled = saved_batched_rect_draws_enabled

	if batch_counters then
		batch_counters.flushes = batch_counters.flushes + 1
		batch_counters.queued_segments = batch_counters.queued_segments + #batch_runtime.state.segments
		render2d.last_batch_counters = copy_batch_counters(render2d.last_batch_counters, batch_counters)
	end

	batch_runtime.state.is_flushing = false
	batch_runtime.state.pending_draws = 0
	table.clear(batch_runtime.state.segments)
	reset_rect_batch_matrix_pool_state()
	return true
end

function render2d.Initialize()
	if render2d.pipeline then return end

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
						block.global_color[3] = block.global_color[3] * fragment_state.alpha_multiplier
						block.texture_index = textures.texture and self:GetTextureIndex(textures.texture) or -1
						block.sdf_texture_index = textures.sdf_texture and
							self:GetTextureIndex(textures.sdf_texture) or
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
						field = "border_radius",
					},
					block = fragment_shape_constant_fields,
					write = function(self, block)
						block.rect_size[0] = fragment_state.rect_size.w
						block.rect_size[1] = fragment_state.rect_size.h
						block.sdf_rect_size[0] = fragment_state.rect_size.lw
						block.sdf_rect_size[1] = fragment_state.rect_size.lh
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

					// radius = (tl, tr, br, bl); p.y > 0 is the top of the screen
					float rad;
					if (p.x < 0.0 && p.y > 0.0) rad = radius.x;
					else if (p.x > 0.0 && p.y > 0.0) rad = radius.y;
					else if (p.x > 0.0 && p.y < 0.0) rad = radius.z;
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

				float sd_circle(vec2 p, float r) {
					return length(p) - r;
				}

				float sd_ellipse( in vec2 p, in vec2 r )
				{
					p = abs(p);
					p = max(p,(p-r).yx);
					float m = dot(r,r);
					float d = p.y-p.x;
					return p.x - (r.y*sqrt(m-d*d)-r.x*d)*r.x/m;
				}

				float sd_box( in vec2 p, in vec2 b )
				{
					vec2 d = abs(p)-b;
					return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
				}

				float sd_rounded_box(vec2 p, vec2 b, vec4 r) {
					r.xy = (p.x > 0.0) ? r.xy : r.zw;
					r.x = (p.y > 0.0) ? r.x : r.y;
					vec2 q = abs(p) - b + r.x;
					return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r.x;
				}

				float sd_chamfered_box(vec2 p, vec2 b, vec4 r) {
					vec2 ap = abs(p);
					vec2 q = ap - b;
					float sx = step(0.0, p.x);
					float sy = step(0.0, p.y);
					float rad = mix(mix(r.z, r.x, sx), mix(r.w, r.y, sx), sy);
					float e = q.x + q.y + rad;
					float h = clamp(0.5 * (q.y - q.x + rad), 0.0, rad);
					float seg = length(vec2(q.x + h, q.y + rad - h)) * sign(e);
					vec2 m = max(q, vec2(0.0));
					float outd = length(m);
					float ind = min(max(q.x, q.y), 0.0);
					return max(ind + outd, min(max(e, 0.0), seg));
				}

				float sd_line( in vec2 p, vec2 a, vec2 b )
				{
					vec2 pa = p-a, ba = b-a;
					float s = (ba.x*ba.y>0.0)?1.0:-1.0;
					float h = clamp( (pa.y+s*pa.x)/(ba.y+s*ba.x), 0.0, 1.0 );
					vec2 q = abs(pa-h*ba);
					return max(q.x,q.y);
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
						// transformed: sample uv goes through the draw uv transform (uv_scale/uv_offset)
						// direct: vertex sample uv is used as-is, ignoring the uv transform
						uv = FLAGS_SDF_SAMPLE_UV_MODE_DIRECT ? in_sample_uv : (in_sample_uv * draw.sdf_uv_scale + draw.sdf_uv_offset);
					}

					float bounds_left = min(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_right = max(draw.sdf_uv_bounds.x, draw.sdf_uv_bounds.z);
					float bounds_top = min(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					float bounds_bottom = max(draw.sdf_uv_bounds.y, draw.sdf_uv_bounds.w);
					
					uv = clamp(uv, vec2(bounds_left, bounds_top), vec2(bounds_right, bounds_bottom));

					return uv;
				}

				float get_sdf_screen_scale() {
					if (shape.rect_size.x <= 0.0 || shape.rect_size.y <= 0.0) return 1.0;
					vec2 fw = fwidth(in_uv) * shape.rect_size;
					return max(1.0 / max(fw.x, 1e-6), 1.0 / max(fw.y, 1e-6));
				}

				float get_sdf_texels_per_screen_pixel() {
					vec2 tex_size = vec2(textureSize(TEXTURE(draw.sdf_texture_index), 0));
					vec2 rate = fwidth(in_sample_uv) * tex_size;
					if (!FLAGS_SDF_SAMPLE_UV_MODE_DIRECT) {
						rate *= abs(draw.sdf_uv_scale);
					}
					return max(rate.x, rate.y);
				}

				float edge(float x) {
					float softness = shape.sdf_softness;
					return smoothstep(-softness, softness, x);
				}
					
				float compute_sdf_alpha(float d) {
					float alpha = edge(d);

					float outline = shape.outline_width * get_sdf_screen_scale();

					if (outline != 0) 
						alpha = abs(alpha - edge(d + outline));

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
					
				float get_sdf_distance(vec2 coords) {
					if (draw.sdf_texture_index != -1) {
						float range = shape.sdf_texel_range;
						float d = read_raw_sdf(coords);
						d *= range;
						d -= shape.sdf_threshold * range;
						d += shape.sdf_bias * range;
						d /= max(get_sdf_texels_per_screen_pixel(), 1e-6);
						return d;
					//} else if (FLAGS_SHAPE != 0 && shape.sdf_rect_size.x > 0.0 && shape.sdf_rect_size.y > 0.0) {
					} else if (FLAGS_SHAPE != 0) {
						vec2 p = (coords - 0.5) * shape.rect_size;
						vec2 b = shape.sdf_rect_size * 0.5;
						float d;
						if (FLAGS_SHAPE_RECT) {
							d = sd_box(p, b);
						} else if (FLAGS_SHAPE_CIRCLE) {
							d = sd_circle(p, b.x);
						} else if (FLAGS_SHAPE_ROUNDED) {
							d = sd_rounded_box(p, b, shape.border_radius.yzxw);
						} else if (FLAGS_SHAPE_CHAMFERED) {
							d = sd_chamfered_box(p, b, shape.border_radius.yzxw);
						} else if (FLAGS_SHAPE_ELLIPSE) {
							d = sd_ellipse(p, b);
						}
						//else if (FLAGS_SHAPE_LINE) {
							//d = sd_line(p, b);
						//}
						return (-d) * get_sdf_screen_scale();
					} else if (shape.sdf_rect_size.x > 0.0 && shape.sdf_rect_size.y > 0.0) {
						float d = sd_rect(coords);
						return (-d) * get_sdf_screen_scale();
					}
					return 1.0;
				}

				vec4 apply_swizzle(vec4 tex) {
					if (FLAGS_SWIZZLE_RRR) return vec4(tex.rrr, 1.0);
					if (FLAGS_SWIZZLE_GGG) return vec4(tex.ggg, 1.0);
					if (FLAGS_SWIZZLE_BBB) return vec4(tex.bbb, 1.0);
					if (FLAGS_SWIZZLE_AAA) return vec4(tex.aaa, 1.0);
					if (FLAGS_SWIZZLE_RGB) return vec4(tex.rgb, 1.0);
					return tex;
				}

				vec3 srgb_to_linear(vec3 c) {
					vec3 low = c / 12.92;
					vec3 high = pow(max((c + 0.055) / 1.055, vec3(0.0)), vec3(2.4));
					return mix(low, high, step(vec3(0.0031308), c));
				}

				vec4 sample_fragment_color(vec2 uv) {
					// Vertex/global colors and texture values are both authored in
					// sRGB display space. Linearizing the final product (and letting
					// the sRGB framebuffer re-encode at write time) keeps the final
					// image equal to the plain authored product while blending
					// against the framebuffer still happens in linear space.
					vec4 color = in_color * draw.global_color;

					if (draw.texture_index >= 0) {
						vec4 tex = texture(TEXTURE(draw.texture_index), uv);
						color *= apply_swizzle(tex);
					}

					color.rgb = srgb_to_linear(color.rgb);

					return color;
				}
				
				void main()
				{
					vec2 color_uv = get_uv_color(in_uv);
					out_color = sample_fragment_color(color_uv);
					
					vec2 sdf_uv = get_uv_sdf(in_uv);
					float d = get_sdf_distance(sdf_uv);
					out_color.a *= compute_sdf_alpha(d);

					if (false) {
						vec3 col = (d>0.0) ? vec3(0.9,0.6,0.3) : vec3(0.65,0.85,1.0);
						col *= 1.0 - exp2(-20.0*abs(d));
						col *= 0.8 + 0.2*cos(120.0*abs(d));
						col = mix( col, vec3(1.0), 1.0-smoothstep(0.0,0.01,abs(d)) );
						out_color.rgb = col;
					}
						
					if (FLAGS_LIGHTING != 0) {
						if (shape.outline_width > 0)
							d = -d;

						float t = clamp(d / max(shape.bevel_width * get_sdf_screen_scale(), 1e-5), 0.0, 1.0);
						float tilt_t  =  mix(smoothstep(1, 0.0, t), t, shape.bevel_height);

						float eps = 0.0005*2;
						float dx = get_sdf_distance(sdf_uv + vec2(eps, 0.0)) - get_sdf_distance(sdf_uv - vec2(eps, 0.0));
						float dy = get_sdf_distance(sdf_uv + vec2(0.0, eps)) - get_sdf_distance(sdf_uv - vec2(0.0, eps));
						vec3 normal = normalize(vec3(normalize(vec2(dx, dy)) * tilt_t, 1.0));

						vec3 light_color = srgb_to_linear(draw.light_color);
						vec3 lit_color = srgb_to_linear(draw.ambient_color);

						vec3 light_dir = normalize(vec3(
							-cos(shape.light_angle),
							-sin(shape.light_angle),
							1.0
						));

						float diff = max(dot(normal, light_dir), 0.0);
						lit_color *= light_color * diff;

						vec3 view_dir = vec3(0.0, 0.0, 1.0);
						vec3 reflect_dir = reflect(-light_dir, normal);
						float spec = pow(max(dot(view_dir, reflect_dir), 0.0), shape.light_shininess);
						lit_color += light_color * spec;

						out_color.rgb *= lit_color;
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
		ColorWriteMask = "rgba",
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

	-- The rect batch pipeline reuses the main pipeline's fragment shader and
	-- constants, feeding per-rect state through instance attributes instead.
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

		local batch_config = {}

		for key, value in pairs(config) do
			batch_config[key] = value
		end

		batch_config.name = "render2d_rect_batch"
		batch_config.vertex = {
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
		}
		batch_config.fragment = {
			constants = config.fragment.constants,
			adapters = batch_fragment_adapters,
			shader = config.fragment.shader,
		}
		render2d.rect_batch_pipeline = EasyPipeline.New(batch_config)
	end

	do
		-- Instance attribute layout of the batch pipeline, used to allocate instance buffers
		render2d.rect_batch_instance_buffer_attributes = {}

		for _, attribute in ipairs(render2d.rect_batch_pipeline.vertex_attributes) do
			if attribute.binding == 1 then
				render2d.rect_batch_instance_buffer_attributes[#render2d.rect_batch_instance_buffer_attributes + 1] = attribute
			end
		end
	end

	local sampler_config_resolver = function()
		return render.GetSamplerFilterConfig()
	end
	render2d.pipeline:SetTextureSamplerConfigResolver(sampler_config_resolver)
	render2d.rect_batch_pipeline:SetTextureSamplerConfigResolver(sampler_config_resolver)
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

	do
		local function get_last_batch_counters()
			return render2d.GetBatchCounters()
		end

		render_stats.RegisterGroup{
			id = "render2d_batch",
			label = "RENDER2D BATCH",
		}
		render_stats.RegisterField{
			id = "r2d_batch_queued",
			label = "R2D Q DRAWS",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().queued_draws
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_segs",
			label = "R2D Q SEGS",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().queued_segments
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_gpu",
			label = "R2D GPU CALLS",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().gpu_draw_calls
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_inst",
			label = "R2D INST DRAWS",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().instanced_draws
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_inst_segs",
			label = "R2D INST SEGS",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().instanced_segments
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_replay",
			label = "R2D REPLAY",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().replay_draws
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_maxseg",
			label = "R2D MAX SEG",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().max_segment_size
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_flushes",
			label = "R2D FLUSHES",
			group = "render2d_batch",
			getter = function()
				return get_last_batch_counters().flushes
			end,
		}
		render_stats.RegisterField{
			id = "r2d_batch_pending",
			label = "R2D PENDING",
			group = "render2d_batch",
			getter = function()
				return render2d.GetBatchState().pending_draws
			end,
		}
	end

	runtime_pipeline.dirty = true
	import("goluwa/render2d/render2d_extensions.lua")
end

function render2d.ResetState()
	render2d.FlushBatches("reset_state")
	render2d.ClearPendingBatches()
	render2d.stencil_level = 0
	render2d.SetRectBatchMode("instanced")
	reset_rect_batch_instance_frame_state()
	render2d.SetTexture()
	render2d.SetSDFTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetSDFUV()
	render2d.SetColorUV()
	render2d.SetSwizzleMode("none")
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetOutlineWidth(0)
	constants.flags = 0
	render2d.SetClampBorderRadius(true)
	constants.sdf_texel_range = 1
	constants.sdf_threshold = 0.5
	constants.sdf_bias = 0
	constants.sdf_gamma = 1
	constants.sdf_softness = 0.5
	constants.sdf_texture_index = -1
	local sdf_uv_bounds = constants.sdf_uv_bounds
	sdf_uv_bounds[0], sdf_uv_bounds[1], sdf_uv_bounds[2], sdf_uv_bounds[3] = 0, 0, 1, 1
	render2d.ClearNinePatch()
	render2d.SetScreenSize(render.GetRenderImageSize():Unpack())
	render2d.SetScissor(0, 0, render2d.GetSize())
	render2d.SetBlendPreset("alpha")
	render2d.SetDepthMode(DEFAULT_DEPTH_MODE, false)
	render2d.SetStencilMode("none")
	--bevel
	render2d.SetBevelWidth(0.0)
	render2d.SetBevelHeight(0)
	render2d.SetLightAngle(0.785)
	render2d.SetLightShininess(32.0)
	render2d.SetLightColor(1.0, 1.0, 1.0)
	render2d.SetAmbientColor(0.3, 0.3, 0.3)
	render2d.SetLighting(false)
end

do
	local function mark_margin_dirty()
		options.computed_margin_dirty = true
	end

	local function define_scalar_property(name, field, on_set)
		render2d["Set" .. name] = function(value)
			constants[field] = value

			if on_set then on_set() end
		end
		render2d["Get" .. name] = function()
			return constants[field]
		end
		utility.MakePushPopFunction(render2d, name, 1)
	end

	local function define_flag_property(name, flag_key, value_filter, on_set)
		render2d["Set" .. name] = function(value)
			if value_filter then value = value_filter(value) end

			if value == nil then return end

			render2d.SetFlagBits(flag_key, value)

			if on_set then on_set() end
		end
		render2d["Get" .. name] = function()
			return render2d.GetFlagBits(flag_key)
		end
		utility.MakePushPopFunction(render2d, name, 1)
	end

	local function define_color3_property(name, field)
		render2d["Set" .. name] = function(r, g, b)
			local c = constants[field]
			c[0], c[1], c[2] = r, g, b
		end
		render2d["Get" .. name] = function()
			local c = constants[field]
			return c[0], c[1], c[2]
		end
		utility.MakePushPopFunction(render2d, name, 3)
	end

	function render2d.SetColor(r, g, b, a)
		constants.global_color[0] = r
		constants.global_color[1] = g
		constants.global_color[2] = b

		if a then constants.global_color[3] = a end
	end

	function render2d.GetColor()
		return constants.global_color[0],
		constants.global_color[1],
		constants.global_color[2],
		constants.global_color[3]
	end

	utility.MakePushPopFunction(render2d, "Color", 4)

	do -- Flag definitions: single source of truth for all flag fields
		local flag_builder = utility.MakeFlags{
			{
				name = "SWIZZLE",
				enums = {
					"none",
					"rrr",
					"ggg",
					"bbb",
					"aaa",
					"rgb",
				},
			},
			{
				name = "SDF_SAMPLE_UV_MODE",
				enums = {
					"transformed",
					"direct",
				},
			},
			{name = "CLAMP_BORDER_RADIUS"},
			{name = "MSDF"},
			{name = "LIGHTING"},
			{
				name = "SHAPE",
				label = "shape mode",
				enums = {
					"none",
					"rect",
					"circle",
					"rounded",
					"chamfered",
					"ellipse",
				--"line",
				},
			},
		}

		function render2d.SetFlagBits(key, val)
			render2d.state.render.fragment.constants.flags = flag_builder:set(constants.flags, key, val)
		end

		function render2d.GetFlagBits(key)
			return flag_builder:get(constants.flags, key)
		end

		function render2d.BuildShaderFlags(var_name)
			local lines = {}

			for _, def in ipairs(flag_builder.fields) do
				if def.shift == 0 then
					lines[#lines + 1] = "#define FLAGS_" .. def.name .. " (" .. var_name .. " & " .. def.mask .. ")"
				else
					lines[#lines + 1] = "#define FLAGS_" .. def.name .. " ((" .. var_name .. " & " .. def.shifted_mask .. ") >> " .. def.shift .. ")"
				end

				if def.map then
					local keys = {}

					for key in pairs(def.map) do
						keys[#keys + 1] = key
					end

					table.sort(keys)

					for _, key in ipairs(keys) do
						lines[#lines + 1] = "#define FLAGS_" .. def.name .. "_" .. key:upper() .. " (FLAGS_" .. def.name .. " == " .. def.map[key] .. ")"
					end
				end
			end

			return table.concat(lines, "\n")
		end
	end

	-- Convenience wrappers for the flag-based properties
	local bool_value_filter = function(value)
		return not not value
	end

	define_flag_property(
		"SwizzleMode",
		"SWIZZLE",
		function(value)
			return type(value) == "string" and value or nil
		end,
		mark_margin_dirty
	)

	define_flag_property("SDFSampleUVMode", "SDF_SAMPLE_UV_MODE", function(value)
		return value or "transformed"
	end)

	define_flag_property("Lighting", "LIGHTING", bool_value_filter)

	define_flag_property("ShapeMode", "SHAPE", function(value)
		if type(value) == "string" then return value end

		error("SetShapeMode expects a shape mode name, got " .. type(value), 2)
	end)

	define_flag_property("ClampBorderRadius", "CLAMP_BORDER_RADIUS", bool_value_filter)
	define_flag_property("MSDF", "MSDF", bool_value_filter)
	define_scalar_property("SDFSoftness", "sdf_softness", mark_margin_dirty)
	define_scalar_property("SDFTexelRange", "sdf_texel_range")
	define_scalar_property("SDFThreshold", "sdf_threshold")
	define_scalar_property("SDFBias", "sdf_bias")
	define_scalar_property("SDFGamma", "sdf_gamma")
	define_scalar_property("BevelWidth", "bevel_width")
	define_scalar_property("BevelHeight", "bevel_height")
	define_scalar_property("LightAngle", "light_angle")
	define_scalar_property("LightShininess", "light_shininess")
	define_color3_property("LightColor", "light_color")
	define_color3_property("AmbientColor", "ambient_color")

	function render2d.SetOutlineWidth(width)
		constants.outline_width = width or 0
		mark_margin_dirty()
	end

	function render2d.GetOutlineWidth()
		return constants.outline_width
	end

	utility.MakePushPopFunction(render2d, "OutlineWidth", 1)

	function render2d.SetBorderRadius(tl, tr, br, bl)
		if type(tl) == "table" then
			tr = tl[2]
			br = tl[3]
			bl = tl[4]
			tl = tl[1]
		end

		constants.border_radius[0] = tl or 0
		constants.border_radius[1] = tr or tl or 0
		constants.border_radius[2] = br or tl or 0
		constants.border_radius[3] = bl or tl or 0
	end

	function render2d.GetBorderRadius()
		return constants.border_radius[0],
		constants.border_radius[1],
		constants.border_radius[2],
		constants.border_radius[3]
	end

	utility.MakePushPopFunction(render2d, "BorderRadius", 4)

	function render2d.ClearNinePatch()
		constants.nine_patch_x_count = 0
		constants.nine_patch_y_count = 0

		for i = 0, 5 do
			constants.nine_patch_x_stretch[i] = 0
			constants.nine_patch_y_stretch[i] = 0
		end

		next_batch_rect_version()
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
		constants.nine_patch_x_stretch[index * 2] = x1
		constants.nine_patch_x_stretch[index * 2 + 1] = y1
		constants.nine_patch_x_count = math.max(constants.nine_patch_x_count, index + 1)
		constants.nine_patch_y_stretch[index * 2] = x2
		constants.nine_patch_y_stretch[index * 2 + 1] = y2
		constants.nine_patch_y_count = math.max(constants.nine_patch_y_count, index + 1)
		next_batch_rect_version()
	end

	function render2d.GetNinePatch()
		return constants.nine_patch_x_stretch[0],
		constants.nine_patch_x_stretch[1],
		constants.nine_patch_y_stretch[0],
		constants.nine_patch_y_stretch[1]
	end

	function render2d.SetAlphaMultiplier(a)
		fragment_state.alpha_multiplier = a
	end

	function render2d.GetAlphaMultiplier()
		return fragment_state.alpha_multiplier
	end

	utility.MakePushPopFunction(render2d, "AlphaMultiplier", 1)

	function render2d.SetTexture(tex)
		textures.texture = tex
		-- Register texture with the pipeline BEFORE sync_pipeline_state is called.
		-- This ensures the descriptor set includes the texture when it's bound.
		local pipeline = render2d.GetActivePipeline()

		if pipeline and tex then
			pipeline:GetTextureIndex(tex, 1, render.GetSamplerFilterConfig())
		end
	end

	function render2d.GetTexture()
		return textures.texture
	end

	utility.MakePushPopFunction(render2d, "Texture", 1)

	function render2d.SetSDFTexture(tex)
		textures.sdf_texture = tex

		if tex then
			render2d.GetActivePipeline():GetTextureIndex(tex, 1, render.GetSamplerFilterConfig())
		end

		options.computed_margin_dirty = true
	end

	function render2d.GetSDFTexture()
		return textures.sdf_texture
	end

	utility.MakePushPopFunction(render2d, "SDFTexture", 1)
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

	pipeline_config.blend = next_state
	render2d.MarkPipelineStateDirty()
end

function render2d.SetBlendPreset(mode_name)
	local next_state = get_blend_preset_state(mode_name)
	pipeline_config.blend = next_state
	render2d.MarkPipelineStateDirty()
end

function render2d.GetBlendMode()
	return canonicalize_blend_mode_state(pipeline_config.blend)
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

function render2d.SetDepthMode(mode_name, write)
	mode_name = mode_name or DEFAULT_DEPTH_MODE
	write = not not write

	if mode_name ~= DEFAULT_DEPTH_MODE and not depth_mode_to_compare_op[mode_name] then
		error("Invalid depth mode: " .. tostring(mode_name))
	end

	pipeline_config.depth.mode = mode_name
	pipeline_config.depth.write = write
	constants.depth_mode_id = depth_mode_ids[mode_name]
	constants.depth_write = write and 1 or 0
	render2d.MarkPipelineStateDirty()
end

function render2d.GetDepthMode()
	local state = pipeline_config.depth
	return state.mode, state.write
end

do
	render2d.stencil_level = 0
	render2d._stencil_mask_stack = {}

	function render2d.SetStencilMode(mode_name, ref)
		if ref == nil then ref = pipeline_config.stencil.ref end

		-- Workaround: "greater" with reference 0 doesn't work correctly on some systems.
		-- Since ref=0 and unsigned stencil values, "greater" is equivalent to "not_equal".
		-- Map to test_inverse for reliability.
		if ref == 0 and mode_name == "greater" then mode_name = "test_inverse" end

		local mode = render2d.stencil_modes[mode_name]

		if not mode then error("Invalid stencil mode: " .. tostring(mode_name)) end

		pipeline_config.stencil.mode = mode_name
		pipeline_config.stencil.ref = ref
		constants.stencil_mode_id = stencil_mode_ids[mode_name]
		constants.stencil_ref = ref
		render2d.MarkPipelineStateDirty()
	end

	function render2d.GetStencilMode()
		local state = pipeline_config.stencil
		return state.mode, state.ref
	end

	function render2d.GetStencilReference()
		return pipeline_config.stencil.ref
	end

	function render2d.ClearStencil(val)
		if not render.GetCommandBuffer() then return end

		render2d.FlushBatches("clear_stencil")
		local old_mode, old_ref = render2d.GetStencilMode()
		local old_rect_batch_mode = render2d.GetRectBatchMode()
		local old_batched_rect_draws_enabled = options.batched_rect_draws_enabled
		options.batched_rect_draws_enabled = false
		render2d.SetRectBatchMode("immediate")
		render2d.stencil_level = 0
		render2d.SetStencilMode("write", val or 0)
		local sw, sh = render2d.GetSize()
		render2d.PushWorldMatrix(true)
		render2d.DrawRect(0, 0, sw, sh)
		render2d.PopMatrix()
		render2d.SetRectBatchMode(old_rect_batch_mode)
		options.batched_rect_draws_enabled = old_batched_rect_draws_enabled
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

	if w == 0 or h == 0 then
		local screen_w, screen_h = render2d.GetSize()
		c = math.max(screen_w or 0, 0)
		u = math.max(screen_h or 0, 0)
		w = 1
		h = 1
	end

	cmd:SetScissor(x, y, w, h)
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
	local scissor = pipeline_config.scissor
	scissor.x, scissor.y, scissor.w, scissor.h = x, y, w, h
	local constants_scissor = constants.scissor
	constants_scissor[0], constants_scissor[1], constants_scissor[2], constants_scissor[3] = x, y, w, h
	apply_scissor_to_command_buffer(x, y, w, h)
	next_batch_rect_version()
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
		math.ceil(max_x) - math.floor(min_x),
		math.ceil(max_y) - math.floor(min_y)
	end

	local function draw_clip_mask(entry)
		local saved_state = render2d.CaptureRectDrawState()
		render2d.SetWorldMatrix(entry.world_matrix)
		render2d.SetTexture()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetAlphaMultiplier(1)
		render2d.SetColorUV()
		render2d.SetSDFSampleUVMode("transformed")
		render2d.SetSwizzleMode("none")
		render2d.SetBorderRadius(0, 0, 0, 0)
		render2d.SetOutlineWidth(0)
		render2d.ClearNinePatch()

		if entry.kind == "stencil_rect" then
			render2d.DrawRectf(entry.x, entry.y, entry.w, entry.h)
		elseif entry.kind == "stencil_rounded_rect" then
			render2d.PushBorderRadius(entry.tl, entry.tr, entry.br, entry.bl)
			render2d.DrawRectf(entry.x, entry.y, entry.w, entry.h)
			render2d.PopBorderRadius()
		elseif entry.kind == "stencil_shape" then
			entry.draw_callback()
		else
			render2d.RestoreRectDrawState(saved_state)
			error("unknown clip kind: " .. tostring(entry.kind), 2)
		end

		render2d.RestoreRectDrawState(saved_state)
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
	local rect_size = fragment_state.rect_size
	rect_size.w = w or 0
	rect_size.h = h or 0
	rect_size.lw = lw or w or 0
	rect_size.lh = lh or h or 0
	local pipeline = render2d.GetActivePipeline()

	if pipeline then pipeline:UploadConstants() end
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

		if mesh_state.last_cmd ~= cmd or mesh_state.last_bound ~= mesh then
			mesh:Bind(cmd, 0)
			mesh_state.last_bound = mesh
			mesh_state.last_cmd = cmd
		end

		return true
	end

	function render2d.BindMesh(mesh)
		render2d.FlushBatches("bind_mesh")
		return bind_mesh_immediate(mesh)
	end
end

do -- uv
	function render2d.SetSDFUV(x, y, w, h)
		x = x or 0
		y = y or 0
		w = w or 1
		h = h or 1
		local offset = constants.sdf_uv_offset
		local scale = constants.sdf_uv_scale
		offset[0] = x
		offset[1] = y
		scale[0] = w - x
		scale[1] = h - y
		local s = fragment_state.sdf_uv
		s.x, s.y, s.w, s.h = x, y, w, h
	end

	function render2d.GetSDFUV()
		local s = fragment_state.sdf_uv
		return s.x, s.y, s.w, s.h
	end

	function render2d.GetSDFUVTransformed()
		return constants.sdf_uv_offset[0],
		constants.sdf_uv_offset[1],
		constants.sdf_uv_scale[0],
		constants.sdf_uv_scale[1]
	end

	utility.MakePushPopFunction(render2d, "SDFUV", 4)

	function render2d.SetColorUV(x, y, w, h, rot)
		x = x or 0
		y = y or 0
		w = w or 1
		h = h or 1
		rot = rot or 0
		local offset = constants.color_uv_offset
		local scale = constants.color_uv_scale
		offset[0] = x
		offset[1] = y
		scale[0] = w - x
		scale[1] = h - y
		constants.color_uv_rotation = rot
		local s = fragment_state.color_uv
		s.x, s.y, s.w, s.h, s.r = x, y, w, h, rot
	end

	function render2d.GetColorUV()
		local s = fragment_state.color_uv
		return s.x, s.y, s.w, s.h, s.r
	end

	function render2d.GetColorUVTransformed()
		return constants.color_uv_offset[0],
		constants.color_uv_offset[1],
		constants.color_uv_scale[0],
		constants.color_uv_scale[1],
		constants.color_uv_rotation
	end

	utility.MakePushPopFunction(render2d, "ColorUV", 5)
end

do -- camera
	function render2d.SetScreenSize(w, h)
		camera_state.viewport.w = w
		camera_state.viewport.h = h
		camera_state.projection:Identity()
		camera_state.projection:Ortho(
			camera_state.viewport.x,
			camera_state.viewport.w,
			camera_state.viewport.y,
			camera_state.viewport.h,
			-16000,
			16000
		)
		camera_state.view:Identity()
		local x, y = camera_state.viewport.w / 2, camera_state.viewport.h / 2
		camera_state.view:Translate(x, y, 0)
		camera_state.view:Rotate(camera_state.view_angle, 0, 0, 1)
		camera_state.view:Translate(-x, -y, 0)
		camera_state.view:Translate(camera_state.view_pos.x, camera_state.view_pos.y, 0)
		camera_state.view:Translate(x, y, 0)
		camera_state.view:Scale(camera_state.view_zoom.x, camera_state.view_zoom.y, 1)
		camera_state.view:Translate(-x, -y, 0)
		camera_state.projection_view = camera_state.view * camera_state.projection
	end

	function render2d.GetScreenSize()
		return camera_state.viewport.w, camera_state.viewport.h
	end

	utility.MakePushPopFunction(render2d, "ScreenSize", 2)

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
			Matrix44.CopyFrom(camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos - 1], mat)
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

local function next_pooled_item(pool, slot_field, factory)
	local slot = batch_runtime[slot_field]
	batch_runtime[slot_field] = slot + 1
	local item = pool[slot]

	if not item then
		item = factory()
		pool[slot] = item
	end

	return item
end

local function new_table()
	return {}
end

function render2d.CaptureRectDrawState(world_matrix)
	local rect_state_snapshot = next_pooled_item(render2d.rect_batch_state_snapshots, "next_rect_draw_state_snapshot_slot", RectDrawState)
	ffi.copy(rect_state_snapshot, constants, constants_size)
	local resolved_world_matrix = world_matrix or Matrix44()
	local blend_mode = pipeline_config.blend

	if not blend_mode then
		blend_mode = get_blend_preset_state(DEFAULT_BLEND_MODE)
		pipeline_config.blend = blend_mode
	end

	Matrix44.CopyFrom(render2d.GetWorldMatrix(), resolved_world_matrix)
	return {
		rect_state_snapshot = rect_state_snapshot,
		world_matrix = resolved_world_matrix,
		texture = textures.texture,
		sdf_texture = textures.sdf_texture,
		blend_mode = blend_mode,
		alpha_multiplier = fragment_state.alpha_multiplier,
	}
end

function render2d.RestoreRectDrawState(state)
	ffi.copy(constants, state.rect_state_snapshot, constants_size)
	fragment_state.alpha_multiplier = state.alpha_multiplier
	textures.texture = state.texture
	textures.sdf_texture = state.sdf_texture
	-- Register textures with the pipeline BEFORE bind_mesh_immediate/sync_pipeline_state
	-- is called, so the descriptor set is updated with the correct textures.
	local pipeline = render2d.GetActivePipeline()

	if pipeline then
		if state.texture then
			pipeline:GetTextureIndex(state.texture, 1, render.GetSamplerFilterConfig())
		end

		if state.sdf_texture then
			pipeline:GetTextureIndex(state.sdf_texture, 1, render.GetSamplerFilterConfig())
		end
	end

	local snapshot = state.rect_state_snapshot
	local scissor = pipeline_config.scissor
	pipeline_config.blend = state.blend_mode
	pipeline_config.depth.mode = depth_mode_names[snapshot.depth_mode_id]
	pipeline_config.depth.write = snapshot.depth_write == 1
	pipeline_config.stencil.mode = stencil_mode_names[snapshot.stencil_mode_id]
	pipeline_config.stencil.ref = snapshot.stencil_ref
	scissor.x, scissor.y, scissor.w, scissor.h = snapshot.scissor[0], snapshot.scissor[1], snapshot.scissor[2], snapshot.scissor[3]
	render2d.MarkPipelineStateDirty()
	apply_scissor_to_command_buffer(snapshot.scissor[0], snapshot.scissor[1], snapshot.scissor[2], snapshot.scissor[3])
	Matrix44.CopyFrom(state.world_matrix, render2d.GetWorldMatrix())
end

do
	function render2d.SetMargin(new_m)
		options.margin_override = new_m
		options.computed_margin_dirty = true
	end

	function render2d.GetMargin()
		if options.margin_override then return options.margin_override end

		if not options.computed_margin_dirty then return options.computed_margin end

		local content_m = math.abs(constants.outline_width)

		if textures.sdf_texture ~= nil or render2d.GetFlagBits("SWIZZLE") == "rrr" then
			content_m = content_m + constants.sdf_softness
		end

		if constants.sdf_softness > 0 or content_m > 0 then
			content_m = math.max(content_m, constants.sdf_softness)
		end

		local m = content_m

		if m > 0 then m = m + 1 end

		options.computed_margin = math.ceil(m)
		options.computed_margin_dirty = false
		return options.computed_margin
	end

	utility.MakePushPopFunction(render2d, "Margin", 1)
end

local function queue_rect_draw(use_float, x, y, w, h, a, ox, oy, max_m)
	local margin = render2d.GetMargin(w, h)

	if max_m then margin = math.min(margin, max_m) end

	constants.sdf_uv_bounds[0] = constants.sdf_uv_offset[0]
	constants.sdf_uv_bounds[1] = constants.sdf_uv_offset[1]
	constants.sdf_uv_bounds[2] = constants.sdf_uv_offset[0] + constants.sdf_uv_scale[0]
	constants.sdf_uv_bounds[3] = constants.sdf_uv_offset[1] + constants.sdf_uv_scale[1]
	local state = render2d.CaptureRectDrawState(
		next_pooled_item(render2d.rect_batch_world_matrices, "next_world_matrix_slot", Matrix44)
	)
	local projected = next_pooled_item(render2d.rect_batch_draw_matrices, "next_draw_matrix_slot", Matrix44)
	local qw = w + margin * 2
	local qh = h + margin * 2
	Matrix44.CopyFrom(state.world_matrix, projected)

	if x and y then
		if a then
			-- margin is applied in local space below so it follows the rotation
			if use_float then
				projected:Translate(x, y, 0)
			else
				projected:Translate(math.ceil(x), math.ceil(y), 0)
			end
		elseif use_float then
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
	else
		if a then
			projected:Rotate(a, 0, 0, 1)

			if use_float then
				projected:Translate(-(ox or 0) - margin, -(oy or 0) - margin, 0)
			else
				projected:Translate(math.ceil(-(ox or 0) - margin), math.ceil(-(oy or 0) - margin), 0)
			end
		elseif ox then
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
	end

	local batch_mode = render2d.GetRectBatchMode()
	local entry = next_pooled_item(render2d.rect_batch_entries, "next_entry_slot", new_table)
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
	entry.draw_matrix = projected
	entry.state = state

	-- the key depends only on draw state and not on rects
	if batch_runtime.rect_key_version ~= batch_runtime.rect_state_version then
		batch_runtime.rect_key_version = batch_runtime.rect_state_version
		batch_runtime.rect_key = rect_key_interner:intern{
			batch_runtime.mode_ids[batch_mode] or
			0,
			state.blend_mode.batch_key,
			state.rect_state_snapshot.nine_patch_x_count,
			state.rect_state_snapshot.nine_patch_y_count,
			state.rect_state_snapshot.nine_patch_x_stretch[0],
			state.rect_state_snapshot.nine_patch_x_stretch[1],
			state.rect_state_snapshot.nine_patch_x_stretch[2],
			state.rect_state_snapshot.nine_patch_x_stretch[3],
			state.rect_state_snapshot.nine_patch_x_stretch[4],
			state.rect_state_snapshot.nine_patch_x_stretch[5],
			state.rect_state_snapshot.nine_patch_y_stretch[0],
			state.rect_state_snapshot.nine_patch_y_stretch[1],
			state.rect_state_snapshot.nine_patch_y_stretch[2],
			state.rect_state_snapshot.nine_patch_y_stretch[3],
			state.rect_state_snapshot.nine_patch_y_stretch[4],
			state.rect_state_snapshot.nine_patch_y_stretch[5],
			state.rect_state_snapshot.depth_mode_id,
			state.rect_state_snapshot.depth_write,
			state.rect_state_snapshot.stencil_mode_id,
			state.rect_state_snapshot.stencil_ref,
			state.rect_state_snapshot.scissor[0],
			state.rect_state_snapshot.scissor[1],
			state.rect_state_snapshot.scissor[2],
			state.rect_state_snapshot.scissor[3],
		}
	end

	local segment = batch_runtime.state.segments[#batch_runtime.state.segments]
	assert(batch_runtime.rect_key ~= nil, "rect batch key hash is required")

	if
		not segment or
		segment.kind ~= "rect" or
		segment.key_hash ~= batch_runtime.rect_key
	then
		segment = {
			kind = "rect",
			key_hash = batch_runtime.rect_key,
			entries = {},
		}
		batch_runtime.state.segments[#batch_runtime.state.segments + 1] = segment
	end

	segment.entries[#segment.entries + 1] = entry
	batch_runtime.state.pending_draws = batch_runtime.state.pending_draws + 1
	return true
end

draw_rect_immediate = function(x, y, w, h, a, ox, oy, margin, use_float)
	local resolved_margin = margin or render2d.GetMargin(w, h)

	if not bind_mesh_immediate(render2d.rect_mesh) then return false end

	local old_off_x, old_off_y = constants.sdf_uv_offset[0], constants.sdf_uv_offset[1]
	local old_scale_x, old_scale_y = constants.sdf_uv_scale[0], constants.sdf_uv_scale[1]
	render2d.PushWorldMatrix()

	if x and y then
		if a then
			-- margin is applied in local space below so it follows the rotation
			if use_float then
				render2d.Translatef(x, y)
			else
				render2d.Translate(x, y)
			end
		elseif use_float then
			render2d.Translatef(x - resolved_margin, y - resolved_margin)
		else
			render2d.Translate(x - resolved_margin, y - resolved_margin)
		end
	end

	if a then
		render2d.Rotate(a)

		if use_float then
			render2d.Translatef(-(ox or 0) - resolved_margin, -(oy or 0) - resolved_margin)
		else
			render2d.Translate(math.ceil(-(ox or 0) - resolved_margin), math.ceil(-(oy or 0) - resolved_margin))
		end
	elseif ox then
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
		constants.sdf_uv_scale[0] = old_scale_x * (qw / w)
		constants.sdf_uv_scale[1] = old_scale_y * (qh / h)
		constants.sdf_uv_offset[0] = old_off_x - (resolved_margin / w) * old_scale_x
		constants.sdf_uv_offset[1] = old_off_y - (resolved_margin / h) * old_scale_y
	end

	constants.sdf_uv_bounds[0] = old_off_x
	constants.sdf_uv_bounds[1] = old_off_y
	constants.sdf_uv_bounds[2] = old_off_x + old_scale_x
	constants.sdf_uv_bounds[3] = old_off_y + old_scale_y
	render2d.UploadConstants(qw, qh, w, h)
	render2d.rect_mesh:DrawIndexed(render.GetCommandBuffer(), 6)
	constants.sdf_uv_offset[0], constants.sdf_uv_offset[1] = old_off_x, old_off_y
	constants.sdf_uv_scale[0], constants.sdf_uv_scale[1] = old_scale_x, old_scale_y
	render2d.PopMatrix()
	return true
end

local function draw_rect(use_float, x, y, w, h, a, ox, oy, max_m)
	local batch_state = batch_runtime.state

	if
		options.batched_rect_draws_enabled and
		not batch_state.is_flushing and
		render.GetCommandBuffer() ~= nil and
		render2d.GetRectBatchMode() ~= "immediate" and
		not render2d.shader_override
	then
		return queue_rect_draw(use_float, x, y, w, h, a, ox, oy, max_m)
	end

	return draw_rect_immediate(x, y, w, h, a, ox, oy, nil, use_float)
end

function render2d.DrawRect(x, y, w, h, a, ox, oy, max_m)
	return draw_rect(false, x, y, w, h, a, ox, oy, max_m)
end

function render2d.DrawRectf(x, y, w, h, a, ox, oy, max_m)
	return draw_rect(true, x, y, w, h, a, ox, oy, max_m)
end

function render2d.BindPipeline(force)
	sync_pipeline_state(force)
	-- Reset mesh binding cache since command buffer state was reset
	mesh_state.last_bound = nil
end

function render2d.GetActivePipeline()
	return render2d.shader_override or render2d.pipeline
end

render.RegisterFlushCallback("render2d", function(reason)
	if reason == "begin_frame" then
		reset_rect_batch_instance_frame_state()
		render2d.batch_counters = reset_batch_counters(render2d.batch_counters)
	end

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

event.AddListener("PostDraw", "render2d", function(dt)
	if not render2d.pipeline then return end -- not 2d initialized
	render2d.BindPipeline()
	event.Call("PreDraw2D", dt)
	event.Call("Draw2D", dt)
	render2d.FlushBatches("PostDraw")
end)

event.AddListener("WindowFramebufferResized", "render2d", function(wnd, size)
	if render.target:IsValid() and render.target.config.offscreen then return end

	render2d.SetScreenSize(size.x, size.y)
end)

if HOTRELOAD then
	HOTRELOAD = nil
	render2d.pipeline = nil
	render2d.Initialize()
end

return render2d
