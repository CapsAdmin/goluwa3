local Vec2 = require("structs.vec2")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local event = require("event")
local file_formats = require("file_formats")
local render = require("graphics.render")
local Texture = require("graphics.texture")
local gfx = require("graphics.gfx")
local system = require("system")
local render2d = require("graphics.render2d")

if false then
	local zsnes = Texture.New(
		{
			path = "assets/images/zsnes.png",
			min_filter = "nearest",
			mag_filter = "nearest",
		}
	)
	local skin = {}

	do
		local function R(u, v, w, h)
			local meta = {}
			meta.__index = meta

			function meta:corner_size(v)
				self.corner_size = v
				return self
			end

			function meta:color(v)
				self.corner = v
				return self
			end

			function meta:no_size()
				self.size = Vec2(self.rect.w, self.rect.h)
				return self
			end

			return setmetatable({
				rect = Rect(u, v, w, h),
			}, meta)
		end

		skin.button_inactive = R(480, 0, 31, 31):corner_size(4)
		skin.button_active = R(480, 96, 31, 31):corner_size(4)
		skin.close_inactive = R(32, 452, 9, 7)
		skin.close_active = R(96, 452, 9, 7)
		skin.minimize_inactive = R(131, 452, 9, 7)
		skin.minimize_active = R(195, 452, 9, 7)
		skin.maximize_inactive = R(225, 484, 9, 7)
		skin.maximize_active = R(289, 484, 9, 7)
		skin.maximize2_inactive = R(225, 452, 9, 7)
		skin.maximize2_active = R(289, 452, 9, 7)
		skin.up_inactive = R(464, 224, 15, 15)
		skin.up_active = R(480, 224, 15, 15)
		skin.down_inactive = R(464, 256, 15, 15)
		skin.down_active = R(480, 256, 15, 15)
		skin.left_inactive = R(464, 208, 15, 15)
		skin.left_active = R(480, 208, 15, 15)
		skin.right_inactive = R(464, 240, 15, 15)
		skin.right_active = R(480, 240, 15, 15)
		skin.menu_right_arrow = R(472, 116, 4, 7)
		skin.list_up_arrow = R(385, 114, 5, 3)
		skin.list_down_arrow = R(385, 122, 5, 3)
		skin.check = R(449, 34, 7, 7)
		skin.uncheck = R(465, 34, 7, 7)
		skin.rad_check = R(449, 65, 7, 7)
		skin.rad_uncheck = R(465, 65, 7, 7)
		skin.plus = R(451, 99, 5, 5)
		skin.minus = R(467, 99, 5, 5)
		skin.scroll_vertical_track = R(384, 208, 15, 127):corner_size(4)
		skin.scroll_vertical_handle_inactive = R(400, 208, 15, 127):corner_size(4)
		skin.scroll_vertical_handle_active = R(432, 208, 15, 127):corner_size(4)
		skin.scroll_horizontal_track = R(384, 128, 127, 15):corner_size(4)
		skin.scroll_horizontal_handle_inactive = R(384, 144, 127, 15):corner_size(4)
		skin.scroll_horizontal_handle_active = R(384, 176, 127, 15):corner_size(4)
		skin.button_rounded_active = R(480, 64, 31, 31):corner_size(4)
		skin.button_rounded_inactive = R(480, 64, 31, 31):corner_size(4)
		skin.tab_active = R(1, 384, 61, 24):corner_size(8)
		skin.tab_inactive = R(128, 384, 61, 24):corner_size(16)
		skin.tab_frame = R(320, 384 + 19, 63, 63 - 19):corner_size(4)
		skin.menu_select = R(130, 258, 123, 27):corner_size(16)
		skin.frame = R(480, 32, 31, 31):corner_size(16)
		skin.frame2 = R(320, 384 + 19, 63, 63 - 19):corner_size(4)
		skin.frame_bar = R(320, 384, 63, 19):corner_size(2)
		skin.property = R(256, 256, 63, 127):corner_size(4)
		skin.gradient = R(0, 128, 127, 21):no_size()
		skin.gradient1 = R(480, 96, 31, 31):corner_size(16)
		skin.gradient2 = R(480, 96, 31, 31):corner_size(16)
		skin.gradient3 = R(480, 96, 31, 31):corner_size(16)
		skin.text_edit = R(256, 256, 63, 127):corner_size(4)
	end

	local scale = 4

	local function draw(style, x, y, w, h, corner_size)
		corner_size = corner_size or 4
		local rect = skin[style].rect
		gfx.DrawNinePatch(x, y, w, h, rect.w, rect.h, corner_size, rect.x, rect.y, scale)
	end

	local sorted = {}

	for k, v in pairs(skin) do
		if type(v) == "table" then
			v.name = k
			table.insert(sorted, v)
		end
	end

	table.sort(sorted, function(a, b)
		return a.name > b.name
	end)

	event.AddListener("Draw2D", "test", function(dt)
		render2d.SetTexture(zsnes)
		render2d.SetColor(1, 1, 1, 1)
		local x = 10
		local y = 10
		local w = 50
		local h = 50

		for i, v in ipairs(sorted) do
			draw(v.name, x, y, w, h, 2)
			x = x + w + 4

			if x > 512 then
				x = 0
				y = y + h + 4
			end
		end
	end)
