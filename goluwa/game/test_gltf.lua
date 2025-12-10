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
local Light = require("components.light")
-- DEBUG: Enable to test geometry without textures (all white)
gltf.debug_white_textures = false
gltf.debug_print_nodes = true
-- Load glTF model
local path = nil
path = "/home/caps/projects/glTF-Sample-Assets-main/Models/ABeautifulGame/glTF/ABeautifulGame.gltf"
path = "/home/caps/projects/RTXDI-Assets/bistro/bistro.gltf"
path = "/home/caps/projects/glTF-Sample-Assets-main/Models/Sponza/glTF/Sponza.gltf"
local gltf_result = assert(gltf.Load(path))
-- Create entity hierarchy from glTF, parented to world so ECS queries find it
local scene_root = gltf.CreateEntityHierarchy(
	gltf_result,
	ecs.GetWorld(),
	{
		split_primitives = false, -- Split multi-primitive meshes into separate entities for better culling
	}
)
local default_material = Material.GetDefault()
-- Set camera to suggested position (camera node if found, otherwise scene center)
local cam_pos, cam_ang = gltf.GetSuggestedCameraTransform(gltf_result)
--cam_pos = Vec3(0, 1111, -60)
render3d.SetCameraPosition(cam_pos)
render3d.SetCameraAngles(cam_ang or Ang3(0, 0, 0))
-- Create sun light using ECS (direction in Z-up: x=forward, y=left, z=up)
local sun, sun_entity = Light.CreateDirectional(
	{
		direction = Vec3(0.8, 0.05, 0.4), -- Shining down and to the side
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
		cast_shadows = true,
		shadow_config = {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		},
	}
)
render3d.SetSunLight(sun)
