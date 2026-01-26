local model = {}
package.loaded["components.3d.model"] = model
local event = require("event")
local prototype = require("prototype")
local ecs = require("ecs")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Material = require("render3d.material")
local AABB = require("structs.aabb")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Matrix44 = require("structs.matrix44")
local model_loader = require("render3d.model_loader")
local transform = require("components.3d.transform").Component
local system = require("system")
local timer = require("timer")
local ffi = require("ffi")
-- Cached matrix to avoid allocation in hot drawing loops
local cached_final_matrix = Matrix44()
local META = prototype.CreateTemplate("model")
META.ComponentName = "model"
-- model requires transform component
META.Require = {transform}
META.Events = {"Draw3DGeometry"}
META:GetSet("Primitives", {})
META:GetSet("Visible", true)
META:GetSet("CastShadows", true)
META:GetSet("AABB", AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)) -- Local space AABB (combined from all primitives)
META:GetSet("UseOcclusionCulling", true) -- Enable occlusion culling for this model
META:GetSet("ModelPath", "")
META:GetSet("MaterialOverride", nil)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("RoughnessMultiplier", 1)
META:GetSet("MetallicMultiplier", 1)
META:IsSet("Loading", false)

function META:SetUseOcclusionCulling(enabled)
	self.UseOcclusionCulling = enabled

	if enabled and not self.occlusion_query and model.IsOcclusionCullingEnabled() then
		self.occlusion_query = render.CreateOcclusionQuery()
	end
end

function META:Initialize()
	self.Primitives = {}
	self:SetAABB(AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge))
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
			if not self:IsValid() then
				print("model became invalid while loading")
				return
			end

			self:SetLoading(false)
			self:BuildAABB()
		end,
		function(model)
			if not self:IsValid() then
				print("model became invalid while loading")
				return
			end

			self:AddPrimitive(model)
		end,
		function(err)
			if not self:IsValid() then
				print("model became invalid while loading: " .. err)
				error(err)
				return
			end

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
	if self.UseOcclusionCulling and model.IsOcclusionCullingEnabled() then
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
		aabb = obj.AABB,
		material = obj.material,
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

do
	model.noculling = false -- Debug flag to disable culling
	model.freeze_culling = false -- Debug flag to freeze frustum for culling tests
	local function extract_frustum_planes(proj_view_matrix, out_planes)
		local m = proj_view_matrix
		-- Gribb-Hartmann: Plane = Col 3 +/- Col 0/1/2
		-- Matrix is row-major in Lua: Column i is (m0i, m1i, m2i, m3i)
		-- Left plane: Col 3 + Col 0
		out_planes[0] = m.m03 + m.m00
		out_planes[1] = m.m13 + m.m10
		out_planes[2] = m.m23 + m.m20
		out_planes[3] = m.m33 + m.m30
		-- Right plane: Col 3 - Col 0
		out_planes[4] = m.m03 - m.m00
		out_planes[5] = m.m13 - m.m10
		out_planes[6] = m.m23 - m.m20
		out_planes[7] = m.m33 - m.m30
		-- Top plane: Col 3 + Col 1 (In Vulkan Y is down, so w+y is top)
		out_planes[8] = m.m03 + m.m01
		out_planes[9] = m.m13 + m.m11
		out_planes[10] = m.m23 + m.m21
		out_planes[11] = m.m33 + m.m31
		-- Bottom plane: Col 3 - Col 1 (In Vulkan Y is down, so w-y is bottom)
		out_planes[12] = m.m03 - m.m01
		out_planes[13] = m.m13 - m.m11
		out_planes[14] = m.m23 - m.m21
		out_planes[15] = m.m33 - m.m31
		-- Near plane: Col 2 (Vulkan depth range [0, w])
		out_planes[16] = m.m02
		out_planes[17] = m.m12
		out_planes[18] = m.m22
		out_planes[19] = m.m32
		-- Far plane: Col 3 - Col 2
		out_planes[20] = m.m03 - m.m02
		out_planes[21] = m.m13 - m.m12
		out_planes[22] = m.m23 - m.m22
		out_planes[23] = m.m33 - m.m32

		for i = 0, 20, 4 do
			local a, b, c = out_planes[i], out_planes[i + 1], out_planes[i + 2]
			local len = math.sqrt(a * a + b * b + c * c)

			if len > 0 then
				local inv_len = 1.0 / len
				out_planes[i] = a * inv_len
				out_planes[i + 1] = b * inv_len
				out_planes[i + 2] = c * inv_len
				out_planes[i + 3] = out_planes[i + 3] * inv_len
			end
		end
	end

	local function is_aabb_visible_frustum(aabb, frustum_planes)
		for i = 0, 20, 4 do
			local a, b, c, d = frustum_planes[i], frustum_planes[i + 1], frustum_planes[i + 2], frustum_planes[i + 3]
			local px = a > 0 and aabb.max_x or aabb.min_x
			local py = b > 0 and aabb.max_y or aabb.min_y
			local pz = c > 0 and aabb.max_z or aabb.min_z
			local dist = a * px + b * py + c * pz + d

			if dist < 0 then return false end
		end

		return true
	end

	local function transform_plane(plane_offset, frustum_array, world_matrix, out_offset, out_array)
		local a = frustum_array[plane_offset]
		local b = frustum_array[plane_offset + 1]
		local c = frustum_array[plane_offset + 2]
		local d = frustum_array[plane_offset + 3]
		local m = world_matrix
		-- Transform world plane P to local space: P_L = W^T * P_W
		-- Since matrix is row-major, Column i is (m0i, m1i, m2i, m3i)
		out_array[out_offset] = a * m.m00 + b * m.m10 + c * m.m20 + d * m.m30
		out_array[out_offset + 1] = a * m.m01 + b * m.m11 + c * m.m21 + d * m.m31
		out_array[out_offset + 2] = a * m.m02 + b * m.m12 + c * m.m22 + d * m.m32
		out_array[out_offset + 3] = a * m.m03 + b * m.m13 + c * m.m23 + d * m.m33
	end

	local cached_frustum_planes = ffi.new("float[24]")
	local cached_frustum_frame = -1

	local function get_frustum_planes()
		if model.freeze_culling and cached_frustum_frame >= 0 then
			return cached_frustum_planes
		end

		local current_frame = system.GetFrameNumber()

		if cached_frustum_frame ~= current_frame then
			-- print("Extracting frustum for frame", current_frame)
			-- ORIENTATION / TRANSFORMATION: Extract frustum from projection-view matrix
			local camera = render3d.GetCamera()
			local proj = camera:BuildProjectionMatrix()
			local view = camera:BuildViewMatrix()
			extract_frustum_planes(view * proj, cached_frustum_planes)
			cached_frustum_frame = current_frame
		end

		return cached_frustum_planes
	end

	local local_frustum_planes = ffi.new("float[24]")

	local function is_aabb_visible_local(local_aabb, world_matrix)
		if model.noculling then return true end

		local_aabb = local_aabb or model.GetAABB(nil)

		if not local_aabb then return true end

		local world_frustum = get_frustum_planes()

		for i = 0, 20, 4 do
			transform_plane(i, world_frustum, world_matrix, i, local_frustum_planes)
		end

		return is_aabb_visible_frustum(local_aabb, local_frustum_planes)
	end

	function META:IsAABBVisibleLocal()
		if not self.AABB then return true end

		local world_matrix = self:GetWorldMatrix()

		if not world_matrix then return true end

		return is_aabb_visible_local(self.AABB, world_matrix)
	end
