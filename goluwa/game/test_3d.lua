local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3").Vec3d
local Vec3f = require("structs.vec3").Vec3f
local event = require("event")
local Transform = require("transform")
local render = require("graphics.render")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
local build_cube = require("game.build_cube")
local Texture = require("graphics.texture")
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

event.AddListener("Draw3D", "test_3d", function(cmd, dt)
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
