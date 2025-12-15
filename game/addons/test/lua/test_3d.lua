local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local Vec3 = require("structs.vec3")
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
		path = "/home/caps/projects/glTF-Sample-Assets-main/Models/Sponza/glTF/8481240838833932244.jpg",
		mip_map_levels = "auto",
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			mipmap_mode = "linear",
		},
	}
)
local mat = Material.New({
	albedo_texture = texture,
})
texture:GenerateMipMap()
render3d.SetMaterial(mat)
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

function events.Draw3D.test_3d(cmd, dt)
	center_transform:SetAngles(Ang3(system.GetTime(), system.GetTime(), system.GetTime()))
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)

	for i, transform in ipairs(transforms) do
		render3d.SetWorldMatrix(transform:GetWorldMatrix())
		render3d.UploadConstants(cmd)
		render3d.SetMaterial(mat)
		cmd:DrawIndexed(36)
	end
end
