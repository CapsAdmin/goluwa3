local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3").Vec3d
local event = require("event")
local file_formats = require("file_formats")
local Transform = require("transform")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local build_cube = require("game.build_cube")
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
local img = file_formats.LoadPNG("assets/images/capsadmin.png")
local texture_image = render.CreateImage(
	img.width,
	img.height,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst", "transfer_src"},
	"device_local"
)
render.UploadToImage(
	texture_image,
	img.buffer:GetBuffer(),
	texture_image:GetWidth(),
	texture_image:GetHeight()
)
local texture_view = texture_image:CreateView()
local texture_sampler = render.CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
_G.refs = {texture_image, texture_view, texture_sampler, vertex_buffer, index_buffer}
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
render3d.UpdateDescriptorSet("combined_image_sampler", 1, 0, texture_view, texture_sampler)

event.AddListener("Draw3D", "draw_cube", function(cmd, dt)
	center_transform:SetAngles(Ang3(system.GetTime(), system.GetTime(), system.GetTime()))
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)

	for _, transform in ipairs(transforms) do
		render3d.SetWorldMatrix(transform:GetMatrix())
		render3d.UploadConstants(cmd)
		cmd:DrawIndexed(36, 1, 0, 0, 0)
	end
end)

if true then
	local gfx = require("graphics.gfx")
	local render2d = require("graphics.render2d")

	event.AddListener("Draw2D", "test", function(dt)
		render2d.SetColor(1, 0, 0)
		gfx.DrawFilledCircle(100, 100, 50)
		render2d.SetColor(1, 0, 0)
		render2d.DrawRect(10, 10, 30, 30)
		render2d.SetColor(0, 1, 0)
		render2d.DrawRect(50, 50, 30, 30)
		render2d.SetColor(0, 0, 1)
		render2d.DrawRect(90, 90, 30, 30)
	end)
end

event.AddListener("KeyInput", "escape_shutdown", function(key, press)
	if key == "escape" and press then system.ShutDown() end
end)
