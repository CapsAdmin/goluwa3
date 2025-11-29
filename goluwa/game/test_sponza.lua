local system = require("system")
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local event = require("event")
local Transform = require("transform")
local render = require("graphics.render")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
local gltf = require("gltf")
-- Load Sponza model
local sponza_path = "/home/caps/projects/glTF-Sample-Assets-main/Models/Sponza/glTF/Sponza.gltf"
print("Loading Sponza model from:", sponza_path)
local gltf_result, err = gltf.Load(sponza_path)

if not gltf_result then
	print("ERROR: Failed to load Sponza model:", err)
	return
end

print("Loaded glTF file successfully")
print("  Meshes:", #gltf_result.meshes)
print("  Materials:", #gltf_result.materials)
print("  Textures:", #gltf_result.textures)
print("  Images:", #gltf_result.images)
-- Create GPU resources
print("Creating GPU resources...")
local primitives = gltf.CreateGPUResources(gltf_result)
print("Created", #primitives, "renderable primitives")
-- Count textures loaded
local textures_loaded = 0

for _, prim in ipairs(primitives) do
	if prim.texture then textures_loaded = textures_loaded + 1 end
end

print("Loaded", textures_loaded, "textures")
-- Create transform for the model
local sponza_transform = Transform.New()
sponza_transform:SetPosition(Vec3(0, 0, 0))
sponza_transform:SetAngles(Deg3(90, 0, 0))
sponza_transform:SetSize(0.1) -- Sponza is already quite large
-- Default texture for primitives without textures
local default_texture = gfx.white_texture
-- Require camera movement
require("game.camera_movement")
-- Set initial camera position for Sponza (it's a large architectural scene)
render3d.cam:SetPosition(Vec3(0, 2, 0))
render3d.cam:SetAngles(Ang3(0, 0, 0))

event.AddListener("Draw3D", "test_sponza", function(cmd, dt)
	-- Set world matrix
	render3d.SetWorldMatrix(sponza_transform:GetMatrix())

	-- Draw all primitives
	for _, prim in ipairs(primitives) do
		-- Set texture
		local texture = prim.texture or default_texture
		render3d.SetTexture(texture)
		render3d.UploadConstants(cmd)
		-- Bind vertex buffer
		cmd:BindVertexBuffer(prim.vertex_buffer, 0)

		-- Draw
		if prim.index_buffer then
			cmd:BindIndexBuffer(prim.index_buffer, 0, prim.index_type)
			cmd:DrawIndexed(prim.index_count)
		else
			cmd:Draw(prim.vertex_count)
		end
	end
end)

print("Sponza scene ready!")