end

if false then
	event.AddListener("Draw2D", "test_bezier", function(dt)
		render2d.DrawTriangle(100, 100, 50, 50, os.clock())
	end)
end

if false then
	local rope = Texture.New(
		{
			path = "assets/images/rope.png",
			min_filter = "linear",
			mag_filter = "linear",
		}
	)
	local QuadricBezierCurve = require("graphics.quadric_bezier_curve")
	local curve = QuadricBezierCurve.New()
	curve:Add(Vec2(0, 0))
	curve:Add(Vec2(1, 0))
	curve:Add(Vec2(1, 1))
	curve:Add(Vec2(0, 1))
	local mesh, index_count = curve:ConstructMesh(Vec2(0, 0.1), 8, 0.3)

	event.AddListener("Draw2D", "test_bezier", function(dt)
		render2d.SetTexture(rope)
		render2d.SetBlendMode("alpha")
		render2d.SetColor(1, 1, 1, 1)
		render2d.BindMesh(mesh)

		do
			render2d.PushMatrix(50, 50, 500, 500)
			render2d.UploadConstants(render2d.cmd)
			mesh:DrawIndexed(render2d.cmd, index_count)
			render2d.PopMatrix()
		end
	end)
end

if false then
	event.AddListener("Draw2D", "test", function(dt)
		gfx.DrawText("Hello world", 20, 400)
		gfx.DrawRoundedRect(100, 100, 200, 200, 50)
		gfx.DrawCircle(400, 300, 50, 5, 6)
		gfx.DrawFilledCircle(400, 500, 50)
		gfx.DrawLine(500, 500, 600, 550, 10)
		gfx.DrawOutlinedRect(500, 100, 100, 50, 5, 1, 0, 0, 1)
	end)
end

