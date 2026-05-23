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
	{"uv_offset", "vec2"},
	{"uv_scale", "vec2"},
	{"flags", "int"},
	{"gradient_texture_index", "int"},
}
local fragment_shape_constant_fields = {
	{"blur", "vec2"},
	{"border_radius", "vec4"},
	{"outline_width", "float"},
	{"rect_size", "vec2"},
	{"sdf_threshold", "float"},
	{"sdf_texel_range", "float"},
	{"sdf_rect_size", "vec2"},
}
local fragment_patch_constant_fields = {
	{"nine_patch_x_count", "int"},
	{"nine_patch_y_count", "int"},
	{"nine_patch_x_stretch", "float", nil, 6},
	{"nine_patch_y_stretch", "float", nil, 6},
}
local fragment_constant_fields = append_fields(
	append_fields(fragment_draw_constant_fields, fragment_shape_constant_fields),
	fragment_patch_constant_fields
)
local rect_draw_state_tail_fields = {
	{"disable_rect_sdf", "int"},
	{"depth_mode_id", "int"},
	{"depth_write", "int"},
	{"stencil_mode_id", "int"},
	{"stencil_ref", "int"},
	{"scissor", "int", nil, 4},
}
local RectDrawState = EasyPipeline.BuildFFIType(
	"scalar",
	"Render2DRectDrawState",
	append_fields(fragment_constant_fields, rect_draw_state_tail_fields)
)
local render2d = library()
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
}
local stencil_mode_names = {
	[1] = "none",
	[2] = "write",
	[3] = "mask_write",
	[4] = "mask_test",
	[5] = "mask_decrement",
	[6] = "test",
	[7] = "test_inverse",
}
local bind_mesh_immediate
local capture_rect_draw_state
local restore_rect_draw_state
local flush_rect_batch_queue
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
			alpha_multiplier = 1,
		},
		textures = {
			texture = nil,
			gradient_texture = nil,
		},
		pipeline = {
			blend = nil,
			depth = {mode = DEFAULT_DEPTH_MODE, write = false},
			stencil = {mode = "none", ref = 1},
			scissor = {x = 0, y = 0, w = 0, h = 0},
		},
		options = {
			disable_rect_sdf = false,
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

local function reset_rect_batch_matrix_pool_state()
	render2d.state.runtime.batch.next_entry_slot = 1
	render2d.state.runtime.batch.next_world_matrix_slot = 1
	render2d.state.runtime.batch.next_draw_matrix_slot = 1
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

utility.MakePushPopFunction(render2d, "RectBatchMode")

local function get_active_pipeline()
	return render2d.shader_override or render2d.pipeline
end

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
			vertex.batch_rect_geometry[2] = rect_state_snapshot.disable_rect_sdf == 1 and 0 or entry.w
			vertex.batch_rect_geometry[3] = rect_state_snapshot.disable_rect_sdf == 1 and 0 or entry.h
		end,
		fragment_values = {
			{"shape.rect_size", "batch_rect_size", "in_batch_rect_geometry.xy"},
			{"shape.sdf_rect_size", "batch_sdf_rect_size", "in_batch_rect_geometry.zw"},
		},
	},
	{
		name = "batch_material_state",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		write = function(vertex, entry, state, rect_state_snapshot)
			vertex.batch_material_state[0] = rect_state_snapshot.sdf_threshold
			vertex.batch_material_state[1] = rect_state_snapshot.sdf_texel_range
			vertex.batch_material_state[2] = state.texture and
				render2d.rect_batch_pipeline:GetTextureIndex(state.texture) or
				-1
			vertex.batch_material_state[3] = state.gradient_texture and
				render2d.rect_batch_pipeline:GetTextureIndex(state.gradient_texture) or
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
			{
				"draw.gradient_texture_index",
				{"int", "batch_gradient_texture_index"},
				"int(round(in_batch_material_state.w))",
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

function render2d.FlushBatches(reason)
	local batch_state = render2d.state.runtime.batch.state

	if not batch_state:BeginFlush(reason) then return false end

	if not flush_rect_batch_queue then
		batch_state:AbortFlush()
		error(
			"render2d has pending batched draws but batch submission is not implemented yet",
			2
		)
	end

	return flush_rect_batch_queue()
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

local function mark_pipeline_state_dirty()
	render2d.state.runtime.pipeline_state.dirty = true
end

local function sync_pipeline_state(force)
	local pipeline = get_active_pipeline()

	if not pipeline then return end

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
	local stencil_ref = stencil_state.ref or 1
	local stencil_mode = render2d.stencil_modes[stencil_mode_name]
	local depth_compare_op = depth_mode_to_compare_op[depth_mode_name] or "always"
	local cmd = render.GetCommandBuffer()

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

local function write_render2d_vertex_push_constants(self, block)
	--render2d.GetMatrix():CopyToFloatPointer(block.projection_view_world)
	block.projection_view_world = ffi.cast(block.projection_view_world, render2d.GetMatrix():GetFloatPointer())
end

local function get_render2d_fragment_constants_source()
	return render2d.state.render.fragment.constants
end

local function write_render2d_fragment_draw_constants(self, block)
	block.global_color[3] = block.global_color[3] * render2d.state.render.fragment.alpha_multiplier
	block.texture_index = render2d.state.render.textures.texture and
		self:GetTextureIndex(render2d.state.render.textures.texture) or
		-1
	block.gradient_texture_index = render2d.state.render.textures.gradient_texture and
		self:GetTextureIndex(render2d.state.render.textures.gradient_texture) or
		-1
	return block
end

local function write_render2d_fragment_shape_constants(self, block)
	block.rect_size[0] = render2d.state.render.fragment.rect_size.w
	block.rect_size[1] = render2d.state.render.fragment.rect_size.h
	block.sdf_rect_size[0] = render2d.state.render.fragment.rect_size.lw
	block.sdf_rect_size[1] = render2d.state.render.fragment.rect_size.lh
	return block
end

local function write_render2d_fragment_patch_constants(self, block)
	return block
end

-- Blend mode presets
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
		src_alpha_blend_factor = "one",
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
					write = write_render2d_vertex_push_constants,
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
					write = write_render2d_fragment_draw_constants,
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
					write = write_render2d_fragment_shape_constants,
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
					write = write_render2d_fragment_patch_constants,
				},
			},
			shader = render2d.BuildShaderFlags("draw.flags") .. "\n" .. [[
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

				float sd_rect(vec2 coords, vec2 quad_size, vec2 logical_size, vec4 radius) {
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

				float sample_tex_sdf_raw(int texture_index, vec2 sdf_uv) {
					return texture(TEXTURE(texture_index), sdf_uv).r;
				}

				float tex_sdf_screen_px_range(int texture_index, vec2 sdf_uv, float sdf_texel_range) {
					vec2 tex_size = vec2(textureSize(TEXTURE(texture_index), 0));
					vec2 uv_dx = dFdx(sdf_uv);
					vec2 uv_dy = dFdy(sdf_uv);
					vec2 screen_tex_size = vec2(1.0) / max(abs(uv_dx) + abs(uv_dy), vec2(0.0001));
					vec2 unit_range = vec2(max(sdf_texel_range, 1.0)) / max(tex_size, vec2(1.0));
					return max(0.5 * dot(unit_range, screen_tex_size)*1.5, 1.0);
				}

				float sample_tex_sdf_filtered(int texture_index, vec2 sdf_uv) {
					vec2 uv_dx = dFdx(sdf_uv);
					vec2 uv_dy = dFdy(sdf_uv);
					float center = sample_tex_sdf_raw(texture_index, sdf_uv);
					float sx0 = sample_tex_sdf_raw(texture_index, sdf_uv - uv_dx * 0.25);
					float sx1 = sample_tex_sdf_raw(texture_index, sdf_uv + uv_dx * 0.25);
					float sy0 = sample_tex_sdf_raw(texture_index, sdf_uv - uv_dy * 0.25);
					float sy1 = sample_tex_sdf_raw(texture_index, sdf_uv + uv_dy * 0.25);
					return center * 0.7 + (sx0 + sx1 + sy0 + sy1) * 0.075;
				}

				float tex_sdf_distance(int texture_index, float sdf_threshold, float sdf_texel_range, vec2 sdf_uv) {
					float dist = sample_tex_sdf_filtered(texture_index, sdf_uv);
					return (sdf_threshold - dist) * tex_sdf_screen_px_range(texture_index, sdf_uv, sdf_texel_range);
				}

				bool has_rect_sdf_enabled() {
					return shape.sdf_rect_size.x > 0.0 && shape.sdf_rect_size.y > 0.0;
				}

				#define FLAGS_SDF_ENABLED  (FLAGS_SWIZZLE == 10)

				bool has_texture_sdf_enabled() {
					return draw.texture_index >= 0 && FLAGS_SDF_ENABLED;
				}

				vec4 apply_swizzle(vec4 tex) {
					if (FLAGS_SWIZZLE == 1) return vec4(tex.rrr, 1.0);
					if (FLAGS_SWIZZLE == 2) return vec4(tex.ggg, 1.0);
					if (FLAGS_SWIZZLE == 3) return vec4(tex.bbb, 1.0);
					if (FLAGS_SWIZZLE == 4) return vec4(tex.aaa, 1.0);
					if (FLAGS_SWIZZLE == 5) return vec4(tex.rgb, 1.0);
					return tex;
				}

				vec2 resolve_fragment_uv(vec2 coords) {
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

					return uv;
				}

				vec4 sample_fragment_color(vec2 uv, bool is_sdf_tex) {
					vec4 color = in_color * draw.global_color;

					if (draw.texture_index >= 0 && !is_sdf_tex) {
						vec4 tex = texture(TEXTURE(draw.texture_index), uv * draw.uv_scale + draw.uv_offset);
						color *= apply_swizzle(tex);
					}

					return color;
				}

				float compute_fragment_distance(vec2 coords, vec2 uv, bool has_rect_sdf, bool has_tex_sdf) {
					float d = 1e10;

					if (has_rect_sdf) {
						d = sd_rect(coords, shape.rect_size, shape.sdf_rect_size, shape.border_radius);
					}

					if (has_tex_sdf) {
						bool use_direct_sample_uv = (FLAGS_SAMPLE_UV & 1) != 0;
						bool invert_tex_sdf = (FLAGS_SAMPLE_UV & 2) != 0;
						vec2 sdf_uv = use_direct_sample_uv ? in_sample_uv : (in_sample_uv * draw.uv_scale + draw.uv_offset);
						float d_tex = tex_sdf_distance(draw.texture_index, shape.sdf_threshold, shape.sdf_texel_range, sdf_uv);

						if (invert_tex_sdf) d_tex = -d_tex;

						d = has_rect_sdf ? max(d, d_tex) : d_tex;
					}

					return d;
				}

				vec4 apply_fragment_gradient(vec2 coords, vec4 color) {
					if (draw.gradient_texture_index >= 0) {
						float gy = coords.y;

						if (shape.sdf_rect_size.y > 0.0) {
							gy = (coords.y - 0.5) * (shape.rect_size.y / shape.sdf_rect_size.y) + 0.5;
						}

						gy = clamp(gy, 0.0, 1.0);
						color *= texture(TEXTURE(draw.gradient_texture_index), vec2(gy, 0.5));
					}

					return color;
				}

				float compute_sdf_alpha(float d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(shape.blur.x, shape.blur.y) * 1.75);
						float alpha = (shape.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + shape.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, 0.0), gamma);
					}

					float smoothing = max(shape.blur.x, shape.blur.y);
					smoothing = max(0.75, smoothing);
					return (shape.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + shape.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				vec3 compute_sdf_alpha(vec3 d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(shape.blur.x, shape.blur.y) * 1.75);
						vec3 alpha = (shape.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + shape.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, vec3(0.0)), vec3(gamma));
					}

					float smoothing = max(shape.blur.x, shape.blur.y);
					smoothing = max(0.7, smoothing);
					return (shape.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + shape.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				float compute_blur_alpha(vec2 coords) {
					vec2 p = (coords - 0.5) * shape.rect_size;
					vec2 b = max(vec2(0.0), (shape.rect_size - shape.blur * 2.0) * 0.5);
					vec2 q = abs(p) - b;
					float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
					float max_blur = max(shape.blur.x, shape.blur.y);
					return smoothstep(max_blur, 0.0, dist);
				}

				vec4 shade_fragment(vec2 coords, out vec4 color, out float d) {
					bool has_rect_sdf = has_rect_sdf_enabled();
					bool has_tex_sdf = has_texture_sdf_enabled();
					bool has_sdf = has_rect_sdf || has_tex_sdf;
					vec2 uv = resolve_fragment_uv(coords);
					color = sample_fragment_color(uv, has_tex_sdf);
					d = compute_fragment_distance(coords, uv, has_rect_sdf, has_tex_sdf);
					vec4 shaded = color;

					if (has_sdf) {
						shaded = apply_fragment_gradient(coords, color);
						shaded.a *= compute_sdf_alpha(d, has_tex_sdf, has_rect_sdf);
					}

					if ((shape.blur.x > 0.0 || shape.blur.y > 0.0) && shape.sdf_rect_size.x <= 0.0) {
						shaded.a *= compute_blur_alpha(coords);
					}

					return shaded;
				}

				void main() 
				{
					vec4 color;
					float d;
					out_color = shade_fragment(in_uv, color, d);

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
	render2d.triangle_mesh = render2d.CreateMesh{
		{
			pos = Vec3(-0.5, -0.5, 0),
			uv = Vec2(0, 0),
			sample_uv = Vec2(0, 0),
			color = Color(1, 1, 1, 1),
		},
		{
			pos = Vec3(0.5, 0.5, 0),
			uv = Vec2(1, 1),
			sample_uv = Vec2(1, 1),
			color = Color(1, 1, 1, 1),
		},
		{
			pos = Vec3(-0.5, 0.5, 0),
			uv = Vec2(0, 1),
			sample_uv = Vec2(0, 1),
			color = Color(1, 1, 1, 1),
		},
	}
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
	render2d.ClearPendingBatches()
	render2d.SetRectBatchMode("instanced")
	reset_rect_batch_instance_frame_state()
	render2d.SetTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetUV()
	render2d.SetSwizzleMode(0)
	render2d.SetBlur(0)
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetOutlineWidth(0)
	constants.flags = 0
	render2d.SetDisableRectSDF(false)
	render2d.SetClampBorderRadius(true)
	constants.sdf_threshold = 0
	constants.sdf_texel_range = 1
	constants.gradient_texture_index = -1
	constants.nine_patch_x_count = 0
	constants.nine_patch_y_count = 0

	for i = 0, 5 do
		constants.nine_patch_x_stretch[i] = 0
		constants.nine_patch_y_stretch[i] = 0
	end

	render2d.SetSDFThreshold(0.5)
	render2d.UpdateScreenSize(render.GetRenderImageSize():Unpack())
	render2d.SetScissor(0, 0, render2d.GetSize())
	render2d.SetBlendPreset("alpha")

	if render2d.SetDepthMode then
		render2d.SetDepthMode(DEFAULT_DEPTH_MODE, false)
	end

	if render2d.SetStencilMode then render2d.SetStencilMode("none") end
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

		utility.MakePushPopFunction(render2d, "Color")
	end

	do
		do -- Flag definitions: single source of truth for all flag fields
			-- Each entry: { name, mask, shift }
			local FLAGS = {
				{name = "SWIZZLE", mask = 0xF, shift = 0},
				{name = "SAMPLE_UV", mask = 0xF, shift = 4},
				{name = "CLAMP_BORDER_RADIUS", mask = 0x1, shift = 8},
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

			utility.MakePushPopFunction(render2d, "SwizzleMode")
		end

		do
			function render2d.SetSampleUVMode(mode)
				render2d.SetSAMPLE_UV(mode or 0)
			end

			function render2d.GetSampleUVMode()
				return render2d.GetSAMPLE_UV()
			end

			utility.MakePushPopFunction(render2d, "SampleUVMode")
		end

		do
			-- SDF is a computed flag: swizzle == 10
			function render2d.SetSDFMode(mode)
				if mode then
					local sample_uv = render2d.GetSAMPLE_UV()
					render2d.SetSWIZZLE(10)
					render2d.SetSAMPLE_UV(sample_uv)
					render2d.state.render.options.computed_margin_dirty = true
				elseif render2d.GetSWIZZLE() == 10 then
					render2d.SetSWIZZLE(0)
					render2d.state.render.options.computed_margin_dirty = true
				end
			end

			function render2d.GetSDFMode()
				return render2d.GetSWIZZLE() == 10 and 1 or 0
			end

			utility.MakePushPopFunction(render2d, "SDFMode")
		end

		do
			function render2d.SetSDFThreshold(threshold)
				render2d.state.render.fragment.constants.sdf_threshold = threshold
			end

			function render2d.GetSDFThreshold()
				return render2d.state.render.fragment.constants.sdf_threshold
			end

			utility.MakePushPopFunction(render2d, "SDFThreshold")

			function render2d.SetSDFTexelRange(range)
				render2d.state.render.fragment.constants.sdf_texel_range = range or 1
			end

			function render2d.GetSDFTexelRange()
				return render2d.state.render.fragment.constants.sdf_texel_range
			end

			utility.MakePushPopFunction(render2d, "SDFTexelRange")

			function render2d.SetDisableRectSDF(enabled)
				local normalized = enabled == true
				render2d.state.render.options.disable_rect_sdf = normalized
				render2d.state.render.fragment.constants.disable_rect_sdf = normalized and 1 or 0
			end

			function render2d.GetDisableRectSDF()
				return render2d.state.render.options.disable_rect_sdf
			end

			utility.MakePushPopFunction(render2d, "DisableRectSDF")
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

			utility.MakePushPopFunction(render2d, "ClampBorderRadius")
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

			utility.MakePushPopFunction(render2d, "Blur")
		end

		do
			function render2d.SetSDFGradientTexture(tex)
				render2d.state.render.textures.gradient_texture = tex
			end

			function render2d.GetSDFGradientTexture()
				return render2d.state.render.textures.gradient_texture
			end

			utility.MakePushPopFunction(render2d, "SDFGradientTexture")
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

		utility.MakePushPopFunction(render2d, "BorderRadius")
	end

	do
		function render2d.SetOutlineWidth(width)
			render2d.state.render.fragment.constants.outline_width = width or 0
			render2d.state.render.options.computed_margin_dirty = true
		end

		function render2d.GetOutlineWidth()
			return render2d.state.render.fragment.constants.outline_width
		end

		utility.MakePushPopFunction(render2d, "OutlineWidth")
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

		utility.MakePushPopFunction(render2d, "AlphaMultiplier")
	end

	do
		function render2d.SetTexture(tex)
			render2d.state.render.textures.texture = tex
		end

		function render2d.GetTexture()
			return render2d.state.render.textures.texture
		end

		utility.MakePushPopFunction(render2d, "Texture")
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
		mark_pipeline_state_dirty()
	end

	function render2d.SetBlendPreset(mode_name)
		local next_state = get_blend_preset_state(mode_name)
		render2d.state.render.pipeline.blend = next_state
		mark_pipeline_state_dirty()
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

	function render2d.CreateGradient(config)
		local width = config.width or 256
		local height = config.height or 1
		local mode = config.mode or "linear"
		local stops = config.stops or {}

		for i, stop in ipairs(stops) do
			stop.pos = stop.pos or i - 1
		end

		local tex = Texture.New{
			width = width,
			height = height,
			name = string.format("render2d %s gradient %dx%d", mode, width, height),
			format = "r8g8b8a8_unorm",
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		local glsl

		if mode == "linear" then
			local angle = config.angle or 0 -- degrees
			local rad = math.rad(angle)
			local s, c = math.sin(rad), math.cos(rad)
			glsl = [[
				vec2 dir = vec2(]] .. s .. [[, ]] .. -c .. [[);
				float t = dot(uv - 0.5, dir) + 0.5;
			]]
		elseif mode == "radial" then
			glsl = [[
				float t = distance(uv, vec2(0.5)) * 2.0;
			]]
		end

		-- Build the color ramp from stops
		-- stops = { {pos=0, color=Color(1,0,0,1)}, {pos=1, color=Color(0,0,1,1)} }
		table.sort(stops, function(a, b)
			return a.pos < b.pos
		end)

		local ramp = ""

		if #stops == 0 then
			ramp = "return vec4(1.0);"
		elseif #stops == 1 then
			local c = stops[1].color
			ramp = "return vec4(" .. c.r .. "," .. c.g .. "," .. c.b .. "," .. c.a .. ");"
		else
			ramp = "vec4 res = vec4(0.0);\n"

			for i = 1, #stops - 1 do
				local s1 = stops[i]
				local s2 = stops[i + 1]
				local cond = (i == 1) and "t <= " .. s2.pos or "t > " .. s1.pos .. " && t <= " .. s2.pos

				if i == #stops - 1 then cond = "t > " .. s1.pos end

				ramp = ramp .. "if (" .. cond .. ") {\n"
				ramp = ramp .. "  float fac = clamp((t - " .. s1.pos .. ") / (" .. s2.pos .. " - " .. s1.pos .. "), 0.0, 1.0);\n"
				ramp = ramp .. "  res = mix(vec4(" .. s1.color.r .. "," .. s1.color.g .. "," .. s1.color.b .. "," .. s1.color.a .. "), vec4(" .. s2.color.r .. "," .. s2.color.g .. "," .. s2.color.b .. "," .. s2.color.a .. "), fac);\n"
				ramp = ramp .. "}\n"
			end

			ramp = ramp .. "return res;"
		end

		tex:Shade(glsl .. "\n" .. ramp)
		return tex
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
			mark_pipeline_state_dirty()
		end

		function render2d.GetDepthMode()
			local state = render2d.state.render.pipeline.depth
			return state.mode, state.write
		end
	end

	do
		render2d.stencil_level = 0

		function render2d.SetStencilMode(mode_name, ref)
			ref = ref or render2d.state.render.pipeline.stencil.ref
			local mode = render2d.stencil_modes[mode_name]

			if not mode then error("Invalid stencil mode: " .. tostring(mode_name)) end

			render2d.state.render.pipeline.stencil.mode = mode_name
			render2d.state.render.pipeline.stencil.ref = ref
			render2d.state.render.fragment.constants.stencil_mode_id = stencil_mode_ids[mode_name]
			render2d.state.render.fragment.constants.stencil_ref = ref
			mark_pipeline_state_dirty()
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
			render2d.PushStencilMode("mask_write", render2d.stencil_level)
			render2d.stencil_level = render2d.stencil_level + 1
		end

		function render2d.BeginStencilTest()
			render2d.SetStencilMode("mask_test", render2d.stencil_level)
		end

		function render2d.PopStencilMask()
			render2d.PopStencilMode()
			render2d.stencil_level = render2d.stencil_level - 1
		end

		utility.MakePushPopFunction(render2d, "StencilMode")
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
		local use_scissor_clip_rect_fast_path = not OSX

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
			render2d.SetSDFGradientTexture()
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetAlphaMultiplier(1)
			render2d.SetUV()
			render2d.SetSampleUVMode(0)
			render2d.SetSwizzleMode(0)
			render2d.SetSDFMode(false)
			render2d.SetSDFThreshold(0.5)
			render2d.SetSDFTexelRange(1)
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
		local pipeline = get_active_pipeline()

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
			local y = -y - h
			-- Set UV offset and scale
			constants.uv_offset[0] = x / sx
			constants.uv_offset[1] = y / sy
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

	function render2d.GetUVTransform()
		local constants = render2d.state.render.fragment.constants
		return constants.uv_offset[0],
		constants.uv_offset[1],
		constants.uv_scale[0],
		constants.uv_scale[1]
	end

	function render2d.SetSampleUVMode(mode)
		render2d.SetSAMPLE_UV(mode or 0)
	end

	function render2d.GetSampleUVMode()
		return render2d.GetSAMPLE_UV()
	end

	function render2d.SetUV2(u1, v1, u2, v2)
		-- Calculate offset and scale from UV coordinates
		local constants = render2d.state.render.fragment.constants
		constants.uv_offset[0] = u1
		constants.uv_offset[1] = v1
		constants.uv_scale[0] = u2 - u1
		constants.uv_scale[1] = v2 - v1
	end

	utility.MakePushPopFunction(render2d, "UV")
	utility.MakePushPopFunction(render2d, "SampleUVMode")
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

	function render2d.UpdateScreenSize(w, h)
		camera_state.viewport.w = w
		camera_state.viewport.h = h
		update_projection()
		update_view()
	end

	function render2d.GetMatrix()
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:GetMultiplied(camera_state.projection_view, camera_state.projection_view_world)
		return camera_state.projection_view_world
	end

	function render2d.GetProjectionViewMatrix()
		return camera_state.projection_view
	end

	function render2d.GetSize()
		return camera_state.viewport.w, camera_state.viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Translate(ceil(x), ceil(y), z or 0)
		end

		function render2d.Scale(w, h, z)
			camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Scale(ceil(w), ceil(h or w), z or 1)
		end
	end

	function render2d.Translatef(x, y, z)
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Translate(x, y, z or 0)
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

	function render2d.LoadIdentity()
		camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos]:Identity()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
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

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
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
	local rect_state_snapshot = RectDrawState()
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
		gradient_texture = render2d.state.render.textures.gradient_texture,
		blend_mode = blend_mode,
		pipeline_state_id = render2d.state.runtime.ids.current.rect_batch_pipeline,
	}
end
restore_rect_draw_state = function(state)
	ffi.copy(
		render2d.state.render.fragment.constants,
		state.rect_state_snapshot,
		render2d.state.render.fragment.constants_size
	)
	render2d.state.render.textures.texture = state.texture
	render2d.state.render.textures.gradient_texture = state.gradient_texture
	render2d.state.render.pipeline.blend = state.blend_mode
	render2d.state.render.pipeline.depth.mode = depth_mode_names[state.rect_state_snapshot.depth_mode_id]
	render2d.state.render.pipeline.depth.write = state.rect_state_snapshot.depth_write == 1
	render2d.state.render.pipeline.stencil.mode = stencil_mode_names[state.rect_state_snapshot.stencil_mode_id]
	render2d.state.render.pipeline.stencil.ref = state.rect_state_snapshot.stencil_ref
	render2d.state.render.options.disable_rect_sdf = state.rect_state_snapshot.disable_rect_sdf == 1
	render2d.state.render.pipeline.scissor.x = state.rect_state_snapshot.scissor[0]
	render2d.state.render.pipeline.scissor.y = state.rect_state_snapshot.scissor[1]
	render2d.state.render.pipeline.scissor.w = state.rect_state_snapshot.scissor[2]
	render2d.state.render.pipeline.scissor.h = state.rect_state_snapshot.scissor[3]
	mark_pipeline_state_dirty()
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
		local content_m = constants.outline_width
		local swizzle = bit.band(constants.flags, 0xF)

		if swizzle == 10 or swizzle == 1 then
			content_m = content_m + math.max(constants.blur[0], constants.blur[1])
		end

		if constants.blur[0] > 0 or constants.blur[1] > 0 then
			content_m = math.max(content_m, constants.blur[0], constants.blur[1])
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

flush_rect_batch_queue = function()
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

do
	function render2d.DrawTriangle(x, y, w, h, a)
		render2d.BindMesh(render2d.triangle_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if w and h then render2d.Scale(w, h) end

		local cmd = render.GetCommandBuffer()
		render2d.UploadConstants(w, h)
		render2d.triangle_mesh:Draw(cmd, 3)
		render2d.PopMatrix()
	end
end

function render2d.BindPipeline()
	sync_pipeline_state(true)
	-- Reset mesh binding cache since command buffer state was reset
	render2d.state.runtime.mesh.last_bound = nil
end

function render2d.GetActivePipeline()
	return get_active_pipeline()
end

render2d.SetColor(1, 1, 1, 1)
render2d.SetAlphaMultiplier(1)
render2d.SetSwizzleMode(0)
render2d.state.render.pipeline.blend = get_blend_preset_state("alpha")
render2d.state.runtime.pipeline_state.dirty = true

render.RegisterFlushCallback("render2d", function(reason)
	if reason == "begin_frame" then reset_rect_batch_instance_frame_state() end

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

	render2d.UpdateScreenSize(size.x, size.y)
end)

if HOTRELOAD then
	render2d.pipeline = nil
	render2d.Initialize()
end

return render2d
