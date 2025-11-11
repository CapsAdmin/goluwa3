local system = require("system")
local Ang3 = require("structs.Ang3")
local event = require("event")
local file_formats = require("file_formats")
local Transform = require("transform")
local renderer = require("graphics.pipeline_3d")

-- Programmatically generate cube geometry
local function generate_cube(size)
	size = size or 1.0
	local half = size / 2
	-- Define the 6 faces of a cube with their properties
	-- Each face: {normal, positions for 4 corners, UVs for 4 corners}
	local faces = {
		-- Front face (+Z)
		{
			normal = {0, 0, 1},
			positions = {
				{-half, -half, half},
				{half, -half, half},
				{half, half, half},
				{-half, half, half},
			},
		},
		-- Back face (-Z)
		{
			normal = {0, 0, -1},
			positions = {
				{half, -half, -half},
				{-half, -half, -half},
				{-half, half, -half},
				{half, half, -half},
			},
		},
		-- Right face (+X)
		{
			normal = {1, 0, 0},
			positions = {
				{half, -half, half},
				{half, -half, -half},
				{half, half, -half},
				{half, half, half},
			},
		},
		-- Left face (-X)
		{
			normal = {-1, 0, 0},
			positions = {
				{-half, -half, -half},
				{-half, -half, half},
				{-half, half, half},
				{-half, half, -half},
			},
		},
		-- Top face (+Y)
		{
			normal = {0, 1, 0},
			positions = {
				{-half, half, half},
				{half, half, half},
				{half, half, -half},
				{-half, half, -half},
			},
		},
		-- Bottom face (-Y)
		{
			normal = {0, -1, 0},
			positions = {
				{-half, -half, -half},
				{half, -half, -half},
				{half, -half, half},
				{-half, -half, half},
			},
		},
	}
	local uvs = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	local vertices = {}
	local indices = {}
	local vertex_count = 0

	for face_idx, face in ipairs(faces) do
		-- Add 4 vertices for this face
		for i = 1, 4 do
			local pos = face.positions[i]
			local normal = face.normal
			local uv = uvs[i]
			-- Position (vec3)
			table.insert(vertices, pos[1])
			table.insert(vertices, pos[2])
			table.insert(vertices, pos[3])
			-- Normal (vec3)
			table.insert(vertices, normal[1])
			table.insert(vertices, normal[2])
			table.insert(vertices, normal[3])
			-- UV (vec2)
			table.insert(vertices, uv[1])
			table.insert(vertices, uv[2])
		end

		-- Add 6 indices for this face (2 triangles) - counter-clockwise winding
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 1)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 3)
		vertex_count = vertex_count + 4
	end

	return vertices, indices
end

local cube_vertices, cube_indices = generate_cube(1.0)
local vertex_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = cube_vertices,
	}
)
local index_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
local img = file_formats.LoadPNG("assets/images/capsadmin.png")
local texture_image = renderer.device:CreateImage(
	img.width,
	img.height,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst", "transfer_src"},
	"device_local"
)
renderer:UploadToImage(
	texture_image,
	img.buffer:GetBuffer(),
	texture_image:GetWidth(),
	texture_image:GetHeight()
)
local texture_view = texture_image:CreateView()
local texture_sampler = renderer.device:CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
local camera = require("graphics.camera").CreateCamera()
local transform = Transform.New()
renderer.UpdateDescriptorSet("combined_image_sampler", 1, 0, texture_view, texture_sampler)

event.AddListener("Draw3D", "cube", function(cmd, camera, dt)
	transform:SetAngles(Ang3(system.GetTime(), system.GetTime(), system.GetTime()))
	renderer.SetWorldMatrix(transform:GetMatrix())
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)
	cmd:DrawIndexed(36, 1, 0, 0, 0)
end)

require("main_loop")
