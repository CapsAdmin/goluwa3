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
local Constants = ffi.typeof(
	[[
	struct {
		$ projection_view_world;
        float alpha_multiplier;
        float alpha_test_ref;
        $ hsv_mult;
        $ global_color;
        $ color_override;
        float border_radius;
        $ screen_size;
        $ world;
	}
]],
	Matrix44f, -- projection_view_world
	Vec3f, -- hsv_mult
	Colorf, -- global_color
	Colorf, -- color_override
	Vec2f, -- screen_size
	Matrix44f -- world
)

local function to_vertex_data(tbl, layout, type)
	local length = 0

	for _, field in ipairs(layout) do
		length = length + #tbl[1][field]
	end

	length = length * #tbl
	local data = ffi.new(type .. "[?]", length)
	local offset = 0

	for i, row in ipairs(tbl) do
		for _, field in ipairs(layout) do
			for j = 1, #row[field] do
				data[offset] = row[field][j]
				offset = offset + 1
			end
		end
	end

	return data, ffi.sizeof(type) * length
end

local shader_constants = Constants()
local render2d = {}

function render2d.Initialize()
	render2d.pipeline = render.CreateGraphicsPipeline(render2d.pipeline_data)
	local mesh_data = {
		{pos = {0, 1, 0}, uv = {0, 0}, color = {1, 1, 1, 1}},
		{pos = {0, 0, 0}, uv = {0, 1}, color = {1, 1, 1, 1}},
		{pos = {1, 1, 0}, uv = {1, 0}, color = {1, 1, 1, 1}},
		{pos = {1, 0, 0}, uv = {1, 1}, color = {1, 1, 1, 1}},
		{pos = {1, 1, 0}, uv = {1, 0}, color = {1, 1, 1, 1}},
		{pos = {0, 0, 0}, uv = {0, 1}, color = {1, 1, 1, 1}},
	}

	do
		local indices = ffi.new("uint16_t[?]", #mesh_data)

		for i in ipairs(mesh_data) do
			indices[i - 1] = i - 1
		end

		render2d.rectangle_indices = render.CreateBuffer(
			{
				buffer_usage = "index_buffer",
				data_type = "uint16_t",
				data = indices,
				byte_size = ffi.sizeof("uint16_t") * #mesh_data,
			}
		)
	end

	do
		local mesh, size = to_vertex_data(mesh_data, {"pos", "uv", "color"}, "float")
		render2d.rectangle = render.CreateBuffer(
			{
				buffer_usage = "vertex_buffer",
				data_type = "float",
				data = mesh,
				byte_size = size,
			}
		)
	end

	do
		local buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255})
		render2d.white_texture = render.CreateTexture({
			width = 1,
			height = 1,
			buffer = buffer,
		})
	end

	render2d.SetTexture()
	render2d.SetHSV(1, 1, 1)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetColorOverride(0, 0, 0, 0)
	render2d.SetAlphaMultiplier(1)
	render2d.SetAlphaTestReference(0)
	render2d.SetBorderRadius(0)
	render2d.UpdateScreenSize(window:GetSize())
	render2d.ready = true
end

function render2d.IsReady()
	return render2d.ready == true
end

