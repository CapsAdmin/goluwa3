local prototype = require("prototype")
local ecs = require("ecs")
local render3d = require("graphics.render3d")
local Material = require("graphics.material")
local META = prototype.CreateTemplate("component", "model")
META.ComponentName = "model"
-- Model requires transform component
META.Require = {"transform"}
META.Events = {"Draw3D"}
META:GetSet("Primitives", {})
META:GetSet("Visible", true)
META:GetSet("CastShadows", true)

function META:Initialize(config)
	config = config or {}
	self.Primitives = config.primitives or {}

	if config.visible ~= nil then self.Visible = config.visible end

	if config.cast_shadows ~= nil then self.CastShadows = config.cast_shadows end
end

function META:OnAdd(entity) -- Nothing special needed
end

function META:OnRemove()
	-- Could cleanup GPU resources here if needed
	self.Primitives = {}
end

-- Add a primitive to this model
function META:AddPrimitive(primitive)
	table.insert(self.Primitives, primitive)
end

-- Get world matrix from transform component
function META:GetWorldMatrix()
	if self.Entity and self.Entity:HasComponent("transform") then
		return self.Entity.transform:GetWorldMatrix()
	end

	return nil
end

-- Draw event handler
function META:OnDraw3D(cmd, dt)
	if not self.Visible then return end

	if #self.Primitives == 0 then return end

	local world_matrix = self:GetWorldMatrix()

	if not world_matrix then return end

	local default_material = Material.GetDefault()

	for _, prim in ipairs(self.Primitives) do
		-- If primitive has its own local matrix, combine with world matrix
		local final_matrix = world_matrix

		if prim.local_matrix then
			final_matrix = world_matrix:GetMultiplied(prim.local_matrix)
		end

		render3d.SetWorldMatrix(final_matrix)
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
end

-- Draw shadows (called externally, not via event)
function META:DrawShadow(shadow_cmd, shadow_map, cascade_idx)
	if not self.CastShadows then return end

	if #self.Primitives == 0 then return end

	local world_matrix = self:GetWorldMatrix()

	if not world_matrix then return end

	for _, prim in ipairs(self.Primitives) do
		local final_matrix = world_matrix

		if prim.local_matrix then
			final_matrix = world_matrix:GetMultiplied(prim.local_matrix)
		end

		shadow_map:UploadConstants(final_matrix, cascade_idx)
		shadow_cmd:BindVertexBuffer(prim.vertex_buffer, 0)

		if prim.index_buffer then
			shadow_cmd:BindIndexBuffer(prim.index_buffer, 0, prim.index_type)
			shadow_cmd:DrawIndexed(prim.index_count)
		else
			shadow_cmd:Draw(prim.vertex_count)
		end
	end
end

META:Register()
ecs.RegisterComponent(META)
-----------------------------------------------------------
-- Static helpers
-----------------------------------------------------------
local Model = {}
Model.Component = META

-- Get all model components in scene
function Model.GetSceneModels()
	return ecs.GetComponents("model")
end

-- Draw all model shadows
function Model.DrawAllShadows(shadow_cmd, shadow_map, cascade_idx)
	local models = Model.GetSceneModels()

	for _, model in ipairs(models) do
		model:DrawShadow(shadow_cmd, shadow_map, cascade_idx)
	end
end

return Model
