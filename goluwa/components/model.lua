local prototype = require("prototype")
local ecs = require("ecs")
local render3d = require("graphics.render3d")
local Material = require("graphics.material")
local AABB = require("structs.aabb")
local Vec3 = require("structs.vec3")
local Matrix44 = require("structs.matrix").Matrix44
-- Cached matrix to avoid allocation in hot drawing loops
local cached_final_matrix = Matrix44()
local META = prototype.CreateTemplate("component", "model")
META.ComponentName = "model"
-- Model requires transform component
META.Require = {"transform"}
META.Events = {"Draw3D"}
META:GetSet("Primitives", {})
META:GetSet("Visible", true)
META:GetSet("CastShadows", true)
META:GetSet("AABB", nil) -- Local space AABB (combined from all primitives)
function META:Initialize(config)
	config = config or {}
	self.Primitives = config.primitives or {}
	self.AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

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
-- primitive.aabb should contain the local-space AABB
function META:AddPrimitive(primitive)
	table.insert(self.Primitives, primitive)

	-- Expand model AABB to include this primitive's AABB
	if primitive.aabb then self.AABB:Expand(primitive.aabb) end
end

-- Build/rebuild the combined AABB from all primitives
function META:BuildAABB()
	self.AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, prim in ipairs(self.Primitives) do
		if prim.aabb then self.AABB:Expand(prim.aabb) end
	end

	return self.AABB
end

-- Get world-space AABB by transforming local AABB by world matrix
function META:GetWorldAABB()
	local world_matrix = self:GetWorldMatrix()

	if not world_matrix or not self.AABB then return nil end

	-- Transform all 8 corners of the AABB and compute new bounds
	local corners = {
		{self.AABB.min_x, self.AABB.min_y, self.AABB.min_z},
		{self.AABB.min_x, self.AABB.min_y, self.AABB.max_z},
		{self.AABB.min_x, self.AABB.max_y, self.AABB.min_z},
		{self.AABB.min_x, self.AABB.max_y, self.AABB.max_z},
		{self.AABB.max_x, self.AABB.min_y, self.AABB.min_z},
		{self.AABB.max_x, self.AABB.min_y, self.AABB.max_z},
		{self.AABB.max_x, self.AABB.max_y, self.AABB.min_z},
		{self.AABB.max_x, self.AABB.max_y, self.AABB.max_z},
	}
	local world_aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, corner in ipairs(corners) do
		local wx, wy, wz = world_matrix:TransformVector(corner[1], corner[2], corner[3])

		if wx < world_aabb.min_x then world_aabb.min_x = wx end

		if wy < world_aabb.min_y then world_aabb.min_y = wy end

		if wz < world_aabb.min_z then world_aabb.min_z = wz end

		if wx > world_aabb.max_x then world_aabb.max_x = wx end

		if wy > world_aabb.max_y then world_aabb.max_y = wy end

		if wz > world_aabb.max_z then world_aabb.max_z = wz end
	end

	return world_aabb
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

	-- Frustum culling: check if model's world-space AABB is visible
	local world_aabb = self:GetWorldAABB()

	if world_aabb and not render3d.IsAABBVisible(world_aabb) then
		return -- Model is outside frustum, skip drawing
	end

	for _, prim in ipairs(self.Primitives) do
		-- If primitive has its own local matrix, combine with world matrix
		local final_matrix = world_matrix

		if prim.local_matrix then
			-- Reuse cached matrix to avoid per-draw allocation
			final_matrix = world_matrix:GetMultiplied(prim.local_matrix, cached_final_matrix)
		end

		render3d.SetWorldMatrix(final_matrix)
		render3d.SetMaterial(prim.material or Material.GetDefault())
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
			-- Reuse cached matrix to avoid per-draw allocation
			final_matrix = world_matrix:GetMultiplied(prim.local_matrix, cached_final_matrix)
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

-- Compute the world-space AABB of all models in the scene
-- Note: For now, just aggregates local AABBs without world transform
-- This is simpler and avoids coordinate system issues with node transforms
function Model.GetSceneAABB()
	local models = Model.GetSceneModels()
	local scene_aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, model in ipairs(models) do
		-- Use local AABB directly (already in engine coordinates from vertex processing)
		if model.AABB then scene_aabb:Expand(model.AABB) end
	end

	return scene_aabb
end

-- Get scene center from all models
function Model.GetSceneCenter()
	local aabb = Model.GetSceneAABB()
	return Vec3(
		(aabb.min_x + aabb.max_x) / 2,
		(aabb.min_y + aabb.max_y) / 2,
		(aabb.min_z + aabb.max_z) / 2
	)
end

return Model
