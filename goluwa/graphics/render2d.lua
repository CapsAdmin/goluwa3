local ffi = require("ffi")
local utility = require("utility")
local Colorf = require("structs.color")
local Vec3f = require("structs.vec3")
local Vec2f = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44f = require("structs.matrix").Matrix44f
local render = require("graphics.render")
local window = require("graphics.window")
local event = require("event")
local VertexBuffer = require("graphics.vertex_buffer")
local Mesh = require("graphics.mesh")
local Texture = require("graphics.texture")
-- Vertex shader push constants (64 bytes)
local VertexConstants = ffi.typeof([[
	struct {
		float projection_view_world[16];
	}
]])
local FragmentConstants = ffi.typeof([[
	struct {
        float global_color[4];          
        float alpha_multiplier;  
        int texture_index;       
        float uv_offset[2];             
        float uv_scale[2];              
	}
]])
local vertex_constants = VertexConstants()
local fragment_constants = FragmentConstants()
local render2d = {}
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
	render2d.pipeline = render.CreateGraphicsPipeline(render2d.pipeline_data)
	render2d.SetTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetUV()
	render2d.UpdateScreenSize(window:GetSize())
	render2d.current_blend_mode = "alpha"
end

do -- shader
	local dynamic_states = {"viewport", "scissor", "blend_constants"}

	if render.GetDevice().has_extended_dynamic_state3 then
		table.insert(dynamic_states, "color_blend_enable_ext")
		table.insert(dynamic_states, "color_blend_equation_ext")
	end

	render2d.pipeline_data = {
		dynamic_states = dynamic_states, -- Will be updated in Initialize() based on support
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_pos;
					layout(location = 1) in vec2 in_uv;
					layout(location = 2) in vec4 in_color;

					layout(push_constant, scalar) uniform VertexConstants {
						mat4 projection_view_world;
					} pc;

					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec4 out_color;

					void main() {
						gl_Position = pc.projection_view_world * vec4(in_pos, 1.0);
						out_uv = in_uv;
						out_color = in_color;
					}
				]],
				bindings = {
					{
						binding = 0,
						stride = ffi.sizeof("float") * 9, -- vec3 + vec2 + vec4
						input_rate = "vertex",
					},
				},
				attributes = {
					{
						binding = 0,
						location = 0, -- in_position
						format = "R32G32B32_SFLOAT", -- vec3
						offset = 0,
						lua_type = Vec3f,
						lua_name = "pos",
					},
					{
						binding = 0,
						location = 1, -- in_uv
						format = "R32G32_SFLOAT", -- vec2
						offset = ffi.sizeof(Vec3f),
						lua_type = Vec2f,
						lua_name = "uv",
					},
					{
						binding = 0,
						location = 2, -- in_color
						format = "R32G32B32A32_SFLOAT", -- vec4
						offset = ffi.sizeof(Vec3f) + ffi.sizeof(Vec2f),
						lua_type = Colorf,
						lua_name = "color",
					},
				},
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
				push_constants = {
					size = ffi.sizeof(VertexConstants),
					offset = 0,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require
					#extension GL_EXT_nonuniform_qualifier : require

					layout(binding = 0) uniform sampler2D textures[1024]; // Bindless texture array
					layout(location = 0) in vec2 in_uv;
					layout(location = 1) in vec4 in_color;
					layout(location = 0) out vec4 out_color;

					layout(push_constant, scalar) 
					uniform FragmentConstants {
						layout(offset = ]] .. ffi.sizeof(VertexConstants) .. [[)
						vec4 global_color;
						float alpha_multiplier;
						int texture_index;
						vec2 uv_offset;
						vec2 uv_scale;
					} pc;                   
					
					void main() 
					{
						out_color = in_color * pc.global_color;
						
						if (pc.texture_index >= 0) {
							out_color *= texture(textures[nonuniformEXT(pc.texture_index)], in_uv * pc.uv_scale + pc.uv_offset);
						}

						out_color.a = out_color.a * pc.alpha_multiplier;
					}
				]],
				descriptor_sets = {
					{
						type = "combined_image_sampler",
						binding_index = 0,
						count = 1024,
					},
				},
				push_constants = {
					size = ffi.sizeof(FragmentConstants),
					offset = ffi.sizeof(VertexConstants),
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "front",
			front_face = "counter_clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {
				{
					blend = true,
					src_color_blend_factor = "src_alpha",
					dst_color_blend_factor = "one_minus_src_alpha",
					color_blend_op = "add",
					src_alpha_blend_factor = "one",
					dst_alpha_blend_factor = "zero",
					alpha_blend_op = "add",
					color_write_mask = {"r", "g", "b", "a"},
				},
			},
		},
		multisampling = {
			sample_shading = false,
			rasterization_samples = "1",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = true,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
	render2d.pipeline = render2d.pipeline or NULL

	do
		function render2d.SetColor(r, g, b, a)
			fragment_constants.global_color[0] = r
			fragment_constants.global_color[1] = g
			fragment_constants.global_color[2] = b

			if a then fragment_constants.global_color[3] = a end
		end

		function render2d.GetColor()
			return fragment_constants.global_color[0],
			fragment_constants.global_color[1],
			fragment_constants.global_color[2],
			fragment_constants.global_color[3]
		end

		utility.MakePushPopFunction(render2d, "Color")
	end

	do
		function render2d.SetAlphaMultiplier(a)
			fragment_constants.alpha_multiplier = a
		end

		function render2d.GetAlphaMultiplier()
			return fragment_constants.alpha_multiplier
		end

		utility.MakePushPopFunction(render2d, "AlphaMultiplier")
	end

	do
		function render2d.SetTexture(tex)
			render2d.current_texture = tex

			if tex then render2d.pipeline:RegisterTexture(tex) end
		end

		function render2d.GetTexture()
			return render2d.current_texture
		end

		utility.MakePushPopFunction(render2d, "Texture")
	end

	function render2d.SetBlendMode(mode_name)
		if render2d.current_blend_mode == mode_name then return end

		if not render2d.blend_modes[mode_name] then
			local valid_modes = {}

			for k in pairs(render2d.blend_modes) do
				table.insert(valid_modes, k)
			end

			error(
				"Invalid blend mode: " .. tostring(mode_name) .. ". Valid modes: " .. table.concat(valid_modes, ", ")
			)
		end

		render2d.current_blend_mode = mode_name
		local blend_mode = render2d.blend_modes[mode_name]

		if render.GetDevice().has_extended_dynamic_state3 then
			if render2d.cmd then
				render2d.cmd:SetColorBlendEnable(0, blend_mode.blend)

				if blend_mode.blend then
					render2d.cmd:SetColorBlendEquation(0, blend_mode)
				end
			end
		else
			local data = table.copy(render2d.pipeline_data)
			data.color_blend.attachments[1] = {
				blend = blend_mode.blend,
				src_color_blend_factor = blend_mode.src_color_blend_factor,
				dst_color_blend_factor = blend_mode.dst_color_blend_factor,
				color_blend_op = blend_mode.color_blend_op,
				src_alpha_blend_factor = blend_mode.src_alpha_blend_factor,
				dst_alpha_blend_factor = blend_mode.dst_alpha_blend_factor,
				alpha_blend_op = blend_mode.alpha_blend_op,
				color_write_mask = {"r", "g", "b", "a"},
			}
			render2d.pipeline = render.CreateGraphicsPipeline(data)
		end
	end

	function render2d.GetBlendMode()
		return render2d.current_blend_mode
	end

	utility.MakePushPopFunction(render2d, "BlendMode")

	function render2d.GetPipelineVariantInfo()
		if render2d.pipeline and render2d.pipeline.GetVariantInfo then
			return render2d.pipeline:GetVariantInfo()
		end

		return {count = 0, keys = {}, current = nil}
	end

	function render2d.SetBlendConstants(r, g, b, a)
		if render2d.cmd then render2d.cmd:SetBlendConstants(r, g, b, a) end
	end

	function render2d.UploadConstants(cmd)
		do
			vertex_constants.projection_view_world = render2d.GetMatrix()
			render2d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
		end

		do
			fragment_constants.texture_index = render2d.current_texture and
				render2d.pipeline:GetTextureIndex(render2d.current_texture) or
				-1
			render2d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(vertex_constants), fragment_constants)
		end
	end
