-- Debug test for coordinate system
-- Source engine style: X = forward, Y = left, Z = up
-- 
-- This creates 3 elongated bars pointing along each axis
-- so you can easily tell which direction is which.
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local event = require("event")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local build_cube = require("game.build_cube")
local Material = require("graphics.material")
-- Load ECS system and components
local ecs = require("ecs")
require("components.transform")
require("game.camera_movement")
-- Create cube mesh resources
local cube_vertices, cube_indices = build_cube(1.0)
local vertex_buffer = render.CreateBuffer({
	buffer_usage = "vertex_buffer",
	data_type = "float",
	data = cube_vertices,
})
local index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
-- RGB = XYZ (standard convention)s
local red_material = Material.New({base_color_factor = {1, 0, 0, 1}}) -- X axis
local green_material = Material.New({base_color_factor = {0, 1, 0, 1}}) -- Y axis
local blue_material = Material.New({base_color_factor = {0, 0, 1, 1}}) -- Z axis
local white_material = Material.New({base_color_factor = {1, 1, 1, 1}}) -- origin
-- Store entities with their materials for drawing
local entities = {}

local function create_box(name, position, scale, material)
	local entity = ecs.CreateEntity(name)
	entity:AddComponent("transform", {
		position = position,
		scale = scale or Vec3(1, 1, 1),
	})
	table.insert(entities, {entity = entity, material = material})
	return entity
end

-- ============================================
-- SIMPLE AXIS VISUALIZATION
-- RGB = XYZ convention
-- Each bar is 20 units long, 2 units thick
-- ============================================
local bar_length = 20
local bar_thickness = 2
-- Origin marker (white cube)
create_box("origin", Vec3(0, 0, 0), Vec3(3, 3, 3), white_material)
-- X axis = RED bar (pointing in +X direction, which is "forward" in Source)
-- Bar centered at X=12 so it goes from X=2 to X=22
create_box(
	"X_axis",
	Vec3(bar_length / 2 + 2, 0, 0),
	Vec3(bar_length, bar_thickness, bar_thickness),
	red_material
)
-- Y axis = GREEN bar (pointing in +Y direction, which is "left" in Source)
create_box(
	"Y_axis",
	Vec3(0, bar_length / 2 + 2, 0),
	Vec3(bar_thickness, bar_length, bar_thickness),
	green_material
)
-- Z axis = BLUE bar (pointing in +Z direction, which is "up" in Source)
create_box(
	"Z_axis",
	Vec3(0, 0, bar_length / 2 + 2),
	Vec3(bar_thickness, bar_thickness, bar_length),
	blue_material
)
-- ============================================
-- ROTATION TEST
-- Each "arrow" is a long thin box pointing in its local +X direction
-- We rotate them to verify pitch/yaw/roll behavior
-- ============================================
local arrow_material = Material.New({base_color_factor = {1, 1, 0, 1}}) -- Yellow arrows
-- Helper: create an arrow (elongated box) that points along local +X
local function create_arrow(name, position, angles, material)
	local entity = ecs.CreateEntity(name)
	entity:AddComponent(
		"transform",
		{
			position = position,
			scale = Vec3(8, 1, 1), -- Long along X, thin on Y and Z
		}
	)

	if angles then entity.transform:SetAngles(angles) end

	table.insert(entities, {entity = entity, material = material or arrow_material})
	return entity
end

local rot_offset = Vec3(0, -20, 0) -- Place rotation tests to the right of origin
-- Unrotated arrow (should point along world +X = RED direction)
create_arrow("arrow_no_rot", rot_offset + Vec3(0, 0, 0), nil, arrow_material)
-- Yaw +90° (rotate around Z axis) - should now point along world +Y = GREEN direction
-- Deg3(pitch, yaw, roll) so yaw is the second parameter
create_arrow(
	"arrow_yaw_90",
	rot_offset + Vec3(0, 0, 5),
	Deg3(0, 90, 0),
	Material.New({base_color_factor = {0, 1, 1, 1}})
)
-- Yaw -90° (rotate around Z axis) - should now point along world -Y direction
create_arrow(
	"arrow_yaw_-90",
	rot_offset + Vec3(0, 0, 10),
	Deg3(0, -90, 0),
	Material.New({base_color_factor = {1, 0, 1, 1}})
)
-- Pitch +90° (nose down) - should now point along world -Z = DOWN
create_arrow(
	"arrow_pitch_90",
	rot_offset + Vec3(0, 0, 15),
	Deg3(90, 0, 0),
	Material.New({base_color_factor = {1, 0.5, 0, 1}})
)
-- Pitch -90° (nose up) - should now point along world +Z = UP  
create_arrow(
	"arrow_pitch_-90",
	rot_offset + Vec3(0, 0, 20),
	Deg3(-90, 0, 0),
	Material.New({base_color_factor = {0.5, 0, 1, 1}})
)
-- Roll +90° - should spin around X axis (long axis of arrow)
create_arrow(
	"arrow_roll_90",
	rot_offset + Vec3(0, 0, 25),
	Deg3(0, 0, 90),
	Material.New({base_color_factor = {0.5, 1, 0.5, 1}})
)
print("")
print("=== COORDINATE SYSTEM TEST ===")
print("RGB = XYZ (standard convention)")
print("")
print("  WHITE cube = origin (0,0,0)")
print("  RED bar    = +X axis (Source: forward)")
print("  GREEN bar  = +Y axis (Source: left)")
print("  BLUE bar   = +Z axis (Source: up)")
print("")
print("=== ROTATION TEST (at Y=-20) ===")
print("All arrows point along local +X before rotation")
print("Deg3(pitch, yaw, roll)")
print("")
print("  YELLOW      = No rotation     -> should point world +X (toward RED)")
print("  CYAN        = Yaw +90°        -> should point world +Y (toward GREEN)")
print("  MAGENTA     = Yaw -90°        -> should point world -Y")
print("  ORANGE      = Pitch +90°      -> should point world -Z (DOWN)")
print("  PURPLE      = Pitch -90°      -> should point world +Z (UP)")
print("  LIGHT GREEN = Roll +90°       -> still points +X, but rotated around it")
print("")

-- Draw
function events.Draw3D.test_ecs_debug(cmd, dt)
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)

	for _, data in ipairs(entities) do
		local transform = data.entity.transform
		render3d.SetWorldMatrix(transform:GetMatrix())
		render3d.SetMaterial(data.material)
		render3d.UploadConstants(cmd)
		cmd:DrawIndexed(36)
	end
end
