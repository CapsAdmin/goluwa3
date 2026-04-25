local event = import("goluwa/event.lua")
local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/ecs/entity.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local Visual = prototype.CreateTemplate("visual")
local visual = library()

local function create_empty_aabb()
	return AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
end

local function material_ignores_z(material)
	return material and material.GetIgnoreZ and material:GetIgnoreZ() or false
end

local function expand_aabb_with_transformed(source, matrix, target)
	if not source then return end

	local corners = {
		{source.min_x, source.min_y, source.min_z},
		{source.min_x, source.min_y, source.max_z},
		{source.min_x, source.max_y, source.min_z},
		{source.min_x, source.max_y, source.max_z},
		{source.max_x, source.min_y, source.min_z},
		{source.max_x, source.min_y, source.max_z},
		{source.max_x, source.max_y, source.min_z},
		{source.max_x, source.max_y, source.max_z},
	}

	for _, corner in ipairs(corners) do
		local x, y, z = matrix:TransformVectorUnpacked(corner[1], corner[2], corner[3])

		if x < target.min_x then target.min_x = x end
		if y < target.min_y then target.min_y = y end
		if z < target.min_z then target.min_z = z end
		if x > target.max_x then target.max_x = x end
		if y > target.max_y then target.max_y = y end
		if z > target.max_z then target.max_z = z end
	end
end

local function build_transformed_aabb(source, matrix)
	if not source then return nil end
	if not matrix then return source end

	local out = create_empty_aabb()
	expand_aabb_with_transformed(source, matrix, out)
	return out
end

local function is_managed_visual_child(child)
	return child and (child.VisualOwner ~= nil or child.visual_primitive) or false
end

Visual:StartStorable()
Visual:GetSet("Visible", true)
Visual:GetSet("CastShadows", true)
Visual:GetSet("UseOcclusionCulling", true)
Visual:GetSet("ModelPath", "")
Visual:GetSet("MaterialOverride", nil)
Visual:GetSet("AABB", create_empty_aabb())
Visual:EndStorable()
Visual:IsSet("Loading", false)

function Visual:Initialize()
	self.RenderEntries = {}
	self.RenderEntriesDirty = true
	self.LoadGeneration = 0
	self:AddGlobalEvent("Draw3DGeometry")
	self:AddGlobalEvent("Draw3DForwardOverlay")
end

function Visual:SetUseOcclusionCulling(enabled)
	self.UseOcclusionCulling = enabled

	if enabled and not self.occlusion_query and visual.IsOcclusionCullingEnabled() then
		self.occlusion_query = render.CreateOcclusionQuery()
	end
end

function Visual:InvalidateRenderEntries()
	self.RenderEntriesDirty = true
	self.WorldAABBCache = nil
	self.WorldAABBCacheMatrix = nil
	self.WorldAABBCacheSource = nil
	self.raycast_primitive_acceleration = nil
end

function Visual:InvalidateHierarchyState()
	self:InvalidateRenderEntries()
	self:SetAABB(create_empty_aabb())
end

function Visual:CreatePrimitiveEntity(polygon3d, material, name, local_matrix)
	local primitive_entity = Entity.New{
		Name = name or ((self.Owner and self.Owner.Name) or "visual") .. "_primitive",
		Parent = self.Owner,
	}
	primitive_entity.VisualOwner = self
	local transform = primitive_entity:AddComponent("transform")

	if local_matrix then transform:SetFromMatrix(local_matrix) end

	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)

	return primitive_entity, visual_primitive
end

