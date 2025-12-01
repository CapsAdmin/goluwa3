local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local event = require("event")
local Transform = require("transform")
local render = require("graphics.render")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
local gltf = require("gltf")
local Material = require("graphics.material")
local Light = require("graphics.light")
local Matrix44 = require("structs.matrix").Matrix44
local gltf_result = assert(
	gltf.Load(
		"/home/caps/projects/glTF-Sample-Assets-main/Models/ABeautifulGame/glTF/ABeautifulGame.gltf"
	)
)
local primitives = gltf.CreateGPUResources(gltf_result)
local textures_loaded = 0
local materials_loaded = 0

for _, prim in ipairs(primitives) do
	if prim.texture then textures_loaded = textures_loaded + 1 end

	if prim.material then materials_loaded = materials_loaded + 1 end
end

local mesh_idx = 1
local prim_idx = 1
-- Scene transform that applies to the entire model
local scene_transform = Transform.New()
scene_transform:SetPosition(Vec3(0, 0, 0))
scene_transform:SetAngles(Deg3(90, 0, 0))
scene_transform:SetSize(800)
local default_material = Material.GetDefault()
require("game.camera_movement")
render3d.cam:SetPosition(Vec3(0, 2, 0))
render3d.cam:SetAngles(Ang3(0, 0, 0))
local sun = Light.CreateDirectional(
	{
		direction = Vec3(0.8, -0.6, 0.7),
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
	}
)
sun:EnableShadows(
	{
		-- size = 2048, 
		ortho_size = 100.0,
		near_plane = 1.0,
		far_plane = 500.0,
	}
)
render3d.SetSunLight(sun)
Light.AddToScene(sun)
Light.SetSun(sun)

local function get_combined_matrix(scene_matrix, node_world_matrix)
	return scene_matrix:GetMultiplied(node_world_matrix)
end

event.AddListener("PreFrame", "shadows", function(dt)
	if sun:HasShadows() then
		local shadow_map = sun:GetShadowMap()
		sun:UpdateShadowMap(render3d.cam)
		local scene_matrix = scene_transform:GetMatrix()

		for cascade_idx = 1, shadow_map:GetCascadeCount() do
			local shadow_cmd = shadow_map:Begin(cascade_idx)

			for _, prim in ipairs(primitives) do
				local combined_matrix = get_combined_matrix(scene_matrix, prim.world_matrix)
				shadow_map:UploadConstants(combined_matrix, cascade_idx)
				shadow_cmd:BindVertexBuffer(prim.vertex_buffer, 0)

				if prim.index_buffer then
					shadow_cmd:BindIndexBuffer(prim.index_buffer, 0, prim.index_type)
					shadow_cmd:DrawIndexed(prim.index_count)
				else
					shadow_cmd:Draw(prim.vertex_count)
				end
			end

			shadow_map:End(cascade_idx)
		end

		render3d.UpdateShadowUBO()
	end
end)

event.AddListener("Draw3D", "test_gltf", function(cmd, dt)
	local scene_matrix = scene_transform:GetMatrix()

	for _, prim in ipairs(primitives) do
		local combined_matrix = get_combined_matrix(scene_matrix, prim.world_matrix)
		render3d.SetWorldMatrix(combined_matrix)
		render3d.SetMaterial(prim.material or default_material)
		render3d.UploadConstants(cmd)
		cmd:BindVertexBuffer(prim.vertex_buffer, 0)

		if prim.index_buffer then
			cmd:BindIndexBuffer(prim.index_buffer, 0, prim.index_type)
			cmd:DrawIndexed(prim.index_count)
		else
			cmd:Draw(prim.vertex_count)
		end
	end
end)
