local prototype = require("prototype")
local ecs = require("ecs")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local Material = require("graphics.material")
local AABB = require("structs.aabb")
local Vec3 = require("structs.vec3")
local Matrix44 = require("structs.matrix").Matrix44
local model_loader = require("model_loader")
local system = require("system")
local Model = {}
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
META:GetSet("UseOcclusionCulling", true) -- Enable occlusion culling for this model
META:GetSet("ModelPath", "")
META:IsSet("Loading", false)

function META:Initialize(config)
	config = config or {}
	self.Primitives = config.primitives or {}
	self.AABB = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	if config.visible ~= nil then self.Visible = config.visible end

	if config.cast_shadows ~= nil then self.CastShadows = config.cast_shadows end

	if config.use_occlusion_culling ~= nil then
		self.UseOcclusionCulling = config.use_occlusion_culling
	end

	-- Handle mesh/material shorthand config
	if config.mesh then
		local aabb = config.aabb

		-- Auto-compute AABB from mesh if not provided
		if not aabb and config.mesh.ComputeAABB then
			aabb = config.mesh:ComputeAABB()
		end

		self:AddPrimitive(config.mesh)
	end

	-- Create occlusion query object for conditional rendering
	self.occlusion_query = nil
end

function META:SetModelPath(path)
	--self:RemoveSubModels()
	self.ModelPath = path
	self:SetLoading(true)

	if path == "" then
		self:SetLoading(false)
		return
	end

	model_loader.LoadModel(
		path,
		function()
			self:SetLoading(false)
			self:BuildAABB()
		end,
		function(model)
			self:AddPrimitive(model)
		end,
		function(err)
			logf("%s failed to load model %q: %s\n", self, path, err)
			self:MakeError()
		end
	)
end

function META:MakeError()
	--self:RemoveSubModels()
	self:SetLoading(false)
	self:SetModelPath("models/error.mdl")
end

function META:OnAdd(entity)
	if self.UseOcclusionCulling and Model.IsOcclusionCullingEnabled() then
		self.occlusion_query = render.CreateOcclusionQuery()
	end
end

function META:OnRemove()
	-- Cleanup GPU resources
	if self.occlusion_query then
		self.occlusion_query:Delete()
		self.occlusion_query = nil
	end

	self.Primitives = {}
end

-- Add a Polygon3D to this model
function META:AddPrimitive(obj)
	-- Check if it's a Polygon3D object (has .mesh property)
	if not (obj.mesh and obj.mesh.vertex_buffer) then
		error(
			"AddPrimitive requires a Polygon3D object with .mesh.vertex_buffer, got: " .. tostring(obj)
		)
	end

	-- Store the Polygon3D
	local primitive = {
		polygon3d = obj,
		material = obj.material,
		aabb = obj.AABB,
	}
	table.insert(self.Primitives, primitive)

	if obj.AABB then self.AABB:Expand(obj.AABB) end
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

function META:GetWorldMatrixInverse()
	if self.Entity and self.Entity:HasComponent("transform") then
		return self.Entity.transform:GetWorldMatrixInverse()
	end

	return nil
end

-- Draw event handler
function META:OnDraw3D(cmd, dt)
	if not self.Visible then return end

	if #self.Primitives == 0 then return end

	-- Frustum culling: test local AABB against frustum (efficient - no AABB transformation)
	if
		self.AABB and
		not render3d.IsAABBVisibleLocal(self.AABB, self:GetWorldMatrixInverse())
	then
		self.frustum_culled = true
		return -- Model is outside frustum, skip drawing
	end

	self.frustum_culled = false
	-- Begin occlusion culling if enabled
	local using_occlusion = false

	if
		self.UseOcclusionCulling and
		self.occlusion_query and
		Model.IsOcclusionCullingEnabled()
	then
		using_occlusion = self.occlusion_query:BeginConditional(cmd)
		self.using_conditional_rendering = true
	else
		self.using_conditional_rendering = false
	end

	local world_matrix = self:GetWorldMatrix()

	for i, prim in ipairs(self.Primitives) do
		-- If primitive has its own local matrix, combine with world matrix
		local final_matrix = world_matrix

		if prim.local_matrix then
			-- Reuse cached matrix to avoid per-draw allocation
			final_matrix = prim.local_matrix:GetMultiplied(world_matrix, cached_final_matrix)
		end

		render3d.SetWorldMatrix(final_matrix)
		render3d.SetMaterial(prim.material or Material.GetDefault())
		render3d.UploadConstants(cmd)
		-- Draw using Polygon3D's Draw method
		prim.polygon3d:Draw(cmd)
	end

	-- End occlusion culling
	if using_occlusion then self.occlusion_query:EndConditional(cmd) end
end

