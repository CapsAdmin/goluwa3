local ffi = require("ffi")
local utility = require("utility")
local Colorf = require("structs.color").Colorf
local Vec3f = require("structs.vec3").Vec3f
local Vec2f = require("structs.vec2").Vec2f
local Rect = require("structs.rect")
local Matrix44f = require("structs.matrix").Matrix44f
local render = require("graphics.render")
local window = require("graphics.window")
local event = require("event")
local VertexBuffer = require("graphics.vertex_buffer")
local IndexBuffer = require("graphics.index_buffer")
local Texture = require("graphics.texture")
-- Vertex shader push constants (64 bytes)
local VertexConstants = ffi.typeof([[
	struct {
		$ projection_view_world;
	}
]], Matrix44f)
local FragmentConstants = ffi.typeof(
	[[
	struct {
        $ global_color;          
        float alpha_multiplier;  
        int texture_index;       
        $ uv_offset;             
        $ uv_scale;              
	}
]],
	Colorf,
	Vec2f,
	Vec2f
)
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
			fragment_constants.global_color.r = r
			fragment_constants.global_color.g = g
			fragment_constants.global_color.b = b
			fragment_constants.global_color.a = a or fragment_constants.global_color.a
		end

		function render2d.GetColor()
			return fragment_constants.global_color:Unpack()
		end

		utility.MakePushPopFunction(render2d, "Color")
	end

	do
		function render2d.SetAlphaMultiplier(a)
			fragment_constants.alpha_multiplier = a or fragment_constants.alpha_multiplier
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
		local matrices = render2d.camera:GetMatrices()

		do
			vertex_constants.projection_view_world = matrices.projection_view_world
			render2d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
		end

		do
			fragment_constants.texture_index = render2d.current_texture and
				render2d.pipeline:GetTextureIndex(render2d.current_texture) or
				-1
			render2d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(vertex_constants), fragment_constants)
		end
	end

	function render2d.UpdateScreenSize(size)
		render2d.camera:SetViewport(Rect(0, 0, size.x, size.y))
	end
end

do -- mesh
	function render2d.CreateMesh(vertices)
		return VertexBuffer.New(vertices, render2d.pipeline:GetVertexAttributes())
	end

	function render2d.BindMesh(vertex_buffer, index_buffer)
		render2d.cmd:BindVertexBuffer(vertex_buffer:GetBuffer(), 0)

		if index_buffer then
			render2d.cmd:BindIndexBuffer(index_buffer:GetBuffer(), 0, "uint16")
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
			fragment_constants.uv_offset.x = 0
			fragment_constants.uv_offset.y = 0
			fragment_constants.uv_scale.x = 1
			fragment_constants.uv_scale.y = 1
		else
			sx = sx or 1
			sy = sy or 1
			local y = -y - h
			-- Set UV offset and scale
			fragment_constants.uv_offset.x = x / sx
			fragment_constants.uv_offset.y = y / sy
			fragment_constants.uv_scale.x = w / sx
			fragment_constants.uv_scale.y = h / sy
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
		fragment_constants.uv_offset.x = u1
		fragment_constants.uv_offset.y = v1
		fragment_constants.uv_scale.x = u2 - u1
		fragment_constants.uv_scale.y = v2 - v1
	end

	utility.MakePushPopFunction(render2d, "UV")
end

do -- camera
	local camera = require("graphics.camera")
	render2d.camera = camera.CreateCamera()
	render2d.camera:Set3D(false)
	render2d._camera = render2d.camera

	function render2d.SetCamera(cam)
		render2d.camera = cam or render2d._camera
	end

	function render2d.GetSize()
		return render2d.camera.Viewport.w, render2d.camera.Viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			render2d.camera:TranslateWorld(ceil(x), ceil(y), z or 0)
		end
	end

	function render2d.Translatef(x, y, z)
		render2d.camera:TranslateWorld(x, y, z or 0)
	end

	function render2d.Rotate(a)
		render2d.camera:RotateWorld(a, 0, 0, 1)
	end

	function render2d.Scale(w, h, z)
		render2d.camera:ScaleWorld(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		render2d.camera:ShearWorld(x, y, 0)
	end

	function render2d.LoadIdentity()
		render2d.camera:LoadIdentityWorld()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		render2d.camera:PushWorld(nil, dont_multiply)

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
		render2d.camera:PopWorld()
	end

	function render2d.SetWorldMatrix(mat)
		render2d.camera:SetWorld(mat)
	end

	function render2d.GetWorldMatrix()
		return render2d.camera:GetWorld()
	end

	function render2d.ScreenToWorld(x, y)
		return render2d.camera:ScreenToWorld(x, y)
	end

	function render2d.ScreenTo3DWorld(x, y)
		return render3d.camera:ScreenToWorld(x, y)
	end

	function render2d.Start3D2D(pos, ang, scale)
		render2d.camera:Start3D2DEx(pos, ang, scale)
	end

	function render2d.End3D2D()
		render2d.camera:End3D2D()
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
	local index_buffer = IndexBuffer.New(indices)
	local vertex_buffer = render2d.CreateMesh(mesh_data)

	function render2d.DrawRect(x, y, w, h, a, ox, oy)
		render2d.BindMesh(vertex_buffer, index_buffer)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.DrawIndexedMesh(6)
		render2d.PopMatrix()
	end
end

do -- triangle 
	local vertex_buffer = render2d.CreateMesh(
		{
			{pos = Vec3f(-0.5, -0.5, 0), uv = Vec2f(0, 0), color = Colorf(1, 1, 1, 1)},
			{pos = Vec3f(0.5, 0.5, 0), uv = Vec2f(1, 1), color = Colorf(1, 1, 1, 1)},
			{pos = Vec3f(-0.5, 0.5, 0), uv = Vec2f(0, 1), color = Colorf(1, 1, 1, 1)},
		}
	)

	function render2d.DrawTriangle(x, y, w, h, a)
		render2d.BindMesh(vertex_buffer)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.DrawMesh(3)
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