end

-- Draw event handler
function META:OnDraw3DGeometry(cmd, dt)
	if not self.Visible then return end

	if #self.Primitives == 0 then return end

	-- Frustum culling: test local AABB against frustum (efficient - no AABB transformation)
	if not self:IsAABBVisibleLocal() then
		self.frustum_culled = true
		return -- model is outside frustum, skip drawing
	end

	self.frustum_culled = false
	-- Begin occlusion culling if enabled
	local using_occlusion = false

	if
		self.UseOcclusionCulling and
		self.occlusion_query and
		model.IsOcclusionCullingEnabled()
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

		for i, sub_mesh in ipairs(prim.polygon3d:GetSubMeshes()) do
			render3d.SetMaterial(
				self.MaterialOverride or
					sub_mesh.data or
					prim.material or
					render3d.GetDefaultMaterial()
			)
			render3d.UploadGBufferConstants(cmd)
			prim.polygon3d:Draw(cmd, i)
		end
	end

	-- End occlusion culling
	if using_occlusion then self.occlusion_query:EndConditional(cmd) end
end

-- Draw bounding box for occlusion query (simplified geometry)
-- This should be called in a separate pass before the main draw
function META:DrawOcclusionQuery(cmd)
	if self.frustum_culled then return end

	-- Skip updating queries if culling is frozen
	if model.freeze_culling then return end

	if not self:IsAABBVisibleLocal() then return end

	-- Begin occlusion query if enabled and available
	local query = self.UseOcclusionCulling and self.occlusion_query

	-- Verify query is ready (reset) before starting
	if query and query.needs_reset then
		query = nil -- Skip this frame if it needs a reset (must be done outside render pass)
	end

	if query then query:BeginQuery(cmd) end

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

			for i, sub_mesh in ipairs(prim.polygon3d:GetSubMeshes()) do
				render3d.SetMaterial(
					self.MaterialOverride or
						sub_mesh.data or
						prim.material or
						render3d.GetDefaultMaterial()
				)
				render3d.UploadGBufferConstants(cmd)
				prim.polygon3d:Draw(cmd, i)
			end
		end
	end

	-- End occlusion query
	if query then query:EndQuery(cmd) end
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

		for i, sub_mesh in ipairs(prim.polygon3d:GetSubMeshes()) do
			local material = self.MaterialOverride or
				sub_mesh.data or
				prim.material or
				render3d.GetDefaultMaterial()
			shadow_map:UploadConstants(final_matrix, material, cascade_idx)
			prim.polygon3d:Draw(shadow_cmd, i)
		end
	end