end

do -- mesh
	function render2d.CreateMesh(vertices, indices)
		return Mesh.New(render2d.pipeline:GetVertexAttributes(), vertices, indices)
	end

	local last_bound_mesh = nil

	function render2d.BindMesh(mesh)
		if true or last_bound_mesh ~= mesh then
			mesh:Bind(render2d.cmd, 0)
			last_bound_mesh = mesh
		end
	end

	function render2d.DrawIndexedMesh(index_count, instance_count, first_index, vertex_offset, first_instance)
		render2d.cmd:DrawIndexed(
			index_count or index_buffer:GetIndexCount(),
			instance_count or 1,
			first_index or 0,
			vertex_offset or 0,
			first_instance or 0
		)
	end

	function render2d.DrawMesh(vertex_count, instance_count, first_vertex, first_instance)
		render2d.cmd:Draw(
			vertex_count or vertex_buffer:GetVertexCount(),
			instance_count or 1,
			first_vertex or 0,
			first_instance or 0
		)
	end
end

do -- uv
	local X, Y, W, H, SX, SY

	function render2d.SetUV(x, y, w, h, sx, sy)
		if not x then
			-- Reset to default (no transformation)
			fragment_constants.uv_offset[0] = 0
			fragment_constants.uv_offset[1] = 0
			fragment_constants.uv_scale[0] = 1
			fragment_constants.uv_scale[1] = 1
		else
			sx = sx or 1
			sy = sy or 1
			local y = -y - h
			-- Set UV offset and scale
			fragment_constants.uv_offset[0] = x / sx
			fragment_constants.uv_offset[1] = y / sy
			fragment_constants.uv_scale[0] = w / sx
			fragment_constants.uv_scale[1] = h / sy
		end

		X = x
		Y = y
		W = w
		H = h
		SX = sx
		SY = sy
	end

	function render2d.GetUV()
		return X, Y, W, H, SX, SY
	end

	function render2d.SetUV2(u1, v1, u2, v2)
		-- Calculate offset and scale from UV coordinates
		fragment_constants.uv_offset[0] = u1
		fragment_constants.uv_offset[1] = v1
		fragment_constants.uv_scale[0] = u2 - u1
		fragment_constants.uv_scale[1] = v2 - v1
	end

	utility.MakePushPopFunction(render2d, "UV")
