local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local event = require("event")
local render = require("graphics.render")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
local gltf = require("gltf")
local Material = require("graphics.material")
local Matrix44 = require("structs.matrix").Matrix44
-- Load ECS system and components
local ecs = require("ecs")
require("components.transform")
require("components.model")
local Light = require("components.light")
-- Load glTF model
local gltf_result = assert(
	gltf.Load(
		"/home/caps/projects/glTF-Sample-Assets-main/Models/Sponza/glTF/Sponza.gltf"
	)
)
-- Create entity hierarchy from glTF, parented to world so ECS queries find it
local scene_root = gltf.CreateEntityHierarchy(gltf_result, ecs.GetWorld())
-- Configure scene transform (coordinate conversion now happens in gltf loader)
scene_root.transform:SetPosition(Vec3(0, 0, 0))
scene_root.transform:SetAngles(Deg3(0, 0, 0))
scene_root.transform:SetSize(20)
local default_material = Material.GetDefault()
require("game.camera_movement")
render3d.cam:SetPosition(Vec3(0, 2, 0))
render3d.cam:SetAngles(Ang3(0, 0, 0))
-- Create sun light using ECS (direction in Z-up: x=forward, y=left, z=up)
local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(1,0.5,1), -- Shining down and to the side
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
		cast_shadows = true,
		shadow_config = {
			ortho_size = 100.0,
			near_plane = 1.0,
			far_plane = 500.0,
		},
	}
)
render3d.SetSunLight(sun)
