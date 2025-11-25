local Vec2 = require("structs.vec2")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local event = require("event")
local file_formats = require("file_formats")
local render = require("graphics.render")
local Texture = require("graphics.texture")
local gfx = require("graphics.gfx")
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
	local GAME_WIDTH, GAME_HEIGHT
	local pipeline = render.CreateComputePipeline(
		{
			shader = [[
				#version 450

				layout (local_size_x = 16, local_size_y = 16) in;

				layout (binding = 0, rgba8) uniform readonly image2D inputImage;
				layout (binding = 1, rgba8) uniform writeonly image2D outputImage;

				void main() {
					ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(inputImage);

					if (pos.x >= size.x || pos.y >= size.y) {
						return;
					}

					// Count alive neighbors (wrapping at edges)
					int count = 0;
					for (int dy = -1; dy <= 1; dy++) {
						for (int dx = -1; dx <= 1; dx++) {
							if (dx == 0 && dy == 0) continue; 

							ivec2 neighbor = ivec2(
								(pos.x + dx + size.x) % size.x, 
								(pos.y + dy + size.y) % size.y
							);

							vec4 cell = imageLoad(inputImage, neighbor);
							if (cell.r > 0.5) {
								count++;
							}
						}
					}

					// Current cell state
					vec4 current = imageLoad(inputImage, pos);
					bool alive = current.r > 0.5;

					// Conway's Game of Life rules
					bool newState = false;
					if (alive) {
						newState = (count == 2 || count == 3);
					} else {
						newState = (count == 3);
					}

					// Write result
					vec4 color = newState ? vec4(1.0, 1.0, 1.0, 1.0) : vec4(0.0, 0.0, 0.0, 1.0);
					imageStore(outputImage, pos, color);
				}
			]],
			workgroup_size = WORKGROUP_SIZE,
			descriptor_set_count = 2, -- 2 sets for ping-pong
			descriptor_layout = {
				{binding_index = 0, type = "storage_image", stageFlags = "compute", count = 1}, -- input
				{binding_index = 1, type = "storage_image", stageFlags = "compute", count = 1}, -- output
			},
			descriptor_pool = {
				{type = "storage_image", count = 4}, -- 2 bindings * 2 sets
			},
		}
	)

	event.AddListener("PreDraw", "draw_2d", function(cmd)
		pipeline:Dispatch(cmd)
	end)

	event.AddListener("Draw2D", "test_bezier", function(dt)
		render2d.SetTexture(pipeline.storage_textures[1])
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, 512, 512)
	end)
end
