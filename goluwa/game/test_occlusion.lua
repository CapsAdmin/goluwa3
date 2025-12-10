local ecs = require("ecs")
local Vec3 = require("structs.vec3")
local AABB = require("structs.aabb")
local Material = require("graphics.material")
local render3d = require("graphics.render3d")
local render = require("graphics.render")
local build_cube = require("game.build_cube")
local Light = require("components.light")
require("game.camera_movement")
require("components.transform")
require("components.model")

-- Helper function to create a plane mesh
local function build_plane(width, height)
	local vertices = {
		-- Position (x,y,z), Normal (x,y,z), UV (u,v)
		-width / 2,
		0,
		-height / 2,
		0,
		1,
		0,
		0,
		0, -- bottom-left
		width / 2,
		0,
		-height / 2,
		0,
		1,
		0,
		1,
		0, -- bottom-right
		width / 2,
		0,
		height / 2,
		0,
		1,
		0,
		1,
		1, -- top-right
		-width / 2,
		0,
		height / 2,
		0,
		1,
		0,
		0,
		1, -- top-left
	}
	local indices = {
		0,
		1,
		2, -- first triangle
		0,
		2,
		3, -- second triangle
	}
	return vertices, indices
end

-- Helper function to create a wall mesh (vertical plane)
local function build_wall(width, height)
	local vertices = {
		-- Position (x,y,z), Normal (x,y,z), UV (u,v)
		-width / 2,
		-height / 2,
		0,
		0,
		0,
		1,
		0,
		0, -- bottom-left
		width / 2,
		-height / 2,
		0,
		0,
		0,
		1,
		1,
		0, -- bottom-right
		width / 2,
		height / 2,
		0,
		0,
		0,
		1,
		1,
		1, -- top-right
		-width / 2,
		height / 2,
		0,
		0,
		0,
		1,
		0,
		1, -- top-left
	}
	local indices = {
		0,
		1,
		2, -- first triangle
		0,
		2,
		3, -- second triangle
	}
	return vertices, indices
end

-- Create cube buffers
local cube_vertices, cube_indices = build_cube(1.0)
local cube_vertex_buffer = render.CreateBuffer({
	buffer_usage = "vertex_buffer",
	data_type = "float",
	data = cube_vertices,
})
local cube_index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
-- Create plane buffers (floor)
local plane_vertices, plane_indices = build_plane(20, 20)
local plane_vertex_buffer = render.CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = plane_vertices,
	}
)
local plane_index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = plane_indices,
	}
)
-- Create wall buffers
local wall_vertices, wall_indices = build_wall(15, 8)
local wall_vertex_buffer = render.CreateBuffer({
	buffer_usage = "vertex_buffer",
	data_type = "float",
	data = wall_vertices,
})
local wall_index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = wall_indices,
	}
)
-- Create materials with different colors
local red_mat = Material.New({base_color_factor = {1, 0.2, 0.2, 1}})
local green_mat = Material.New({base_color_factor = {0.2, 1, 0.2, 1}})
local blue_mat = Material.New({base_color_factor = {0.2, 0.2, 1, 1}})
local yellow_mat = Material.New({base_color_factor = {1, 1, 0.2, 1}})
local cyan_mat = Material.New({base_color_factor = {0.2, 1, 1, 1}})
local magenta_mat = Material.New({base_color_factor = {1, 0.2, 1, 1}})
local white_mat = Material.New({base_color_factor = {0.9, 0.9, 0.9, 1}})
local gray_mat = Material.New({base_color_factor = {0.5, 0.5, 0.5, 1}})
local materials = {red_mat, green_mat, blue_mat, yellow_mat, cyan_mat, magenta_mat}
local entities = {}
-- Create floor plane
local floor = ecs.CreateEntity("floor", ecs.GetWorld())
floor:AddComponent("transform", {
	position = Vec3(0, -2, 0),
	scale = Vec3(1, 1, 1),
})
local floor_model = floor:AddComponent("model")
floor_model:AddPrimitive(
	{
		vertex_buffer = plane_vertex_buffer,
		index_buffer = plane_index_buffer,
		index_count = 6,
		index_type = "uint32",
		material = gray_mat,
		aabb = AABB(-10, 0, -10, 10, 0, 10),
	}
)
table.insert(entities, floor)
-- Create occluding wall
local wall = ecs.CreateEntity("wall", ecs.GetWorld())
wall:AddComponent("transform", {
	position = Vec3(0, 2, -5),
	scale = Vec3(1, 1, 1),
})
local wall_model = wall:AddComponent("model")
wall_model:AddPrimitive(
	{
		vertex_buffer = wall_vertex_buffer,
		index_buffer = wall_index_buffer,
		index_count = 6,
		index_type = "uint32",
		material = white_mat,
		aabb = AABB(-7.5, -4, 0, 7.5, 4, 0),
	}
)
table.insert(entities, wall)
-- Create objects behind the wall (should be occluded)
local behind_wall_objects = 6

for i = 1, behind_wall_objects do
	local angle = (i / behind_wall_objects) * math.pi * 2
	local radius = 3
	local x = math.cos(angle) * radius
	local y = (i - behind_wall_objects / 2) * 1.5
	local entity = ecs.CreateEntity(string.format("occluded_cube_%d", i), ecs.GetWorld())
	entity:AddComponent("transform", {
		position = Vec3(x, y, -10),
		scale = Vec3(1, 1, 1),
	})
	local model = entity:AddComponent("model")
	local mat = materials[(i % #materials) + 1]
	model:AddPrimitive(
		{
			vertex_buffer = cube_vertex_buffer,
			index_buffer = cube_index_buffer,
			index_count = 36,
			index_type = "uint32",
			material = mat,
			aabb = AABB(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5),
		}
	)
	table.insert(entities, entity)
end

-- Create some objects in front of the wall (visible)
local front_objects = 4

for i = 1, front_objects do
	local x = (i - front_objects / 2 - 0.5) * 3
	local entity = ecs.CreateEntity(string.format("visible_cube_%d", i), ecs.GetWorld())
	entity:AddComponent("transform", {
		position = Vec3(x, 1, -2),
		scale = Vec3(1, 1, 1),
	})
	local model = entity:AddComponent("model")
	local mat = materials[(i % #materials) + 1]
	model:AddPrimitive(
		{
			vertex_buffer = cube_vertex_buffer,
			index_buffer = cube_index_buffer,
			index_count = 36,
			index_type = "uint32",
			material = mat,
			aabb = AABB(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5),
		}
	)
	table.insert(entities, entity)
end

local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(1, 0.5, -0.5):Normalize(),
		color = {1.0, 1.0, 1.0},
		intensity = 2.0,
		name = "Sun",
		cast_shadows = false,
	}
)
render3d.SetSunLight(sun)