-- Draw bounding box for occlusion query (simplified geometry)
-- This should be called in a separate pass before the main draw
function META:DrawOcclusionQuery(cmd)
	if not self.UseOcclusionCulling or not self.occlusion_query then return end

	if self.frustum_culled then return end

	-- Skip updating queries if culling is frozen
	if render3d.freeze_culling then return end

	if not render3d.IsAABBVisibleLocal(self.AABB, self:GetWorldMatrixInverse()) then
		return
	end

	-- Begin occlusion query
	self.occlusion_query:BeginQuery(cmd)
	-- Draw the actual model geometry (like old goluwa method)
	-- This determines if any pixels of the model are visible
	local world_matrix = self:GetWorldMatrix()

	if world_matrix then
		for _, prim in ipairs(self.Primitives) do
			local final_matrix = world_matrix

			if prim.local_matrix then
				final_matrix = prim.local_matrix:GetMultiplied(world_matrix, cached_final_matrix)
			end

			render3d.SetWorldMatrix(final_matrix)
			render3d.SetMaterial(prim.material or Material.GetDefault())
			render3d.UploadConstants(cmd)
			-- Draw using Polygon3D's Draw method
			prim.polygon3d:Draw(cmd)
		end
	end

	-- End occlusion query
	self.occlusion_query:EndQuery(cmd)
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
			final_matrix = prim.local_matrix:GetMultiplied(world_matrix, cached_final_matrix)
		end

		shadow_map:UploadConstants(final_matrix, cascade_idx)
		-- Draw using Polygon3D's Draw method
		prim.polygon3d:Draw(shadow_cmd)
	end
end

META:Register()
ecs.RegisterComponent(META)
-----------------------------------------------------------
-- Static helpers
-----------------------------------------------------------
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

-- Reset occlusion query pools (must be called outside render pass)
function Model.ResetOcclusionQueries(cmd)
	if render3d.freeze_culling then return end

	local models = Model.GetSceneModels()

	-- Reset all query pools that need it
	for _, model in ipairs(models) do
		if model.UseOcclusionCulling and model.occlusion_query then
			model.occlusion_query:ResetQuery(cmd)
		end
	end
end

-- Run occlusion queries for all models
-- This should be called before the main Draw3D event with the same command buffer
function Model.RunOcclusionQueries(cmd)
	local models = Model.GetSceneModels()

	-- Run occlusion queries for all models
	for _, model in ipairs(models) do
		model:DrawOcclusionQuery(cmd)
	end
end

-- Copy occlusion query results (must be called outside render pass)
function Model.CopyOcclusionQueryResults(cmd)
	if render3d.freeze_culling then return end

	local models = Model.GetSceneModels()

	-- Copy query results for all models
	for _, model in ipairs(models) do
		if model.UseOcclusionCulling and model.occlusion_query then
			model.occlusion_query:CopyQueryResults(cmd)
		end
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

-- Get occlusion culling statistics
function Model.GetOcclusionStats()
	local models = Model.GetSceneModels()
	local total = 0
	local with_occlusion = 0
	local frustum_culled = 0
	local submitted_with_conditional = 0

	for _, model in ipairs(models) do
		if model.Visible then
			total = total + 1

			if model.frustum_culled then frustum_culled = frustum_culled + 1 end

			if model.UseOcclusionCulling and model.occlusion_query then
				with_occlusion = with_occlusion + 1
			end

			if model.using_conditional_rendering then
				submitted_with_conditional = submitted_with_conditional + 1
			end
		end
	end

	return {
		total = total,
		with_occlusion = with_occlusion,
		frustum_culled = frustum_culled,
		submitted_with_conditional = submitted_with_conditional,
		potentially_occluded = submitted_with_conditional, -- GPU may cull these
		occlusion_enabled = Model.IsOcclusionCullingEnabled(),
	}
end

Model.occlusion_culling_enabled = false
Model.occlusion_query_fps = 1 -- Limit occlusion queries to this FPS
Model.last_occlusion_query_time = 0
Model.should_run_queries_this_frame = true -- Cached per-frame flag
function Model.IsOcclusionCullingEnabled()
	return Model.occlusion_culling_enabled
end

function Model.SetOcclusionCulling(enabled)
	Model.occlusion_culling_enabled = enabled
end

-- Set the FPS limit for occlusion queries (0 = no limit, runs every frame)
function Model.SetOcclusionQueryFPS(fps)
	Model.occlusion_query_fps = fps
end

function Model.GetOcclusionQueryFPS()
	return Model.occlusion_query_fps
end

-- Check if we should run occlusion queries this frame
-- This should only be called once per frame to avoid timing issues
function Model.UpdateOcclusionQueryTiming()
	if Model.occlusion_query_fps == 0 then
		Model.should_run_queries_this_frame = true
		return
	end

	local current_time = system.GetElapsedTime()
	local min_interval = 1.0 / Model.occlusion_query_fps

	if current_time - Model.last_occlusion_query_time >= min_interval then
		Model.last_occlusion_query_time = current_time
		Model.should_run_queries_this_frame = true
	else
		Model.should_run_queries_this_frame = false
	end
end

-- Update timing once at the start of the frame
function events.PreRenderPass.update_occlusion_timing(cmd)
	if Model.IsOcclusionCullingEnabled() then
		Model.UpdateOcclusionQueryTiming()
	end
end

function events.PreRenderPass.reset_occlusion_queries(cmd)
	if Model.IsOcclusionCullingEnabled() and Model.should_run_queries_this_frame then
		Model.ResetOcclusionQueries(cmd)
	end
end

function events.PreDraw3D.draw_occlusion_queries(cmd, dt)
	if Model.IsOcclusionCullingEnabled() and Model.should_run_queries_this_frame then
		Model.RunOcclusionQueries(cmd)
	end
end

function events.PostRenderPass.copy_occlusion_results(cmd)
	if Model.IsOcclusionCullingEnabled() and Model.should_run_queries_this_frame then
		Model.CopyOcclusionQueryResults(cmd)
	end
end

return Model