function Visual:RemovePrimitives()
	local to_remove = {}

	for _, child in ipairs(self.Owner:GetChildren()) do
		if is_managed_visual_child(child) then
			to_remove[#to_remove + 1] = child
		end
	end

	for i = 1, #to_remove do
		to_remove[i]:Remove()
	end

	self:InvalidateHierarchyState()
end

function Visual:MakeError()
	self:RemovePrimitives()
	self:SetLoading(false)
	self:SetModelPath("models/error.mdl")
end

function Visual:SetModelPath(path)
	self.LoadGeneration = (self.LoadGeneration or 0) + 1
	local load_generation = self.LoadGeneration
	self:RemovePrimitives()
	prototype.CommitProperty(self, "ModelPath", path)
	self:SetLoading(true)

	if path == "" then
		self:SetLoading(false)
		return
	end

	local primitive_index = 0
	model_loader.LoadModel(
		path,
		function()
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			self:SetLoading(false)
			self:BuildAABB()
		end,
		function(data)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			primitive_index = primitive_index + 1
			self:CreatePrimitiveEntity(
				data.mesh,
				data.material,
				((self.Owner and self.Owner.Name) or "visual") .. "_primitive_" .. primitive_index
			)
		end,
		function(err)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading: " .. err)
				error(err)
				return
			end

			logf("%s failed to load model %q: %s\n", self, path, err)
			self:MakeError()
		end
	)
end

function Visual:RebuildRenderEntries()
	local entries = {}
	local bounds = create_empty_aabb()

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive

		if primitive then
			local polygon3d = primitive:GetPolygon3D()

			if polygon3d then
				local source_aabb = primitive:GetLocalAABB()
				local transform = child.transform
				local local_matrix = transform and transform:GetLocalMatrix() or nil
				local local_matrix_inverse = local_matrix and local_matrix:GetInverse() or nil
				local local_aabb = build_transformed_aabb(source_aabb, local_matrix)
				entries[#entries + 1] = {
					entity = child,
					primitive = primitive,
					acceleration_owner = primitive,
					polygon3d = polygon3d,
					transform = transform,
					local_matrix = local_matrix,
					local_matrix_inverse = local_matrix_inverse,
					material = primitive:GetMaterial(),
					aabb = local_aabb,
					source_aabb = source_aabb,
				}

				if local_aabb then bounds:Expand(local_aabb) end
			end
		end
	end

	self.RenderEntries = entries
	self.RenderEntriesDirty = false
	self:SetAABB(bounds)
	return entries
end

function Visual:GetRenderEntries()
	if self.RenderEntriesDirty then return self:RebuildRenderEntries() end

	return self.RenderEntries
end

function Visual:GetPhysicsPrimitives()
	return self:GetRenderEntries()
end

function Visual:BuildAABB()
	self:GetRenderEntries()
	return self:GetAABB()
end

function Visual:GetWorldMatrix()
	if self.Owner and self.Owner.transform then return self.Owner.transform:GetWorldMatrix() end

	return nil
end

function Visual:GetWorldMatrixInverse()
	if self.Owner and self.Owner.transform then return self.Owner.transform:GetWorldMatrixInverse() end

	return nil
end

function Visual:GetWorldAABB()
	if self.RenderEntriesDirty then self:RebuildRenderEntries() end

	local world_matrix = self:GetWorldMatrix()
	local local_aabb = self:GetAABB()

	if not local_aabb then return nil end

	if not world_matrix then return local_aabb end

	if
		self.WorldAABBCache and
		self.WorldAABBCacheMatrix == world_matrix and
		self.WorldAABBCacheSource == local_aabb
	then
		return self.WorldAABBCache
	end

	local corners = {
		{local_aabb.min_x, local_aabb.min_y, local_aabb.min_z},
		{local_aabb.min_x, local_aabb.min_y, local_aabb.max_z},
		{local_aabb.min_x, local_aabb.max_y, local_aabb.min_z},
		{local_aabb.min_x, local_aabb.max_y, local_aabb.max_z},
		{local_aabb.max_x, local_aabb.min_y, local_aabb.min_z},
		{local_aabb.max_x, local_aabb.min_y, local_aabb.max_z},
		{local_aabb.max_x, local_aabb.max_y, local_aabb.min_z},
		{local_aabb.max_x, local_aabb.max_y, local_aabb.max_z},
	}
	local world_aabb = create_empty_aabb()

	for _, corner in ipairs(corners) do
		local wx, wy, wz = world_matrix:TransformVectorUnpacked(corner[1], corner[2], corner[3])

		if wx < world_aabb.min_x then world_aabb.min_x = wx end
		if wy < world_aabb.min_y then world_aabb.min_y = wy end
		if wz < world_aabb.min_z then world_aabb.min_z = wz end
		if wx > world_aabb.max_x then world_aabb.max_x = wx end
		if wy > world_aabb.max_y then world_aabb.max_y = wy end
		if wz > world_aabb.max_z then world_aabb.max_z = wz end
	end

	self.WorldAABBCache = world_aabb
	self.WorldAABBCacheMatrix = world_matrix
	self.WorldAABBCacheSource = local_aabb
	return world_aabb
end

function Visual:GetResolvedMaterial(entry)
	return self.MaterialOverride or entry.material or render3d.GetDefaultMaterial()
end

do
	visual.noculling = false
	visual.freeze_culling = false
	visual.occlusion_culling_enabled = true
	visual.occlusion_query_fps = 30
	visual.last_occlusion_query_time = 0
	visual.should_run_queries_this_frame = true

	local function extract_frustum_planes(proj_view_matrix, out_planes)
		local m = proj_view_matrix
		out_planes[0] = m.m03 + m.m00
		out_planes[1] = m.m13 + m.m10
		out_planes[2] = m.m23 + m.m20
		out_planes[3] = m.m33 + m.m30
		out_planes[4] = m.m03 - m.m00
		out_planes[5] = m.m13 - m.m10
		out_planes[6] = m.m23 - m.m20
		out_planes[7] = m.m33 - m.m30
		out_planes[8] = m.m03 + m.m01
		out_planes[9] = m.m13 + m.m11
		out_planes[10] = m.m23 + m.m21
		out_planes[11] = m.m33 + m.m31
		out_planes[12] = m.m03 - m.m01
		out_planes[13] = m.m13 - m.m11
		out_planes[14] = m.m23 - m.m21
		out_planes[15] = m.m33 - m.m31
		out_planes[16] = m.m02
		out_planes[17] = m.m12
		out_planes[18] = m.m22
		out_planes[19] = m.m32
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
		out_array[out_offset] = a * m.m00 + b * m.m01 + c * m.m02 + d * m.m03
		out_array[out_offset + 1] = a * m.m10 + b * m.m11 + c * m.m12 + d * m.m13
		out_array[out_offset + 2] = a * m.m20 + b * m.m21 + c * m.m22 + d * m.m23
		out_array[out_offset + 3] = a * m.m30 + b * m.m31 + c * m.m32 + d * m.m33
	end

	local cached_frustum_planes = ffi.new("float[24]")
	local cached_frustum_frame = -1
	local cached_frustum_view_m30 = 0
	local cached_frustum_view_m31 = 0
	local cached_frustum_view_m32 = 0
	local cached_frustum_view_m00 = 0
	local cached_frustum_view_m11 = 0
	local cached_frustum_view_m22 = 0
	local cached_frustum_proj_m00 = 0
	local cached_frustum_proj_m11 = 0

	local function get_frustum_planes()
		if visual.freeze_culling and cached_frustum_frame >= 0 then
			return cached_frustum_planes
		end

		local current_frame = system.GetFrameNumber()
		local camera = render3d.GetCamera()
		local view = camera:BuildViewMatrix()
		local proj = camera:BuildProjectionMatrix()

		if
			cached_frustum_frame ~= current_frame or
			cached_frustum_view_m30 ~= view.m30 or
			cached_frustum_view_m31 ~= view.m31 or
			cached_frustum_view_m32 ~= view.m32 or
			cached_frustum_view_m00 ~= view.m00 or
			cached_frustum_view_m11 ~= view.m11 or
			cached_frustum_view_m22 ~= view.m22 or
			cached_frustum_proj_m00 ~= proj.m00 or
			cached_frustum_proj_m11 ~= proj.m11
		then
			local vp = view * proj
			extract_frustum_planes(vp, cached_frustum_planes)
			cached_frustum_frame = current_frame
			cached_frustum_view_m30 = view.m30
			cached_frustum_view_m31 = view.m31
			cached_frustum_view_m32 = view.m32
			cached_frustum_view_m00 = view.m00
			cached_frustum_view_m11 = view.m11
			cached_frustum_view_m22 = view.m22
			cached_frustum_proj_m00 = proj.m00
			cached_frustum_proj_m11 = proj.m11
		end

		return cached_frustum_planes
	end

	local local_frustum_planes = ffi.new("float[24]")

	local function is_aabb_visible_local(local_aabb, world_matrix)
		if visual.noculling then return true end
		if not local_aabb then return true end

		local world_frustum = get_frustum_planes()

		for i = 0, 20, 4 do
			transform_plane(i, world_frustum, world_matrix, i, local_frustum_planes)
		end

		return is_aabb_visible_frustum(local_aabb, local_frustum_planes)
	end

	function visual.IsOcclusionCullingEnabled()
		return visual.occlusion_culling_enabled
	end

	function visual.SetOcclusionCulling(enabled)
		visual.occlusion_culling_enabled = enabled
	end

	function visual.UpdateOcclusionQueryTiming()
		if visual.occlusion_query_fps == 0 then
			visual.should_run_queries_this_frame = true
			return
		end

		local current_time = system.GetElapsedTime()
		local min_interval = 1.0 / visual.occlusion_query_fps

		if current_time - visual.last_occlusion_query_time >= min_interval then
			visual.last_occlusion_query_time = current_time
			visual.should_run_queries_this_frame = true
		else
			visual.should_run_queries_this_frame = false
		end
	end

	function visual.GetOcclusionStats()
		local total = 0
		local with_occlusion = 0
		local frustum_culled = 0
		local submitted_with_conditional = 0

		for _, component in ipairs(Visual.Instances) do
			if component.Visible then
				total = total + 1

				if component.frustum_culled then frustum_culled = frustum_culled + 1 end

				if component.UseOcclusionCulling and component.occlusion_query then
					with_occlusion = with_occlusion + 1
				end

				if component.using_conditional_rendering then
					submitted_with_conditional = submitted_with_conditional + 1
				end
			end
		end

		return {
			total = total,
			with_occlusion = with_occlusion,
			frustum_culled = frustum_culled,
			submitted_with_conditional = submitted_with_conditional,
			potentially_occluded = submitted_with_conditional,
			occlusion_enabled = visual.IsOcclusionCullingEnabled(),
		}
	end

	function Visual:IsAABBVisibleLocal()
		if visual.noculling then return true end

		local local_aabb = self:GetAABB()

		if not local_aabb or local_aabb.min_x > local_aabb.max_x then return true end

		local world_matrix = self:GetWorldMatrix()

		if not world_matrix then return true end

		return is_aabb_visible_local(local_aabb, world_matrix)
	end
	Visual.Library = visual
end

function Visual:HasRenderEntriesForPass(ignore_z)
	for _, entry in ipairs(self:GetRenderEntries()) do
		if material_ignores_z(self:GetResolvedMaterial(entry)) == ignore_z then return true end
	end

	return false
end

function Visual:DrawEntriesForPass(ignore_z, upload_constants)
	local drew_any = false

	for _, entry in ipairs(self:GetRenderEntries()) do
		local material = self:GetResolvedMaterial(entry)

		if material_ignores_z(material) == ignore_z then
			local transform = entry.transform
			local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

			if world_matrix then
				render3d.SetWorldMatrix(world_matrix)
				render3d.SetMaterial(material)
				upload_constants()
				entry.polygon3d:Draw()
				drew_any = true
			end
		end
	end

	return drew_any
end

function Visual:OnDraw3DGeometry()
	if not self.Visible then return end
	if not self:GetRenderEntries()[1] then return end
	if not self:HasRenderEntriesForPass(false) then return end

	local cmd = render.GetCommandBuffer()

	if not self:IsAABBVisibleLocal() then
		self.frustum_culled = true
		return
	end

	self.frustum_culled = false
	local using_occlusion = false

	if self.UseOcclusionCulling and self.occlusion_query and visual.IsOcclusionCullingEnabled() then
		using_occlusion = self.occlusion_query:BeginConditional(cmd)
		self.using_conditional_rendering = true
	else
		self.using_conditional_rendering = false
	end

	self:DrawEntriesForPass(false, render3d.UploadGBufferConstants)

	if using_occlusion then self.occlusion_query:EndConditional(cmd) end
end

function Visual:OnDraw3DForwardOverlay()
	if not self.Visible then return end
	if not self:GetRenderEntries()[1] then return end
	if not self:HasRenderEntriesForPass(true) then return end
	if not self:IsAABBVisibleLocal() then return end
	self:DrawEntriesForPass(true, render3d.UploadForwardOverlayConstants)
end

function Visual:DrawOcclusionQuery()
	if self.frustum_culled then return end

	local cmd = render.GetCommandBuffer()

	if visual.freeze_culling then return end
	if not self:IsAABBVisibleLocal() then return end

	local query = self.UseOcclusionCulling and self.occlusion_query

	if query and query.needs_reset then query = nil end
	if query then query:BeginQuery(cmd) end

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetWorldMatrix(world_matrix)
			render3d.SetMaterial(self:GetResolvedMaterial(entry))
			render3d.UploadGBufferConstants()
			entry.polygon3d:Draw()
		end
	end

	if query then query:EndQuery(cmd) end
end

function Visual:DrawShadow(shadow_map, cascade_idx)
	if not self.CastShadows then return end

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			shadow_map:UploadConstants(world_matrix, self:GetResolvedMaterial(entry), cascade_idx)
			entry.polygon3d:Draw()
		end
	end
end

function Visual:DrawProbeGeometry(lightprobes)
	if not self.Visible then return end

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetWorldMatrix(world_matrix)
			render3d.SetMaterial(self:GetResolvedMaterial(entry))
			lightprobes.UploadConstants()
			entry.polygon3d:Draw()
		end
	end
end

function Visual:OnChildAdd()
	self:InvalidateHierarchyState()
end

function Visual:OnChildRemove()
	self:InvalidateHierarchyState()
end

function Visual:OnAdd()
	if self.UseOcclusionCulling and visual.IsOcclusionCullingEnabled() then
		self.occlusion_query = render.CreateOcclusionQuery()
	end
end

function Visual:OnRemove()
	if self.occlusion_query then
		self.occlusion_query:Delete()
		self.occlusion_query = nil
	end

	self.RenderEntries = {}
	self:InvalidateRenderEntries()
end

function Visual:OnFirstCreated()
	event.AddListener("DrawAllShadows", "visual_shadow_draw", function(shadow_map, cascade_idx)
		for _, visual in ipairs(Visual.Instances) do
			visual:DrawShadow(shadow_map, cascade_idx)
		end
	end)

	event.AddListener("PreRenderPass", "visual_occlusion_culling_maintenance", function()
		if not visual.IsOcclusionCullingEnabled() then return end

		local cmd = render.GetCommandBuffer()
		visual.UpdateOcclusionQueryTiming()

		if visual.should_run_queries_this_frame and not visual.freeze_culling then
			for _, component in ipairs(Visual.Instances) do
				if component.UseOcclusionCulling and component.occlusion_query then
					component.occlusion_query:ResetQuery(cmd)
				end
			end
		end
	end)

	event.AddListener("PreDraw3D", "visual_draw_occlusion_queries", function()
		if visual.IsOcclusionCullingEnabled() and visual.should_run_queries_this_frame then
			if visual.freeze_culling then return end

			for _, component in ipairs(Visual.Instances) do
				if component.Visible and not (component.UseOcclusionCulling and component.occlusion_query) then
					component:DrawOcclusionQuery()
				end
			end

			for _, component in ipairs(Visual.Instances) do
				if component.Visible and (component.UseOcclusionCulling and component.occlusion_query) then
					component:DrawOcclusionQuery()
				end
			end
		end
	end)

	event.AddListener("PostRenderPass", "visual_copy_occlusion_results", function(cmd)
		if visual.IsOcclusionCullingEnabled() and visual.should_run_queries_this_frame then
			if visual.freeze_culling then return end

			for _, component in ipairs(Visual.Instances) do
				if component.UseOcclusionCulling and component.occlusion_query then
					component.occlusion_query:CopyQueryResults(cmd)
				end
			end
		end
	end)

	event.AddListener("DrawProbeGeometry", "visual_probe_draw", function(cmd, lightprobes)
		for _, visual in ipairs(Visual.Instances) do
			visual:DrawProbeGeometry(lightprobes)
		end
	end)
end

function Visual:OnLastRemoved()
	event.RemoveListener("DrawAllShadows", "visual_shadow_draw")
	event.RemoveListener("PreRenderPass", "visual_occlusion_culling_maintenance")
	event.RemoveListener("PreDraw3D", "visual_draw_occlusion_queries")
	event.RemoveListener("PostRenderPass", "visual_copy_occlusion_results")
	event.RemoveListener("DrawProbeGeometry", "visual_probe_draw")
end

return Visual:Register()