if true then
	local ffi = require("ffi")
	local WORKGROUP_SIZE = 16
	local pipeline = render.CreateComputePipeline(
		{
			push_constant_ranges = {
				{stage = "compute", offset = 0, size = 16},
			},
			shader = [[
				#version 450

				layout (local_size_x = 16, local_size_y = 16) in;

				layout (binding = 0, rgba8) uniform readonly image2D inputImage;
				layout (binding = 1, rgba8) uniform writeonly image2D outputImage;

				layout(push_constant) uniform PushConstants {
					uint iFrame;
					vec2 iMouse;
					float mousePressed;
				} pc;

				const float pi = 3.1415;
				const float pi2 = pi/2.0;

				float random(vec2 fragCoord)
				{
					return fract(sin(dot(fragCoord.xy, vec2(12.9898,78.233))) * 43758.5453);  
				}

				vec4 get_pixel(ivec2 fragCoord, float x_offset, float y_offset)
				{
					ivec2 size = imageSize(inputImage);
					vec2 offset = vec2(x_offset, y_offset) / vec2(size);
					vec2 uv = (vec2(fragCoord) / vec2(size)) + offset;
					ivec2 pixel = ivec2(uv * vec2(size));
					return imageLoad(inputImage, pixel);
				}

				float step_simulation(ivec2 fragCoord)
				{
					ivec2 size = imageSize(inputImage);
					float val = get_pixel(fragCoord, 0.0, 0.0).r;
					
					val += random(vec2(fragCoord))*val*0.15;
					
					val = get_pixel(
						fragCoord,
						sin(get_pixel(fragCoord, val, 0.0).r  - get_pixel(fragCoord, -val, 0.0).r + pi) * val * 0.4, 
						cos(get_pixel(fragCoord, 0.0, -val).r - get_pixel(fragCoord, 0.0 , val).r - pi2) * val * 0.4
					).r;
					
					val *= 1.0001;
					
					return val;
				}

				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(inputImage);

					if (pos.x >= size.x || pos.y >= size.y) {
						return;
					}

					float val = step_simulation(pos);
				
					if(pc.iFrame == 0)
						val = 
							random(vec2(pos))*length(vec2(size))/100.0 + 
							smoothstep(length(vec2(size))/2.0, 0.5, length(vec2(size) * 0.5 - vec2(pos)))*25.0;
					
					if (pc.mousePressed > 0.0) 
						val += smoothstep(length(vec2(size))/10.0, 0.5, length(pc.iMouse - vec2(pos)));
						
					imageStore(outputImage, pos, vec4(val, val, val, 1.0));
				}
			]],
			workgroup_size = WORKGROUP_SIZE,
			descriptor_set_count = 2,
			descriptor_layout = {
				{binding_index = 0, type = "storage_image", stageFlags = "compute", count = 1},
				{binding_index = 1, type = "storage_image", stageFlags = "compute", count = 1},
			},
			descriptor_pool = {
				{type = "storage_image", count = 4},
			},
		}
	)
	local mouse_pressed = 0
	local PushConstants = ffi.typeof([[
		struct {
			uint32_t iFrame;
			float iMouse[2];
			float mousePressed;
		}
	]])
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	local Fence = require("graphics.vulkan.internal.fence")
	local window = require("window")
	local input = require("input")

	local function compute()
		cmd:Reset()
		cmd:Begin()
		cmd:PushConstants(
			pipeline.pipeline_layout,
			"compute",
			0,
			ffi.sizeof(PushConstants),
			PushConstants(
				{
					iFrame = system.GetFrameNumber(),
					iMouse = {window.GetMousePosition():Unpack()},
					mousePressed = input.IsMouseDown("button_1") and 1 or 0,
				}
			)
		)
		pipeline:Dispatch(cmd)
		cmd:End()
		local device = render.GetDevice()
		local fence = Fence.New(device)
		render.GetQueue():SubmitAndWait(device, cmd, fence)
	end

	event.AddListener("Update", "draw_2d", function()
		compute()
	end)

	local presentation_texture
	local presentation_pipeline
	local presentation_mip0_view
	local presentation_command_pool
	local presentation_cmd
	local presentation_fence

	local function init_presentation()
		if presentation_texture then return end

		local Texture = require("graphics.texture")
		local ImageView = require("graphics.vulkan.internal.image_view")
		local CommandPool = require("graphics.vulkan.internal.command_pool")
		local Fence = require("graphics.vulkan.internal.fence")
		local device = render.GetDevice()
		presentation_texture = Texture.New(
			{
				width = 512,
				height = 512,
				format = "R8G8B8A8_UNORM",
				min_filter = "linear",
				mag_filter = "linear",
				mip_map_levels = 1,
				usage = {"sampled", "color_attachment", "transfer_src"},
			}
		)
		presentation_mip0_view = ImageView.New(
			{
				device = device,
				image = presentation_texture.image,
				format = presentation_texture.format,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		presentation_pipeline = render.CreateGraphicsPipeline(
			{
				dynamic_states = {"viewport", "scissor"},
				color_format = presentation_texture.format,
				samples = "1",
				shader_stages = {
					{
						type = "vertex",
						code = [[
						#version 450

						vec2 positions[3] = vec2[](
							vec2(-1.0, -1.0),
							vec2( 3.0, -1.0),
							vec2(-1.0,  3.0)
						);

						layout(location = 0) out vec2 frag_uv;

						void main() {
							vec2 pos = positions[gl_VertexIndex];
							gl_Position = vec4(pos, 0.0, 1.0);
							frag_uv = pos * 0.5 + 0.5;
						}
					]],
						input_assembly = {
							topology = "triangle_list",
							primitive_restart = false,
						},
					},
					{
						type = "fragment",
						code = [[
						#version 450

						layout(location = 0) in vec2 in_uv;
						layout(location = 0) out vec4 out_color;
						layout(binding = 0) uniform sampler2D iChannel0;

						void mainImage( out vec4 fragColor, in vec2 fragCoord, vec2 iResolution )
						{
							float val = texture(iChannel0, fragCoord/iResolution).r;
						
							vec4 color = pow(vec4(cos(val), tan(val), sin(val), 1.0) * 0.5 + 0.5, vec4(0.5));
							
							vec2 q = fragCoord/iResolution;
							
							vec3 e = vec3(vec2(1.0)/iResolution,0.);
							float p10 = texture(iChannel0, q-e.zy).x;
							float p01 = texture(iChannel0, q-e.xz).x;
							float p21 = texture(iChannel0, q+e.xz).x;
							float p12 = texture(iChannel0, q+e.zy).x;
								
							vec3 grad = normalize(vec3(p21 - p01, p12 - p10, 1.));
							vec3 light = normalize(vec3(.2,-.25,.7));
							float diffuse = dot(grad,light);
							float spec = pow(max(0.,-reflect(light,grad).z),32.0);
							
							fragColor = (color * diffuse) + spec;
						}

						void main() {
							mainImage(out_color, in_uv * vec2(512.0, 512.0), vec2(512.0, 512.0));
						}
					]],
						descriptor_sets = {
							{binding_index = 0, type = "combined_image_sampler", count = 1},
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
							src_color_blend_factor = "one",
							dst_color_blend_factor = "zero",
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
					depth_write = false,
					depth_compare_op = "less",
					depth_bounds_test = false,
					stencil_test = false,
				},
			}
		)
		device:UpdateDescriptorSet(
			"combined_image_sampler",
			presentation_pipeline.descriptor_sets[1],
			0,
			pipeline.storage_textures[1]:GetView(),
			pipeline.storage_textures[1].sampler
		)
		presentation_command_pool = render.GetCommandPool()
		presentation_cmd = presentation_command_pool:AllocateCommandBuffer()
		presentation_fence = Fence.New(device)
	end

	local function draw_presentation_effect()
		local device = render.GetDevice()
		local queue = render.GetQueue()
		presentation_cmd:Reset()
		presentation_cmd:Begin()
		presentation_cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = "color_attachment_output",
				imageBarriers = {
					{
						image = presentation_texture.image,
						srcAccessMask = "none",
						dstAccessMask = "color_attachment_write",
						oldLayout = "undefined",
						newLayout = "color_attachment_optimal",
					},
				},
			}
		)
		presentation_pipeline:Bind(presentation_cmd)
		presentation_cmd:BeginRendering(
			{
				colorImageView = presentation_mip0_view,
				extent = {width = 512, height = 512},
				clearColor = {0, 0, 0, 1},
			}
		)
		presentation_cmd:SetViewport(0.0, 0.0, 512, 512, 0.0, 1.0)
		presentation_cmd:SetScissor(0, 0, 512, 512)
		presentation_cmd:BindDescriptorSets(
			"graphics",
			presentation_pipeline.pipeline_layout,
			{presentation_pipeline.descriptor_sets[1]},
			0
		)
		presentation_cmd:Draw(3, 1, 0, 0)
		presentation_cmd:EndRendering()
		presentation_cmd:PipelineBarrier(
			{
				srcStage = "color_attachment_output",
				dstStage = "fragment",
				imageBarriers = {
					{
						image = presentation_texture.image,
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
					},
				},
			}
		)
		presentation_cmd:End()
		queue:SubmitAndWait(device, presentation_cmd, presentation_fence)
	end

	event.AddListener("Draw2D", "test_bezier", function(dt)
		init_presentation()
		draw_presentation_effect()
		render2d.SetTexture(presentation_texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, 512, 512)
	end)
end
