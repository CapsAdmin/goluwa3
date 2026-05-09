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
local RectDrawState = ffi.typeof([[
	struct {
        float global_color[4];          
        float alpha_multiplier;  
        int texture_index;       
        float uv_offset[2];             
        float uv_scale[2];              
        int flags;
        float blur[2];
        float border_radius[4];
        float outline_width;
        float rect_size[2];
        float sdf_threshold;
		float sdf_texel_range;
        int gradient_texture_index;
        int nine_patch_x_count;
        int nine_patch_y_count;
        float nine_patch_x_stretch[6];
        float nine_patch_y_stretch[6];
        float sdf_rect_size[2];
	}
]])
local render2d = library()
local DEFAULT_BLEND_MODE = "alpha"
local DEFAULT_COLOR_WRITE_MASK = {"r", "g", "b", "a"}
local DEFAULT_DEPTH_MODE = "none"
local rect_batch_instance_attributes = {
	{"pvw_row_0", "vec4", "r32g32b32a32_sfloat"},
	{"pvw_row_1", "vec4", "r32g32b32a32_sfloat"},
	{"pvw_row_2", "vec4", "r32g32b32a32_sfloat"},
	{"pvw_row_3", "vec4", "r32g32b32a32_sfloat"},
	{"batch_global_color", "vec4", "r32g32b32a32_sfloat"},
	{"batch_uv_transform", "vec4", "r32g32b32a32_sfloat"},
	{"batch_blur_modes", "vec4", "r32g32b32a32_sfloat"},
	{"batch_border_radius", "vec4", "r32g32b32a32_sfloat"},
	{"batch_quad_size", "vec4", "r32g32b32a32_sfloat"},
	{"batch_sdf_texture", "vec4", "r32g32b32a32_sfloat"},
	{"batch_outline_alpha", "vec2", "r32g32_sfloat"},
}
local depth_mode_to_compare_op = {
	less = "less",
	lequal = "less_or_equal",
	equal = "equal",
	gequal = "greater_or_equal",
	greater = "greater",
	notequal = "not_equal",
	always = "always",
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
		},
		ids = {
			nil_value = {},
			roots = {
				fragment_static = {next_id = 1},
				blend = {next_id = 1},
				depth = {next_id = 1},
				stencil = {next_id = 1},
				scissor = {next_id = 1},
				pipeline = {next_id = 1},
				rect_batch_key = {next_id = 1},
			},
			current = {
				fragment_static = 0,
				blend = 0,
				depth = 0,
				stencil = 0,
				scissor = 0,
				rect_batch_pipeline = 0,
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

local function intern_state_id(root, ...)
	local node = root

	for i = 1, select("#", ...) do
		local value = select(i, ...)

		if value == nil then value = render2d.state.runtime.ids.nil_value end

		local next_node = node[value]

		if not next_node then
			next_node = {}
			node[value] = next_node
		end

		node = next_node
	end

	local id = node.id

	if not id then
		id = root.next_id
		root.next_id = id + 1
		node.id = id
	end

	return id
end

local function intern_rect_batch_key_id(
	batch_mode_id,
	pipeline_id,
	fragment_static_state_id,
	blend_mode_state_id,
	depth_state_id,
	stencil_state_id,
	scissor_state_id
)
	local rect_batch_key_roots = render2d.state.runtime.ids.roots.rect_batch_key
	local node = rect_batch_key_roots[batch_mode_id]

	if not node then
		node = {}
		rect_batch_key_roots[batch_mode_id] = node
	end

	local next_node = node[pipeline_id]

	if not next_node then
		next_node = {}
		node[pipeline_id] = next_node
	end

	node = next_node
	next_node = node[fragment_static_state_id]

	if not next_node then
		next_node = {}
		node[fragment_static_state_id] = next_node
	end

	node = next_node
	next_node = node[blend_mode_state_id]

	if not next_node then
		next_node = {}
		node[blend_mode_state_id] = next_node
	end

	node = next_node
	next_node = node[depth_state_id]

	if not next_node then
		next_node = {}
		node[depth_state_id] = next_node
	end

	node = next_node
	next_node = node[stencil_state_id]

	if not next_node then
		next_node = {}
		node[stencil_state_id] = next_node
	end

	node = next_node
	local leaf = node[scissor_state_id]

	if not leaf then
		leaf = rect_batch_key_roots.next_id
		rect_batch_key_roots.next_id = leaf + 1
		node[scissor_state_id] = leaf
	end

	return leaf
end

local function update_fragment_static_state_id()
	local constants = render2d.state.render.fragment.constants
	render2d.state.runtime.ids.current.fragment_static = intern_state_id(
		render2d.state.runtime.ids.roots.fragment_static,
		constants.nine_patch_x_count,
		constants.nine_patch_y_count,
		constants.nine_patch_x_stretch[0],
		constants.nine_patch_x_stretch[1],
		constants.nine_patch_x_stretch[2],
		constants.nine_patch_x_stretch[3],
		constants.nine_patch_x_stretch[4],
		constants.nine_patch_x_stretch[5],
		constants.nine_patch_y_stretch[0],
		constants.nine_patch_y_stretch[1],
		constants.nine_patch_y_stretch[2],
		constants.nine_patch_y_stretch[3],
		constants.nine_patch_y_stretch[4],
		constants.nine_patch_y_stretch[5]
	)
end

local function get_blend_mode_state_id(state)
	return intern_state_id(
		render2d.state.runtime.ids.roots.blend,
		state and state.blend == true,
		state and state.src_color_blend_factor,
		state and state.dst_color_blend_factor,
		state and state.color_blend_op,
		state and state.src_alpha_blend_factor,
		state and state.dst_alpha_blend_factor,
		state and state.alpha_blend_op,
		state and state.color_write_mask and state.color_write_mask[1],
		state and state.color_write_mask and state.color_write_mask[2],
		state and state.color_write_mask and state.color_write_mask[3],
		state and state.color_write_mask and state.color_write_mask[4]
	)
end

local function update_blend_mode_state_id(state)
	render2d.state.runtime.ids.current.blend = get_blend_mode_state_id(state)
end

local function update_depth_state_id(mode_name, write)
	render2d.state.runtime.ids.current.depth = intern_state_id(render2d.state.runtime.ids.roots.depth, mode_name, write == true)
end

local function update_stencil_state_id(mode_name, ref)
	render2d.state.runtime.ids.current.stencil = intern_state_id(render2d.state.runtime.ids.roots.stencil, mode_name, ref)
end

local function update_scissor_state_id(x, y, w, h)
	render2d.state.runtime.ids.current.scissor = intern_state_id(render2d.state.runtime.ids.roots.scissor, x, y, w, h)
end

local function reset_rect_batch_instance_frame_state()
	render2d.state.runtime.frame.next_rect_batch_instance_buffer_slot = 1
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

local function build_rect_draw_matrix(base_world_matrix, x, y, w, h, a, ox, oy, margin, use_float)
	local matrix = Matrix44()
	local projected = Matrix44()
	local qw = w + margin * 2
	local qh = h + margin * 2
	Matrix44.CopyTo(base_world_matrix, matrix)

	if x and y then
		if use_float then
			matrix:Translate(x - margin, y - margin, 0)
		else
			matrix:Translate(math.ceil(x - margin), math.ceil(y - margin), 0)
		end
	end

	if a then matrix:Rotate(a, 0, 0, 1) end

	if ox then
		if use_float then
			matrix:Translate(-ox, -oy, 0)
		else
			matrix:Translate(math.ceil(-ox), math.ceil(-oy), 0)
		end
	end

	if w and h then
		if use_float then
			matrix:Scale(qw, qh, 1)
		else
			matrix:Scale(math.ceil(qw), math.ceil(qh), 1)
		end
	end

	matrix:GetMultiplied(render2d.GetProjectionViewMatrix(), projected)
	return projected, qw, qh
end

local function build_rect_batch_fragment_shader_source(source)
	local shader = [[
		#define batch_global_color in_batch_global_color
		#define batch_uv_offset in_batch_uv_transform.xy
		#define batch_uv_scale in_batch_uv_transform.zw
		#define batch_blur in_batch_blur_modes.xy
		#define batch_border_radius in_batch_border_radius
		#define batch_rect_size in_batch_quad_size.xy
		#define batch_sdf_rect_size in_batch_quad_size.zw
		#define batch_sdf_threshold in_batch_sdf_texture.x
		#define batch_sdf_texel_range in_batch_sdf_texture.y
		#define batch_outline_width in_batch_outline_alpha.x
		#define batch_alpha_multiplier in_batch_outline_alpha.y

		int batch_texture_index() {
			return int(round(in_batch_sdf_texture.z));
		}

		int batch_gradient_texture_index() {
			return int(round(in_batch_sdf_texture.w));
		}

		int batch_flags() {
			return int(round(in_batch_blur_modes.z));
		}
	]] .. source

	for _, replacement in ipairs{
		{"U%.global_color", "batch_global_color"},
		{"U%.alpha_multiplier", "batch_alpha_multiplier"},
		{"U%.texture_index", "batch_texture_index()"},
		{"U%.uv_offset", "batch_uv_offset"},
		{"U%.uv_scale", "batch_uv_scale"},
		{"U%.flags", "batch_flags()"},
		{"U%.blur", "batch_blur"},
		{"U%.border_radius", "batch_border_radius"},
		{"U%.outline_width", "batch_outline_width"},
		{"U%.rect_size", "batch_rect_size"},
		{"U%.sdf_threshold", "batch_sdf_threshold"},
		{"U%.sdf_texel_range", "batch_sdf_texel_range"},
		{"U%.gradient_texture_index", "batch_gradient_texture_index()"},
		{"U%.sdf_rect_size", "batch_sdf_rect_size"},
	} do
		shader = shader:gsub(replacement[1], replacement[2])
	end

	return shader
end

local function build_rect_batch_key(state, w, h, margin, batch_mode)
	local batch_mode_id = render2d.state.runtime.batch.mode_ids[batch_mode] or 0
	return intern_rect_batch_key_id(
		batch_mode_id,
		state.pipeline_state_id,
		state.fragment_static_state_id,
		get_blend_mode_state_id(state.blend_mode),
		state.depth_state_id,
		state.stencil_state_id,
		state.scissor_state_id
	)
end

local function apply_rect_margin_uv(qw, qh, w, h)
	local constants = render2d.state.render.fragment.constants
	local old_off_x, old_off_y = constants.uv_offset[0], constants.uv_offset[1]
	local old_scale_x, old_scale_y = constants.uv_scale[0], constants.uv_scale[1]
	local margin = (qw - w) * 0.5

	if margin > 0 and w > 0 and h > 0 then
		constants.uv_scale[0] = old_scale_x * (qw / w)
		constants.uv_scale[1] = old_scale_y * (qh / h)
		constants.uv_offset[0] = old_off_x - (margin / w) * old_scale_x
		constants.uv_offset[1] = old_off_y - (margin / h) * old_scale_y
	end

	return old_off_x, old_off_y, old_scale_x, old_scale_y
end

local function restore_rect_margin_uv(old_off_x, old_off_y, old_scale_x, old_scale_y)
	local constants = render2d.state.render.fragment.constants
	constants.uv_offset[0], constants.uv_offset[1] = old_off_x, old_off_y
	constants.uv_scale[0], constants.uv_scale[1] = old_scale_x, old_scale_y
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

local function write_rect_batch_instance(vertex, entry)
	local values = entry.draw_matrix:GetFloatCopy()
	local state = entry.state
	local rect_state_snapshot = state.rect_state_snapshot
	local uv_off_x, uv_off_y, uv_scale_x, uv_scale_y = get_rect_batch_instance_uv_transform(entry)
	ffi.copy(vertex.pvw_row_0, values + 0, ffi.sizeof("float") * 4)
	ffi.copy(vertex.pvw_row_1, values + 4, ffi.sizeof("float") * 4)
	ffi.copy(vertex.pvw_row_2, values + 8, ffi.sizeof("float") * 4)
	ffi.copy(vertex.pvw_row_3, values + 12, ffi.sizeof("float") * 4)
	ffi.copy(vertex.batch_global_color, rect_state_snapshot.global_color, ffi.sizeof("float") * 4)
	vertex.batch_uv_transform[0] = uv_off_x
	vertex.batch_uv_transform[1] = uv_off_y
	vertex.batch_uv_transform[2] = uv_scale_x
	vertex.batch_uv_transform[3] = uv_scale_y
	vertex.batch_blur_modes[0] = rect_state_snapshot.blur[0]
	vertex.batch_blur_modes[1] = rect_state_snapshot.blur[1]
	vertex.batch_blur_modes[2] = rect_state_snapshot.flags
	vertex.batch_blur_modes[3] = 0
	ffi.copy(vertex.batch_border_radius, rect_state_snapshot.border_radius, ffi.sizeof("float") * 4)
	vertex.batch_quad_size[0] = entry.qw
	vertex.batch_quad_size[1] = entry.qh
	vertex.batch_quad_size[2] = state.disable_rect_sdf and 0 or entry.w
	vertex.batch_quad_size[3] = state.disable_rect_sdf and 0 or entry.h
	vertex.batch_sdf_texture[0] = rect_state_snapshot.sdf_threshold
	vertex.batch_sdf_texture[1] = rect_state_snapshot.sdf_texel_range
	vertex.batch_sdf_texture[2] = state.texture and
		render2d.rect_batch_pipeline:GetTextureIndex(state.texture) or
		-1
	vertex.batch_sdf_texture[3] = state.gradient_texture and
		render2d.rect_batch_pipeline:GetTextureIndex(state.gradient_texture) or
		-1
	vertex.batch_outline_alpha[0] = rect_state_snapshot.outline_width
	vertex.batch_outline_alpha[1] = rect_state_snapshot.alpha_multiplier
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

local function copy_array(tbl)
	if not tbl then return nil end

	local out = {}

	for i, v in ipairs(tbl) do
		out[i] = v
	end

	return out
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

	return {
		blend = blend == true,
		src_color_blend_factor = state.src_color_blend_factor or "one",
		dst_color_blend_factor = state.dst_color_blend_factor or "zero",
		color_blend_op = state.color_blend_op or "add",
		src_alpha_blend_factor = state.src_alpha_blend_factor or "one",
		dst_alpha_blend_factor = state.dst_alpha_blend_factor or "zero",
		alpha_blend_op = state.alpha_blend_op or "add",
		color_write_mask = copy_array(state.color_write_mask or DEFAULT_COLOR_WRITE_MASK),
	}
end

local function get_blend_preset_state(mode_name)
	mode_name = mode_name or DEFAULT_BLEND_MODE
	local preset = render2d.blend_modes[mode_name]

	if not preset then error(get_valid_blend_preset_error(mode_name), 3) end

	return canonicalize_blend_mode_state(preset)
end

local function apply_blend_mode_state(pipeline, blend_mode, stencil_mode)
	pipeline:SetBlend(blend_mode.blend)
	pipeline:SetSrcColorBlendFactor(blend_mode.src_color_blend_factor)
	pipeline:SetDstColorBlendFactor(blend_mode.dst_color_blend_factor)
	pipeline:SetColorBlendOp(blend_mode.color_blend_op)
	pipeline:SetSrcAlphaBlendFactor(blend_mode.src_alpha_blend_factor)
	pipeline:SetDstAlphaBlendFactor(blend_mode.dst_alpha_blend_factor)
	pipeline:SetAlphaBlendOp(blend_mode.alpha_blend_op)
	pipeline:SetColorWriteMask(stencil_mode.color_write_mask or blend_mode.color_write_mask)
end

local function apply_stencil_state(pipeline, stencil_mode, stencil_ref)
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
	apply_blend_mode_state(pipeline, blend_mode, stencil_mode)
	pipeline:SetDepthTest(depth_mode_name ~= DEFAULT_DEPTH_MODE)
	pipeline:SetDepthWrite(depth_write)
	pipeline:SetDepthCompareOp(depth_compare_op)
	apply_stencil_state(pipeline, stencil_mode, stencil_ref)
	pipeline:Bind(cmd, render.GetCurrentFrame())
	render2d.state.runtime.pipeline_state.dirty = false
	render2d.state.runtime.pipeline_state.synced_pipeline = pipeline
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
		RasterizationSamples = render.target:GetSamples(),
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			push_constants = {
				{
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, block, key)
								render2d.GetMatrix():CopyToFloatPointer(block[key])
							end,
						},
					},
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
					gl_Position = U.projection_view_world * vec4(in_pos, 1.0);
					out_uv = in_uv;
					out_sample_uv = in_sample_uv;
					out_color = in_color;
				}
			]],
		},
		fragment = {
			push_constants = {
				{
					block = {
						{
							"global_color",
							"vec4",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.global_color, 16)
							end,
						},
						{
							"alpha_multiplier",
							"float",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.alpha_multiplier
							end,
						},
						{
							"texture_index",
							"int",
							function(self, block, key)
								local texture = render2d.state.render.textures.texture
								block[key] = texture and self:GetTextureIndex(texture) or -1
							end,
						},
						{
							"uv_offset",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.uv_offset, 8)
							end,
						},
						{
							"uv_scale",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.uv_scale, 8)
							end,
						},
						{
							"flags",
							"int",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.flags
							end,
						},
						{
							"blur",
							"vec2",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.blur, 8)
							end,
						},
						{
							"border_radius",
							"vec4",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.border_radius, 16)
							end,
						},
						{
							"outline_width",
							"float",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.outline_width
							end,
						},
						{
							"rect_size",
							"vec2",
							function(self, block, key)
								block[key][0] = render2d.state.render.fragment.rect_size.w
								block[key][1] = render2d.state.render.fragment.rect_size.h
							end,
						},
						{
							"sdf_threshold",
							"float",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.sdf_threshold
							end,
						},
						{
							"sdf_texel_range",
							"float",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.sdf_texel_range
							end,
						},
						{
							"gradient_texture_index",
							"int",
							function(self, block, key)
								local gradient_texture = render2d.state.render.textures.gradient_texture
								block[key] = gradient_texture and
									self:GetTextureIndex(gradient_texture) or
									-1
							end,
						},
						{
							"nine_patch_x_count",
							"int",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.nine_patch_x_count
							end,
						},
						{
							"nine_patch_y_count",
							"int",
							function(self, block, key)
								block[key] = render2d.state.render.fragment.constants.nine_patch_y_count
							end,
						},
						{
							"nine_patch_x_stretch",
							"float",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.nine_patch_x_stretch, 4 * 6)
							end,
							6,
						},
						{
							"nine_patch_y_stretch",
							"float",
							function(self, block, key)
								ffi.copy(block[key], render2d.state.render.fragment.constants.nine_patch_y_stretch, 4 * 6)
							end,
							6,
						},
						{
							"sdf_rect_size",
							"vec2",
							function(self, block, key)
								block[key][0] = render2d.state.render.fragment.rect_size.lw
								block[key][1] = render2d.state.render.fragment.rect_size.lh
							end,
						},
					},
				},
			},
			shader = render2d.BuildShaderFlags("U.flags") .. "\n" .. [[
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
					return U.sdf_rect_size.x > 0.0 && U.sdf_rect_size.y > 0.0;
				}

				#define FLAGS_SDF_ENABLED  (FLAGS_SWIZZLE == 10)

				bool has_texture_sdf_enabled() {
					return U.texture_index >= 0 && FLAGS_SDF_ENABLED;
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

					if (U.texture_index >= 0 && (U.nine_patch_x_count > 0 || U.nine_patch_y_count > 0)) {
						vec2 tex_size = vec2(textureSize(TEXTURE(U.texture_index), 0));
						vec2 p_logical = (coords - 0.5) * U.rect_size + U.sdf_rect_size * 0.5;

						if (U.nine_patch_x_count > 0) {
							uv.x = map_nine_patch(p_logical.x, U.sdf_rect_size.x, tex_size.x, U.nine_patch_x_stretch, U.nine_patch_x_count);
						}

						if (U.nine_patch_y_count > 0) {
							uv.y = map_nine_patch(p_logical.y, U.sdf_rect_size.y, tex_size.y, U.nine_patch_y_stretch, U.nine_patch_y_count);
						}
					}

					return uv;
				}

				vec4 sample_fragment_color(vec2 uv, bool is_sdf_tex) {
					vec4 color = in_color * U.global_color;

					if (U.texture_index >= 0 && !is_sdf_tex) {
						vec4 tex = texture(TEXTURE(U.texture_index), uv * U.uv_scale + U.uv_offset);
						color *= apply_swizzle(tex);
					}

					return color;
				}

				float compute_fragment_distance(vec2 coords, vec2 uv, bool has_rect_sdf, bool has_tex_sdf) {
					float d = 1e10;

					if (has_rect_sdf) {
						d = sd_rect(coords, U.rect_size, U.sdf_rect_size, U.border_radius);
					}

					if (has_tex_sdf) {
						bool use_direct_sample_uv = (FLAGS_SAMPLE_UV & 1) != 0;
						bool invert_tex_sdf = (FLAGS_SAMPLE_UV & 2) != 0;
						vec2 sdf_uv = use_direct_sample_uv ? in_sample_uv : (in_sample_uv * U.uv_scale + U.uv_offset);
						float d_tex = tex_sdf_distance(U.texture_index, U.sdf_threshold, U.sdf_texel_range, sdf_uv);

						if (invert_tex_sdf) d_tex = -d_tex;

						d = has_rect_sdf ? max(d, d_tex) : d_tex;
					}

					return d;
				}

				vec4 apply_fragment_gradient(vec2 coords, vec4 color) {
					if (U.gradient_texture_index >= 0) {
						float gy = coords.y;

						if (U.sdf_rect_size.y > 0.0) {
							gy = (coords.y - 0.5) * (U.rect_size.y / U.sdf_rect_size.y) + 0.5;
						}

						gy = clamp(gy, 0.0, 1.0);
						color *= texture(TEXTURE(U.gradient_texture_index), vec2(gy, 0.5));
					}

					return color;
				}

				float compute_sdf_alpha(float d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(U.blur.x, U.blur.y) * 1.75);
						float alpha = (U.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + U.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, 0.0), gamma);
					}

					float smoothing = max(U.blur.x, U.blur.y);
					smoothing = max(0.75, smoothing);
					return (U.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + U.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				vec3 compute_sdf_alpha(vec3 d, bool has_tex_sdf, bool has_rect_sdf) {
					if (has_tex_sdf && !has_rect_sdf) {
						float bias = -0.015;
						float gamma = 1.1;
						float softness = max(1.0, max(U.blur.x, U.blur.y) * 1.75);
						vec3 alpha = (U.outline_width > 0.0) ?
							(clamp((d + bias) / softness + 0.5, 0.0, 1.0) - clamp(((d + U.outline_width) + bias) / softness + 0.5, 0.0, 1.0)) :
							clamp((d + bias) / softness + 0.5, 0.0, 1.0);
						return pow(max(alpha, vec3(0.0)), vec3(gamma));
					}

					float smoothing = max(U.blur.x, U.blur.y);
					smoothing = max(0.7, smoothing);
					return (U.outline_width > 0.0) ?
						(smoothstep(smoothing, -smoothing, d) - smoothstep(smoothing, -smoothing, d + U.outline_width)) :
						smoothstep(smoothing, -smoothing, d);
				}

				float compute_blur_alpha(vec2 coords) {
					vec2 p = (coords - 0.5) * U.rect_size;
					vec2 b = max(vec2(0.0), (U.rect_size - U.blur * 2.0) * 0.5);
					vec2 q = abs(p) - b;
					float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
					float max_blur = max(U.blur.x, U.blur.y);
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

					if ((U.blur.x > 0.0 || U.blur.y > 0.0) && U.sdf_rect_size.x <= 0.0) {
						shaded.a *= compute_blur_alpha(coords);
					}

					shaded.a *= U.alpha_multiplier;
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
	local rect_batch_fragment = {
		push_constants = config.fragment.push_constants,
		shader = build_rect_batch_fragment_shader_source(config.fragment.shader),
	}
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
					attributes = {
						{"pos", "vec3", "r32g32b32_sfloat"},
						{"uv", "vec2", "r32g32_sfloat"},
						{"sample_uv", "vec2", "r32g32_sfloat"},
						{"color", "vec4", "r32g32b32a32_sfloat"},
					},
				},
				{
					binding = 1,
					input_rate = "instance",
					attributes = rect_batch_instance_attributes,
				},
			},
			outputs = {
				{"uv", "vec2"},
				{"sample_uv", "vec2"},
				{"color", "vec4"},
				{"batch_global_color", "vec4"},
				{"batch_uv_transform", "vec4"},
				{"batch_blur_modes", "vec4"},
				{"batch_border_radius", "vec4"},
				{"batch_quad_size", "vec4"},
				{"batch_sdf_texture", "vec4"},
				{"batch_outline_alpha", "vec2"},
			},
			shader = [[
				void main() {
					mat4 pvw = mat4(in_pvw_row_0, in_pvw_row_1, in_pvw_row_2, in_pvw_row_3);
					gl_Position = pvw * vec4(in_pos, 1.0);
					out_uv = in_uv;
					out_sample_uv = in_sample_uv;
					out_color = in_color;
					out_batch_global_color = in_batch_global_color;
					out_batch_uv_transform = in_batch_uv_transform;
					out_batch_blur_modes = in_batch_blur_modes;
					out_batch_border_radius = in_batch_border_radius;
					out_batch_quad_size = in_batch_quad_size;
					out_batch_sdf_texture = in_batch_sdf_texture;
					out_batch_outline_alpha = in_batch_outline_alpha;
				}
			]],
		},
		fragment = rect_batch_fragment,
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
	render2d.rect_batch_pipeline_state_id = intern_state_id(render2d.state.runtime.ids.roots.pipeline, render2d.rect_batch_pipeline)
	render2d.state.runtime.ids.current.rect_batch_pipeline = render2d.rect_batch_pipeline_state_id

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

	update_fragment_static_state_id()
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
				if mode then render2d.SetSWIZZLE(mode) end
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
				elseif render2d.GetSWIZZLE() == 10 then
					render2d.SetSWIZZLE(0)
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
				render2d.state.render.options.disable_rect_sdf = enabled == true
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

			update_fragment_static_state_id()
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
			update_fragment_static_state_id()
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
			render2d.state.render.fragment.constants.alpha_multiplier = a
		end

		function render2d.GetAlphaMultiplier()
			return render2d.state.render.fragment.constants.alpha_multiplier
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
		update_blend_mode_state_id(next_state)
		mark_pipeline_state_dirty()
	end

	function render2d.SetBlendPreset(mode_name)
		local next_state = get_blend_preset_state(mode_name)
		render2d.state.render.pipeline.blend = next_state
		update_blend_mode_state_id(next_state)
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
			update_depth_state_id(mode_name, write)
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
			update_stencil_state_id(mode_name, ref)
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
		update_scissor_state_id(x, y, w, h)
		apply_scissor_to_command_buffer(x, y, w, h)
	end

	do
		local stack = {}
		local clip_stack = {}
		local clip_axis_alignment_epsilon = 0.001

		local function clip_point_to_screen(clip_matrix, screen_w, screen_h, px, py)
			local clip_x, clip_y = clip_matrix:TransformVectorUnpacked(px, py, 0)
			return (clip_x * 0.5 + 0.5) * screen_w, (clip_y * 0.5 + 0.5) * screen_h
		end

		local function capture_clip_world_matrix()
			local world_matrix = Matrix44()
			Matrix44.CopyTo(render2d.GetWorldMatrix(), world_matrix)
			return world_matrix
		end

		local function project_clip_rect_to_screen(world_matrix, x, y, w, h)
			local clip_matrix = Matrix44()
			local screen_w, screen_h = render2d.GetSize()
			world_matrix:GetMultiplied(render2d.GetProjectionViewMatrix(), clip_matrix)
			local tl_x, tl_y = clip_point_to_screen(clip_matrix, screen_w, screen_h, x, y)
			local tr_x, tr_y = clip_point_to_screen(clip_matrix, screen_w, screen_h, x + w, y)
			local br_x, br_y = clip_point_to_screen(clip_matrix, screen_w, screen_h, x + w, y + h)
			local bl_x, bl_y = clip_point_to_screen(clip_matrix, screen_w, screen_h, x, y + h)
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
			local world_matrix = capture_clip_world_matrix()
			local axis_aligned, scissor_x, scissor_y, scissor_w, scissor_h = project_clip_rect_to_screen(world_matrix, x, y, w, h)

			if axis_aligned then
				render2d.PushScissor(scissor_x, scissor_y, scissor_w, scissor_h)
				table.insert(clip_stack, {kind = "scissor"})
				return
			end

			push_stencil_clip{
				kind = "stencil_rect",
				world_matrix = world_matrix,
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
				world_matrix = capture_clip_world_matrix(),
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
				world_matrix = capture_clip_world_matrix(),
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
		Matrix44.CopyTo(mat, camera_state.world_matrix_stack[camera_state.world_matrix_stack_pos])
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

capture_rect_draw_state = function()
	local rect_state_snapshot = RectDrawState()
	ffi.copy(
		rect_state_snapshot,
		render2d.state.render.fragment.constants,
		render2d.state.render.fragment.constants_size
	)
	return {
		rect_state_snapshot = rect_state_snapshot,
		world_matrix = render2d.state.runtime.camera.world_matrix_stack[render2d.state.runtime.camera.world_matrix_stack_pos]:Copy(),
		texture = render2d.state.render.textures.texture,
		gradient_texture = render2d.state.render.textures.gradient_texture,
		blend_mode = canonicalize_blend_mode_state(render2d.state.render.pipeline.blend),
		depth_mode = render2d.state.render.pipeline.depth.mode,
		depth_write = render2d.state.render.pipeline.depth.write,
		stencil_mode = render2d.state.render.pipeline.stencil.mode,
		stencil_ref = render2d.state.render.pipeline.stencil.ref,
		disable_rect_sdf = render2d.state.render.options.disable_rect_sdf,
		scissor_x = render2d.state.render.pipeline.scissor.x,
		scissor_y = render2d.state.render.pipeline.scissor.y,
		scissor_w = render2d.state.render.pipeline.scissor.w,
		scissor_h = render2d.state.render.pipeline.scissor.h,
		pipeline_state_id = render2d.state.runtime.ids.current.rect_batch_pipeline,
		fragment_static_state_id = render2d.state.runtime.ids.current.fragment_static,
		depth_state_id = render2d.state.runtime.ids.current.depth,
		stencil_state_id = render2d.state.runtime.ids.current.stencil,
		scissor_state_id = render2d.state.runtime.ids.current.scissor,
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
	render2d.state.render.pipeline.depth.mode = state.depth_mode
	render2d.state.render.pipeline.depth.write = state.depth_write
	render2d.state.render.pipeline.stencil.mode = state.stencil_mode
	render2d.state.render.pipeline.stencil.ref = state.stencil_ref
	render2d.state.render.options.disable_rect_sdf = state.disable_rect_sdf
	render2d.state.render.pipeline.scissor.x = state.scissor_x
	render2d.state.render.pipeline.scissor.y = state.scissor_y
	render2d.state.render.pipeline.scissor.w = state.scissor_w
	render2d.state.render.pipeline.scissor.h = state.scissor_h
	update_blend_mode_state_id(state.blend_mode)
	update_depth_state_id(state.depth_mode, state.depth_write)
	update_stencil_state_id(state.stencil_mode, state.stencil_ref)
	update_scissor_state_id(state.scissor_x, state.scissor_y, state.scissor_w, state.scissor_h)
	mark_pipeline_state_dirty()
	apply_scissor_to_command_buffer(state.scissor_x, state.scissor_y, state.scissor_w, state.scissor_h)
	Matrix44.CopyTo(
		state.world_matrix,
		render2d.state.runtime.camera.world_matrix_stack[render2d.state.runtime.camera.world_matrix_stack_pos]
	)
end

do
	local function get_margin()
		local constants = render2d.state.render.fragment.constants
		local content_m = constants.outline_width
		local swizzle = render2d.GetSwizzleMode()

		if swizzle == 10 or swizzle == 1 then
			content_m = content_m + math.max(constants.blur[0], constants.blur[1])
		end

		if constants.blur[0] > 0 or constants.blur[1] > 0 then
			content_m = math.max(content_m, constants.blur[0], constants.blur[1])
		end

		local m = content_m

		if m > 0 then m = m + 1 end

		return math.ceil(m)
	end

	function render2d.GetMargin()
		return render2d.state.render.options.margin_override or get_margin()
	end

	function render2d.SetMargin(new_m)
		render2d.state.render.options.margin_override = new_m
	end

	local function queue_rect_draw(use_float, x, y, w, h, a, ox, oy, max_m)
		local margin = render2d.GetMargin(w, h)
		local batch_mode = render2d.GetRectBatchMode()

		if max_m then margin = math.min(margin, max_m) end

		local state = capture_rect_draw_state()
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
			use_float
		)
		render2d.state.runtime.batch.state:Append(
			"rect",
			build_rect_batch_key(state, w, h, margin, batch_mode),
			{
				batch_mode = batch_mode,
				use_float = use_float,
				x = x,
				y = y,
				w = w,
				h = h,
				a = a,
				ox = ox,
				oy = oy,
				qw = qw,
				qh = qh,
				margin = margin,
				draw_matrix = draw_matrix,
				state = state,
			}
		)
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
		local old_off_x, old_off_y = constants.uv_offset[0], constants.uv_offset[1]
		local old_scale_x, old_scale_y = constants.uv_scale[0], constants.uv_scale[1]
		constants.uv_offset[0] = u1
		constants.uv_offset[1] = v1
		constants.uv_scale[0] = u2 - u1
		constants.uv_scale[1] = v2 - v1
		local result

		if can_batch_rect_draw() then
			result = queue_rect_draw(use_float, x, y, w, h, a, ox, oy, max_m)
		else
			result = draw_rect_immediate(x, y, w, h, a, ox, oy, nil, use_float)
		end

		constants.uv_offset[0], constants.uv_offset[1] = old_off_x, old_off_y
		constants.uv_scale[0], constants.uv_scale[1] = old_scale_x, old_scale_y
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
update_blend_mode_state_id(render2d.state.render.pipeline.blend)
update_depth_state_id(DEFAULT_DEPTH_MODE, false)
update_stencil_state_id("none", 1)
update_scissor_state_id(0, 0, 0, 0)
update_fragment_static_state_id()
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
