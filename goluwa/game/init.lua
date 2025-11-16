local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3").Vec3d
local Vec3f = require("structs.vec3").Vec3f
local Vec2f = require("structs.vec2").Vec2f
local Colorf = require("structs.color").Colorf
local event = require("event")
local file_formats = require("file_formats")
local Transform = require("transform")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local build_cube = require("game.build_cube")
local Texture = require("graphics.texture")
local gfx = require("graphics.gfx")
local render2d = require("graphics.render2d")
require("game.camera_movement")
local cube_vertices, cube_indices = build_cube(1.0)
local vertex_buffer = render.CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = cube_vertices,
	}
)
local index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
local texture = Texture.New(
	{
		path = "assets/images/capsadmin.png",
		mip_map_levels = "auto",
		min_filter = "linear_mipmap_linear",
		mag_filter = "linear",
	}
)
texture:GenerateMipMap()
render3d.SetTexture(texture)
local transforms = {}

for i = 1, 100 do
	local transform = Transform.New()
	transform:SetPosition(Vec3(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20)))
	transform:SetAngles(
		Ang3(
			math.random() * math.pi * 2,
			math.random() * math.pi * 2,
			math.random() * math.pi * 2
		)
	)
	transform:SetSize(math.random() * 4 + 1)
	transforms[i] = transform
end

local center_transform = Transform.New()
center_transform:SetSize(5)
table.insert(transforms, center_transform)

event.AddListener("Draw3D", "draw_cube", function(cmd, dt)
	center_transform:SetAngles(Ang3(system.GetTime(), system.GetTime(), system.GetTime()))
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)

	for i, transform in ipairs(transforms) do
		render3d.SetWorldMatrix(transform:GetMatrix())
		render3d.UploadConstants(cmd)

		if i == 10 then
			render3d.SetTexture(gfx.quadrant_circle_texture)
		else
			render3d.SetTexture(texture)
		end

		cmd:DrawIndexed(36)
	end
end)

if true then
	local vertex_buffer = render2d.CreateMesh(3)
	vertex_buffer:SetVertex(0, {pos = Vec3f(300, 300, 0), uv = Vec2f(0, 0), color = Colorf(1, 0, 0, 1)})
	vertex_buffer:SetVertex(1, {pos = Vec3f(400, 300, 0), uv = Vec2f(1, 0), color = Colorf(0, 0, 1, 1)})
	vertex_buffer:SetVertex(2, {pos = Vec3f(300, 400, 0), uv = Vec2f(0, 1), color = Colorf(0, 1, 0, 1)})
	local IndexBuffer = require("graphics.index_buffer")
	local indices = {0, 1, 2}
	local index_buffer = IndexBuffer.New(indices, "uint16")
	local index_count = #indices

	event.AddListener("Draw2D", "test_bezier", function(dt)
		render2d.SetTexture()
		render2d.SetColor(1, 1, 1, 1)
		render2d.BindMesh(vertex_buffer, index_buffer)
		render2d.UploadConstants(render2d.cmd)
		render2d.DrawIndexedMesh(index_count)
	end)
end

if false then
	local QuadricBezierCurve = require("graphics.quadric_bezier_curve")
	local curve = QuadricBezierCurve.New(3)
	curve:Set(1, Vec2f(-300, 0), Vec2f(-200, -200))
	curve:Set(2, Vec2f(0, 0), Vec2f(-100, 200))
	curve:Set(3, Vec2f(200, 0), Vec2f(100, -200))
	local mesh, index_buffer, index_count = curve:ConstructPoly()

	event.AddListener("Draw2D", "test_bezier", function(dt)
		render2d.SetTexture(gfx.quadrant_circle_texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.BindMesh(mesh, index_buffer) -- Bind the bezier mesh
		render2d.UploadConstants(render2d.cmd)
		render2d.DrawIndexedMesh(index_count)
	end)
end

if false then
	event.AddListener("Draw2D", "test", function(dt)
		render2d.BindMesh(render2d.vertex_buffer, render2d.index_buffer) -- Bind default buffers
		gfx.DrawText("Hello world", 20, 400)
		gfx.DrawRoundedRect(100, 100, 200, 200, 50)
		gfx.DrawCircle(400, 300, 50, 5, 6)
		gfx.DrawFilledCircle(400, 500, 50)
		gfx.DrawLine(500, 500, 600, 550, 10)
		gfx.DrawOutlinedRect(500, 100, 100, 50, 5, 1, 0, 0, 1)
	end)
end