end

do -- camera
	local Matrix44 = require("structs.matrix").Matrix44f
	local proj = Matrix44()
	local view = Matrix44()
	local world = Matrix44()
	local viewport = Rect(0, 0, 512, 512)
	local view_pos = Vec2f(0, 0)
	local view_zoom = Vec2f(1, 1)
	local view_angle = 0
	local world_matrix_stack = {Matrix44()}
	local world_matrix_stack_pos = 1
	local proj_view = Matrix44()

	local function update_proj_view()
		proj_view = proj * view
	end

	local function update_projection()
		proj:Identity()
		proj:Ortho(viewport.x, viewport.w, viewport.y, viewport.h, -1, 1)
		update_proj_view()
	end

	local function update_view()
		view:Identity()
		local x, y = viewport.w / 2, viewport.h / 2
		view:Translate(x, y, 0)
		view:Rotate(view_angle, 0, 0, 1)
		view:Translate(-x, -y, 0)
		view:Translate(view_pos.x, view_pos.y, 0)
		view:Translate(x, y, 0)
		view:Scale(view_zoom.x, view_zoom.y, 1)
		view:Translate(-x, -y, 0)
		update_proj_view()
	end

	function render2d.UpdateScreenSize(size)
		viewport.w = size.w
		viewport.h = size.h
		update_projection()
		update_view()
	end

	function render2d.GetMatrix()
		return proj_view * world_matrix_stack[world_matrix_stack_pos]
	end

	function render2d.GetSize()
		return viewport.w, viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			world_matrix_stack[world_matrix_stack_pos]:Translate(ceil(x), ceil(y), z or 0)
		end
	end

	function render2d.Translatef(x, y, z)
		world_matrix_stack[world_matrix_stack_pos]:Translate(x, y, z or 0)
	end

	function render2d.Rotate(a)
		world_matrix_stack[world_matrix_stack_pos]:Rotate(a, 0, 0, 1)
	end

	function render2d.Scale(w, h, z)
		world_matrix_stack[world_matrix_stack_pos]:Scale(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		world_matrix_stack[world_matrix_stack_pos]:Shear(x, y, 0)
	end

	function render2d.LoadIdentity()
		world_matrix_stack[world_matrix_stack_pos]:Identity()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		world_matrix_stack_pos = world_matrix_stack_pos + 1

		if dont_multiply then
			world_matrix_stack[world_matrix_stack_pos] = Matrix44()
		else
			world_matrix_stack[world_matrix_stack_pos] = world_matrix_stack[world_matrix_stack_pos - 1]:Copy()
		end

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
		if world_matrix_stack_pos > 1 then
			world_matrix_stack_pos = world_matrix_stack_pos - 1
		else
			error("Matrix stack underflow")
		end
	end

	function render2d.SetWorldMatrix(mat)
		world_matrix_stack[world_matrix_stack_pos] = mat:Copy()
	end

	function render2d.GetWorldMatrix()
		return world_matrix_stack[world_matrix_stack_pos]
	end
end

render2d.Initialize()

do -- rectangle
	local mesh_data = {
		{pos = Vec3f(0, 1, 0), uv = Vec2f(0, 0), color = Colorf(1, 1, 1, 1)}, -- top-left
		{pos = Vec3f(0, 0, 0), uv = Vec2f(0, 1), color = Colorf(1, 1, 1, 1)}, -- bottom-left
		{pos = Vec3f(1, 1, 0), uv = Vec2f(1, 0), color = Colorf(1, 1, 1, 1)}, -- top-right
		{pos = Vec3f(1, 0, 0), uv = Vec2f(1, 1), color = Colorf(1, 1, 1, 1)}, -- bottom-right
	}
	local indices = {0, 1, 2, 2, 1, 3}
	local mesh = render2d.CreateMesh(mesh_data, indices)

	function render2d.DrawRect(x, y, w, h, a, ox, oy)
		render2d.BindMesh(mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		mesh:DrawIndexed(render2d.cmd, 6)
		render2d.PopMatrix()
	end
end

do -- triangle 
	local mesh = render2d.CreateMesh(
		{
			{pos = Vec3f(-0.5, -0.5, 0), uv = Vec2f(0, 0), color = Colorf(1, 1, 1, 1)},
			{pos = Vec3f(0.5, 0.5, 0), uv = Vec2f(1, 1), color = Colorf(1, 1, 1, 1)},
			{pos = Vec3f(-0.5, 0.5, 0), uv = Vec2f(0, 1), color = Colorf(1, 1, 1, 1)},
		}
	)

	function render2d.DrawTriangle(x, y, w, h, a)
		render2d.BindMesh(mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		mesh:Draw(render2d.cmd, 3)
		render2d.PopMatrix()
	end
end

event.AddListener("PostDraw", "draw_2d", function(cmd, dt)
	local frame_index = render.GetCurrentFrame()
	render2d.cmd = cmd
	render2d.pipeline:Bind(cmd, frame_index)
	render2d.SetBlendMode(render2d.current_blend_mode)
	event.Call("Draw2D", dt)
end)

event.AddListener("WindowFramebufferResized", "render2d", function(wnd, size)
	render2d.UpdateScreenSize(size)
end)

return render2d
