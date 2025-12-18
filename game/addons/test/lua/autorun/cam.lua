local T = require("test.environment")
local ffi = require("ffi")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local Polygon3D = require("graphics.polygon_3d")
local event = require("event")
local Material = require("graphics.material")
local Texture = require("graphics.texture")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Quat = require("structs.quat")
local Ang3 = require("structs.ang3")
local Matrix44 = require("structs.matrix").Matrix44
local orientation = require("orientation")
local png_encode = require("file_formats.png.encode")
local white_tex

-- Create 6 quads for the inverted cube
local function create_face(pos, normal, up, color)
	if not white_tex then
		white_tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	end

	local poly = Polygon3D.New()
	local right = normal:GetCross(up)
	local size = 10 -- Large enough to cover the view
	-- Vertices for a quad
	local v1 = pos - right * size + up * size
	local v2 = pos + right * size + up * size
	local v3 = pos + right * size - up * size
	local v4 = pos - right * size - up * size
	-- CCW winding for looking from origin (inside)
	-- Triangle 1: v1, v4, v3
	poly:AddVertex({pos = v1, normal = -normal})
	poly:AddVertex({pos = v4, normal = -normal})
	poly:AddVertex({pos = v3, normal = -normal})
	-- Triangle 2: v1, v3, v2
	poly:AddVertex({pos = v1, normal = -normal})
	poly:AddVertex({pos = v3, normal = -normal})
	poly:AddVertex({pos = v2, normal = -normal})
	poly:Upload()
	return {
		poly = poly,
		material = Material.New(
			{
				base_color_factor = {color.x, color.y, color.z, 1},
				emissive_texture = white_tex,
				emissive_factor = {color.x * 100, color.y * 100, color.z * 100},
			}
		),
	}
end

local faces

local function draw_faces(cmd)
	if not faces then
		faces = {
			-- Forward (+Z): Blue
			create_face(Vec3(0, 0, 10), Vec3(0, 0, 1), Vec3(0, 1, 0), Vec3(0, 0, 1)),
			-- Backward (-Z): Yellow
			create_face(Vec3(0, 0, -10), Vec3(0, 0, -1), Vec3(0, 1, 0), Vec3(1, 1, 0)),
			-- Right (+X): Red
			create_face(Vec3(10, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(1, 0, 0)),
			-- Left (-X): Cyan
			create_face(Vec3(-10, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, 1, 1)),
			-- Up (+Y): Green
			create_face(Vec3(0, 10, 0), Vec3(0, 1, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)),
			-- Down (-Y): Magenta
			create_face(Vec3(0, -10, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(1, 0, 1)),
		}
	end

	for _, face in ipairs(faces) do
		render3d.SetWorldMatrix(Matrix44())
		render3d.SetMaterial(face.material)
		render3d.UploadConstants(cmd)
		face.poly:Draw(cmd)
	end
end

event.AddListener("Draw3D", "camera_test", function(cmd)
	draw_faces(cmd)
end)
