local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local ModelPreview = import("game/addons/gui/lua/model_preview.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_entity(offset)
	local poly = Polygon3D.New()
	poly:CreateCube(0.5, 1.0)

	if offset then
		for _, vertex in ipairs(poly.Vertices) do
			vertex.pos = vertex.pos + offset
		end

		poly:BuildBoundingBox()
	end

	poly:Upload()
	local material = Material.New{
		ColorMultiplier = Color(1, 0.2, 0.2, 1),
		EmissiveMultiplier = Color(0.2, 0.02, 0.02, 1),
		DoubleSided = true,
	}
	local entity = Entity.New{Name = "preview_model"}
	entity:AddComponent("transform")
	entity:AddComponent("model")
	entity.model:AddPrimitive(poly, material)
	entity.model:BuildAABB()
	entity.model:SetUseOcclusionCulling(false)
	return entity
end

T.Test3D("Model preview renders offscreen and restores the active camera", function()
	local entity = create_entity()
	local preview = ModelPreview.New()
	local camera = render3d.GetCamera()
	local old_position = camera:GetPosition():Copy()
	local old_rotation = camera:GetRotation():Copy()
	local ok, err = xpcall(
		function()
			local tex = preview:RenderEntity(entity)

			T.TexturePixel(
				tex,
				128,
				128,
				function(r, g, b, a)
					return r > 0.1 and g > 0.01 and a > 0.9
				end
			)

			T.TexturePixel(tex, 4, 4, 0, 0, 0, 0, 0.05)
			T(render3d.GetCamera() == camera)["=="](true)
			T(camera:GetPosition() == old_position)["=="](true)
			T(camera:GetRotation() == old_rotation)["=="](true)
		end,
		debug.traceback
	)
	preview:Remove()
	entity:Remove()

	if not ok then error(err, 0) end
end)