do -- shader
	render2d.pipeline_data = {
		dynamic_states = {"viewport", "scissor"},
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					layout(location = 0) in vec3 in_pos;
					layout(location = 1) in vec2 in_uv;
					layout(location = 2) in vec4 in_color;

					layout(push_constant) uniform Constants {
						mat4 projection_view_world;
                        float alpha_multiplier;
                        float alpha_test_ref;
                        vec3 hsv_mult;
                        vec4 global_color;
                        vec4 color_override;
                        float border_radius;
                        vec2 screen_size;
                        mat4 world;
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
					},
					{
						binding = 0,
						location = 1, -- in_uv
						format = "R32G32_SFLOAT", -- vec2
						offset = ffi.sizeof("float") * 3,
					},
					{
						binding = 0,
						location = 2, -- in_color
						format = "R32G32B32A32_SFLOAT", -- vec4
						offset = ffi.sizeof("float") * 5,
					},
				},
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
				push_constants = {
					size = ffi.sizeof(Constants),
					offset = 0,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450

					layout(binding = 0) uniform sampler2D tex_sampler;
					layout(location = 0) in vec2 in_uv;
					layout(location = 1) in vec4 in_color;
					layout(location = 0) out vec4 out_color;

                    layout(push_constant) uniform Constants {
						mat4 projection_view_world;
                        float alpha_multiplier;
                        float alpha_test_ref;
                        vec3 hsv_mult;
                        vec4 global_color;
                        vec4 color_override;
                        float border_radius;
                        vec2 screen_size;
                        mat4 world;
					} pc;

                    vec3 rgb2hsv(vec3 c)
                    {
                        vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                        vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
                        vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

                        float d = q.x - min(q.w, q.y);
                        float e = 1.0e-10;
                        return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
                    }

                    vec3 hsv2rgb(vec3 c)
                    {
                        vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                        vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
                        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
                    }

					void main() {
						
                        vec4 tex_color = texture(tex_sampler, in_uv);
                        float alpha_test = pc.alpha_test_ref;
                        if (alpha_test > 0.0) {
                            if (tex_color.a < alpha_test) {
                                discard;
                            }
                        }

                        vec4 override = pc.color_override;

                        if (override.r > 0) tex_color.r = override.r;
                        if (override.g > 0) tex_color.g = override.g;
                        if (override.b > 0) tex_color.b = override.b;
                        if (override.a > 0) tex_color.a = override.a;

                        out_color = tex_color * in_color * pc.global_color;
                        out_color.a = out_color.a * pc.alpha_multiplier;

                        vec3 hsv_mult = pc.hsv_mult;
                        if (hsv_mult != vec3(1,1,1)) {
                            out_color.rgb = hsv2rgb(rgb2hsv(out_color.rgb) * hsv_mult);
                        }

                        vec2 ratio = vec2(1, 1);

                        if (pc.screen_size.y > pc.screen_size.x) {
                            ratio = vec2(1, pc.screen_size.y / pc.screen_size.x);
                        } else {
                            ratio = vec2(1, pc.screen_size.y / pc.screen_size.x);
                        }

                        float radius = pc.border_radius;
                        if (radius > 0) {
                            float softness = 50;
                            vec2 scale = vec2(pc.world[0][0], pc.world[1][1]);
                            vec2 ratio2 = vec2(scale.y / scale.x, 1);
                            vec2 size = scale;
                            radius = min(radius, scale.x/2);
                            radius = min(radius, scale.y/2);

                            if (in_uv.x > 1.0 - radius/scale.x && in_uv.y > 1.0 - radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(1, 1) + vec2(radius/scale.x, radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x < radius/scale.x && in_uv.y > 1.0 - radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(0, 1) + vec2(-radius/scale.x, radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x > 1.0 - radius/scale.x && in_uv.y < radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(1, 0) + vec2(radius/scale.x, -radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x < radius/scale.x && in_uv.y < radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(0, 0) + vec2(-radius/scale.x, -radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }
                        }


					}
				]],
				descriptor_sets = {
					{
						type = "combined_image_sampler",
						binding_index = 0,
					},
				},
				push_constants = {
					size = ffi.sizeof(Constants),
					offset = 0,
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
					blend = false,
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

	function render2d.CreateMesh(vertices)
		return render.CreateVertexBuffer(render2d.pipeline:GetMeshLayout(), vertices)
	end

	render2d.pipeline = render2d.pipeline or NULL

	local function convert(tbl, layout)
		local length = 0

		for _, field in ipairs(layout) do
			length = length + #tbl[1][field]
		end

		length = length * #tbl
		local data = ffi.new("float[?]", length)
		local offset = 0

		for i, row in ipairs(tbl) do
			for _, field in ipairs(layout) do
				for j = 1, #row[field] do
					data[offset] = row[field][j]
					offset = offset + 1
				end
			end
		end

		return {data, ffi.sizeof("float") * length}
	end

	function render2d.SetHSV(h, s, v)
		shader_constants.hsv_mult.x = h
		shader_constants.hsv_mult.y = s
		shader_constants.hsv_mult.z = v
	end

	function render2d.GetHSV()
		return shader_constants.hsv_mult:Unpack()
	end

	utility.MakePushPopFunction(render2d, "HSV")

	function render2d.SetColor(r, g, b, a)
		shader_constants.global_color.r = r
		shader_constants.global_color.g = g
		shader_constants.global_color.b = b
		shader_constants.global_color.a = a or shader_constants.global_color.a
	end

	function render2d.GetColor()
		return shader_constants.global_color:Unpack()
	end

	utility.MakePushPopFunction(render2d, "Color")

	function render2d.SetColorOverride(r, g, b, a)
		shader_constants.color_override.r = r
		shader_constants.color_override.g = g
		shader_constants.color_override.b = b
		shader_constants.color_override.a = a or shader_constants.color_override.a
	end

	function render2d.GetColorOverride()
		return shader_constants.color_override:Unpack()
	end

	utility.MakePushPopFunction(render2d, "ColorOverride")

	function render2d.SetAlpha(a)
		shader_constants.global_color.a = a
	end

	function render2d.GetAlpha()
		return shader_constants.global_color.a
	end

	utility.MakePushPopFunction(render2d, "Alpha")

	function render2d.SetAlphaMultiplier(a)
		shader_constants.alpha_multiplier = a or shader_constants.alpha_multiplier
	end

	function render2d.GetAlphaMultiplier()
		return shader_constants.alpha_multiplier
	end

	utility.MakePushPopFunction(render2d, "AlphaMultiplier")

	function render2d.SetTexture(tex)
		if not tex then tex = render2d.white_texture end

		render2d.current_texture = tex
		render2d.UpdateDescriptorSet("combined_image_sampler", 1, 0, tex.view, tex.sampler)
	end

	function render2d.GetTexture()
		return render2d.current_texture
	end

	utility.MakePushPopFunction(render2d, "Texture")

	function render2d.SetAlphaTestReference(num)
		if not num then num = 0 end

		shader_constants.alpha_test_ref = num
	end

	function render2d.GetAlphaTestReference()
		return shader_constants.alpha_test_ref
	end

	utility.MakePushPopFunction(render2d, "AlphaTestReference")

	function render2d.SetBorderRadius(num)
		if not num then num = 0 end

		shader_constants.border_radius = num
	end

	function render2d.GetBorderRadius()
		return shader_constants.border_radius
	end

	utility.MakePushPopFunction(render2d, "BorderRadius")

	function render2d.UpdateDescriptorSet(type, index, binding_index, ...)
		render2d.pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
	end

	function render2d.UploadConstants(cmd)
		shader_constants.projection_view_world = render2d.camera:GetMatrices().projection_view_world
		shader_constants.world = render2d.camera:GetMatrices().world
		render2d.pipeline:PushConstants(cmd, {"vertex", "fragment"}, 0, shader_constants)
	end

	function render2d.UpdateScreenSize(size)
		render2d.camera:SetViewport(Rect(0, 0, size.x, size.y))
		shader_constants.screen_size = Vec2f(size.x, size.y)
	end
end

do -- rectangle
	function render2d.DrawRect(x, y, w, h, a, ox, oy)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.cmd:DrawIndexed(6, 1, 0, 0, 0)
		render2d.PopMatrix()
	end

	do
		--[[{
		{pos = {0, 0}, uv = {xbl, ybl}, color = color_bottom_left},
		{pos = {0, 1}, uv = {xtl, ytl}, color = color_top_left},
		{pos = {1, 1}, uv = {xtr, ytr}, color = color_top_right},

		{pos = {1, 1}, uv = {xtr, ytr}, color = color_top_right},
		{pos = {1, 0}, uv = {xbr, ybr}, color = mesh_data[1].color},
		{pos = {0, 0}, uv = {xbl, ybl}, color = color_bottom_left},
	})]]
		-- sdasdasd
		local last_xtl = 0
		local last_ytl = 0
		local last_xtr = 1
		local last_ytr = 0
		local last_xbl = 0
		local last_ybl = 1
		local last_xbr = 1
		local last_ybr = 1
		local last_color_bottom_left = Colorf(1, 1, 1, 1)
		local last_color_top_left = Colorf(1, 1, 1, 1)
		local last_color_top_right = Colorf(1, 1, 1, 1)
		local last_color_bottom_right = Colorf(1, 1, 1, 1)

		local function update_vbo()
			if
				last_xtl ~= render2d.rectangle.Vertices.Pointer[0].uv[0] or
				last_ytl ~= render2d.rectangle.Vertices.Pointer[0].uv[1] or
				last_xtr ~= render2d.rectangle.Vertices.Pointer[4].uv[0] or
				last_ytr ~= render2d.rectangle.Vertices.Pointer[4].uv[1] or
				last_xbl ~= render2d.rectangle.Vertices.Pointer[1].uv[0] or
				last_ybl ~= render2d.rectangle.Vertices.Pointer[0].uv[1] or
				last_xbr ~= render2d.rectangle.Vertices.Pointer[3].uv[0] or
				last_ybr ~= render2d.rectangle.Vertices.Pointer[3].uv[1] or
				last_color_bottom_left ~= render2d.rectangle.Vertices.Pointer[1].color or
				last_color_top_left ~= render2d.rectangle.Vertices.Pointer[0].color or
				last_color_top_right ~= render2d.rectangle.Vertices.Pointer[2].color or
				last_color_bottom_right ~= render2d.rectangle.Vertices.Pointer[3].color
			then
				render2d.rectangle:UpdateBuffer()
				last_xtl = render2d.rectangle.Vertices.Pointer[0].uv[0]
				last_ytl = render2d.rectangle.Vertices.Pointer[0].uv[1]
				last_xtr = render2d.rectangle.Vertices.Pointer[4].uv[0]
				last_ytr = render2d.rectangle.Vertices.Pointer[4].uv[1]
				last_xbl = render2d.rectangle.Vertices.Pointer[1].uv[0]
				last_ybl = render2d.rectangle.Vertices.Pointer[0].uv[1]
				last_xbr = render2d.rectangle.Vertices.Pointer[3].uv[0]
				last_ybr = render2d.rectangle.Vertices.Pointer[3].uv[1]
				last_color_bottom_left = render2d.rectangle.Vertices.Pointer[1].color
				last_color_top_left = render2d.rectangle.Vertices.Pointer[0].color
				last_color_top_right = render2d.rectangle.Vertices.Pointer[2].color
				last_color_bottom_right = render2d.rectangle.Vertices.Pointer[3].color
			end
		end

		do
			local X, Y, W, H, SX, SY

			function render2d.SetRectUV(x, y, w, h, sx, sy)
				if not x then
					render2d.rectangle.Vertices.Pointer[1].uv[0] = 0
					render2d.rectangle.Vertices.Pointer[0].uv[1] = 0
					render2d.rectangle.Vertices.Pointer[1].uv[1] = 1
					render2d.rectangle.Vertices.Pointer[2].uv[0] = 1
				else
					sx = sx or 1
					sy = sy or 1
					local y = -y - h
					render2d.rectangle.Vertices.Pointer[1].uv[0] = x / sx
					render2d.rectangle.Vertices.Pointer[0].uv[1] = y / sy
					render2d.rectangle.Vertices.Pointer[1].uv[1] = (y + h) / sy
					render2d.rectangle.Vertices.Pointer[2].uv[0] = (x + w) / sx
				end

				render2d.rectangle.Vertices.Pointer[0].uv[0] = render2d.rectangle.Vertices.Pointer[1].uv[0]
				render2d.rectangle.Vertices.Pointer[2].uv[1] = render2d.rectangle.Vertices.Pointer[0].uv[1]
				render2d.rectangle.Vertices.Pointer[4].uv = render2d.rectangle.Vertices.Pointer[2].uv
				render2d.rectangle.Vertices.Pointer[3].uv[0] = render2d.rectangle.Vertices.Pointer[2].uv[0]
				render2d.rectangle.Vertices.Pointer[3].uv[1] = render2d.rectangle.Vertices.Pointer[1].uv[1]
				render2d.rectangle.Vertices.Pointer[5].uv = render2d.rectangle.Vertices.Pointer[1].uv
				update_vbo()
				X = x
				Y = y
				W = w
				H = h
				SX = sx
				SY = sy
			end

			function render2d.GetRectUV()
				return X, Y, W, H, SX, SY
			end

			function render2d.SetRectUV2(u1, v1, u2, v2)
				render2d.rectangle.Vertices.Pointer[1].uv[0] = u1
				render2d.rectangle.Vertices.Pointer[0].uv[1] = v1
				render2d.rectangle.Vertices.Pointer[1].uv[1] = u2
				render2d.rectangle.Vertices.Pointer[2].uv[0] = v2
				render2d.rectangle.Vertices.Pointer[0].uv[0] = render2d.rectangle.Vertices.Pointer[1].uv[0]
				render2d.rectangle.Vertices.Pointer[2].uv[1] = render2d.rectangle.Vertices.Pointer[0].uv[1]
				render2d.rectangle.Vertices.Pointer[4].uv = render2d.rectangle.Vertices.Pointer[2].uv
				render2d.rectangle.Vertices.Pointer[3].uv[0] = render2d.rectangle.Vertices.Pointer[2].uv[0]
				render2d.rectangle.Vertices.Pointer[3].uv[1] = render2d.rectangle.Vertices.Pointer[1].uv[1]
				render2d.rectangle.Vertices.Pointer[5].uv = render2d.rectangle.Vertices.Pointer[1].uv
				update_vbo()
			end
		end

		function render2d.SetRectColors(cbl, ctl, ctr, cbr)
			if not cbl then
				for i = 0, 5 do
					render2d.rectangle.Vertices.Pointer[i].color = {1, 1, 1, 1}
				end
			else
				render2d.rectangle.Vertices.Pointer[1].color = {cbl:Unpack()}
				render2d.rectangle.Vertices.Pointer[0].color = {ctl:Unpack()}
				render2d.rectangle.Vertices.Pointer[2].color = {ctr:Unpack()}
				render2d.rectangle.Vertices.Pointer[4].color = render2d.rectangle.Vertices.Pointer[2].color
				render2d.rectangle.Vertices.Pointer[3].color = {cbr:Unpack()}
				render2d.rectangle.Vertices.Pointer[5].color = render2d.rectangle.Vertices.Pointer[0]
			end

			update_vbo()
		end
	end
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

do -- stencil
	do
		local X, Y, W, H = 0, 0

		function render2d.SetScissor(x, y, w, h)
			X = x
			Y = y
			W = w or render.GetWidth()
			H = h or render.GetHeight()

			if not x then
				X = 0
				Y = 0
				render.SetScissor()
			else
				x, y = render2d.ScreenToWorld(-x, -y)
				render.SetScissor(-x, -y, w, h)
			end
		end

		function render2d.GetScissor()
			return X, Y, W, H
		end

		utility.MakePushPopFunction(render2d, "Scissor")
	end

	do
		function render2d.PushStencilRect(x, y, w, h)
			render.SetStencil(true)
			render.GetFrameBuffer():ClearStencil(0)
			render.StencilFunction("always", 1, 0xFFFFFFFF)
			render.StencilOperation("keep", "keep", "replace")
			render.SetColorMask(0, 0, 0, 0)
			render2d.PushTexture()
			render2d.DrawRect(x, y, w, h)
			render2d.PopTexture()
			render.SetColorMask(1, 1, 1, 1)
			render.StencilFunction("equal", 1)
		end

		function render2d.PopStencilRect()
			render.SetStencil(false)
		end
	end

	do
		local X, Y, W, H

		function render2d.EnableClipRect(x, y, w, h, i)
			i = i or 1
			render.SetStencil(true)
			render.GetFrameBuffer():ClearStencil(0) -- out = 0
			render.StencilOperation("keep", "replace", "replace")
			-- if true then stencil = 33 return true end
			render.StencilFunction("always", i)
			-- on fail, keep zero value
			-- on success replace it with 33
			-- write to the stencil buffer
			-- on fail is probably never reached
			render2d.PushTexture()
			render.SetColorMask(0, 0, 0, 0)
			render2d.DrawRect(x, y, w, h)
			render.SetColorMask(1, 1, 1, 1)
			render2d.PopTexture()
			-- if stencil == 33 then stencil = 33 return true else return false end
			render.StencilFunction("equal", i)
			X = x
			Y = y
			W = w
			H = h
		end

		function render2d.GetClipRect()
			return X or 0, Y or 0, W or render.GetWidth(), H or render.GetHeight()
		end

		function render2d.DisableClipRect()
			render.SetStencil(false)
		end
	end
end

render2d.Initialize()

event.AddListener("PostDraw", "draw_2d", function(cmd, dt)
	render2d.pipeline:Bind(cmd)
	cmd:BindVertexBuffer(render2d.rectangle, 0)
	cmd:BindIndexBuffer(render2d.rectangle_indices, 0, "uint16")
	render2d.cmd = cmd
	event.Call("Draw2D", dt)
end)

event.AddListener("FramebufferResized", "render2d", function(size)
	render2d.UpdateScreenSize(size)
end)

return render2d