end

-- Draw into reflection probe cubemap
function META:DrawProbeGeometry(cmd, lightprobes)
	if not self.Visible then return end

	if #self.Primitives == 0 then return end

	local world_matrix = self:GetWorldMatrix()

	if not world_matrix then return end

	for _, prim in ipairs(self.Primitives) do
		local final_matrix = world_matrix

		if prim.local_matrix then
			final_matrix = prim.local_matrix:GetMultiplied(world_matrix, cached_final_matrix)
		end

		render3d.SetWorldMatrix(final_matrix)

		for i, sub_mesh in ipairs(prim.polygon3d:GetSubMeshes()) do
			render3d.SetMaterial(
				self.MaterialOverride or
					sub_mesh.data or
					prim.material or
					render3d.GetDefaultMaterial()
			)
			lightprobes.UploadConstants(cmd)
			prim.polygon3d:Draw(cmd, i)
		end
	end
end

model.occlusion_culling_enabled = true
model.occlusion_query_fps = 30 -- Limit occlusion queries to this FPS
model.last_occlusion_query_time = 0
model.should_run_queries_this_frame = true -- Cached per-frame flag
function model.IsOcclusionCullingEnabled()
	return model.occlusion_culling_enabled
end

function model.SetOcclusionCulling(enabled)
	model.occlusion_culling_enabled = enabled
end

-- Check if we should run occlusion queries this frame
-- This should only be called once per frame to avoid timing issues
function model.UpdateOcclusionQueryTiming()
	if model.occlusion_query_fps == 0 then
		model.should_run_queries_this_frame = true
		return
	end

	local current_time = system.GetElapsedTime()
	local min_interval = 1.0 / model.occlusion_query_fps

	if current_time - model.last_occlusion_query_time >= min_interval then
		model.last_occlusion_query_time = current_time
		model.should_run_queries_this_frame = true
	else
		model.should_run_queries_this_frame = false
	end
end

model.Component = META:Register()

function model.DrawAllShadows(shadow_cmd, shadow_map, cascade_idx)
	local models = ecs.GetComponents("model")

	for _, model in ipairs(models) do
		model:DrawShadow(shadow_cmd, shadow_map, cascade_idx)
	end
end

function model.GetOcclusionStats()
	local models = ecs.GetComponents("model")
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
		occlusion_enabled = model.IsOcclusionCullingEnabled(),
	}
end

-- Update timing and reset queries at the start of the frame
event.AddListener("PreRenderPass", "occlusion_culling_maintenance", function(cmd)
	if not model.IsOcclusionCullingEnabled() then return end

	model.UpdateOcclusionQueryTiming()

	if model.should_run_queries_this_frame and not model.freeze_culling then
		local models = ecs.GetComponents("model")

		for _, model in ipairs(models) do
			if model.UseOcclusionCulling and model.occlusion_query then
				model.occlusion_query:ResetQuery(cmd)
			end
		end
	end
end)

event.AddListener("PreDraw3D", "draw_occlusion_queries", function(cmd, dt)
	if model.IsOcclusionCullingEnabled() and model.should_run_queries_this_frame then
		if model.freeze_culling then return end

		local models = ecs.GetComponents("model")

		-- First pass: draw all models that DON'T use occlusion culling
		-- This fills the depth buffer with occluders
		for _, model in ipairs(models) do
			if model.Visible and not (model.UseOcclusionCulling and model.occlusion_query) then
				model:DrawOcclusionQuery(cmd)
			end
		end

		-- Second pass: draw all models that DO use occlusion culling with queries
		-- They will be tested against the occluders drawn in the first pass
		for _, model in ipairs(models) do
			if model.Visible and (model.UseOcclusionCulling and model.occlusion_query) then
				model:DrawOcclusionQuery(cmd)
			end
		end
	end
end)

event.AddListener("PostRenderPass", "copy_occlusion_results", function(cmd)
	if model.IsOcclusionCullingEnabled() and model.should_run_queries_this_frame then
		if model.freeze_culling then return end

		local models = ecs.GetComponents("model")

		for _, model in ipairs(models) do
			if model.UseOcclusionCulling and model.occlusion_query then
				model.occlusion_query:CopyQueryResults(cmd)
			end
		end
	end
end)

-- Draw all models into reflection probe when requested
event.AddListener("DrawProbeGeometry", "model_probe_draw", function(cmd, lightprobes)
	local models = ecs.GetComponents("model")

	for _, model in ipairs(models) do
		model:DrawProbeGeometry(cmd, lightprobes)
	end
end)

return model
