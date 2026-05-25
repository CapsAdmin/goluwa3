local event = import("goluwa/event.lua")
local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/ecs/entity.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local Visual = prototype.CreateTemplate("visual")
local visual = library()

local function registry_insert(registry, index_field, component)
	if component[index_field] then return end

	registry[#registry + 1] = component
	component[index_field] = #registry
end

local function registry_remove(registry, index_field, component)
	local index = component[index_field]

	if not index then return end

	local last_index = #registry
	local last_component = registry[last_index]
	registry[index] = last_component
	registry[last_index] = nil
	component[index_field] = nil

	if last_component and last_component ~= component then
		last_component[index_field] = index
	end
end

local function refresh_shadow_registry(component)
	if component.CastShadows then
		registry_insert(visual.shadow_casters, "shadow_registry_index", component)
	else
		registry_remove(visual.shadow_casters, "shadow_registry_index", component)
	end
end

local function refresh_occlusion_registries(component)
	local has_query = component.UseOcclusionCulling and component.occlusion_query ~= nil

	if has_query then
		registry_remove(visual.non_occlusion_visuals, "non_occlusion_registry_index", component)
		registry_insert(visual.occlusion_query_visuals, "occlusion_registry_index", component)
	else
		registry_remove(visual.occlusion_query_visuals, "occlusion_registry_index", component)
		registry_insert(visual.non_occlusion_visuals, "non_occlusion_registry_index", component)
	end
end

local function refresh_visual_registries(component)
	refresh_shadow_registry(component)
	refresh_occlusion_registries(component)
end

local function create_empty_aabb()
	return AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
end

local function material_ignores_z(material)
	return material and material.GetIgnoreZ and material:GetIgnoreZ() or false
end

local function expand_aabb_with_transformed(source, matrix, target)
	if not source then return end

	if matrix.m03 == 0 and matrix.m13 == 0 and matrix.m23 == 0 and matrix.m33 == 1 then
		local center_x = (source.min_x + source.max_x) * 0.5
		local center_y = (source.min_y + source.max_y) * 0.5
		local center_z = (source.min_z + source.max_z) * 0.5
		local extent_x = (source.max_x - source.min_x) * 0.5
		local extent_y = (source.max_y - source.min_y) * 0.5
		local extent_z = (source.max_z - source.min_z) * 0.5
		local world_x, world_y, world_z = matrix:TransformVectorUnpacked(center_x, center_y, center_z)
		local world_extent_x = math.abs(matrix.m00) * extent_x + math.abs(matrix.m10) * extent_y + math.abs(matrix.m20) * extent_z
		local world_extent_y = math.abs(matrix.m01) * extent_x + math.abs(matrix.m11) * extent_y + math.abs(matrix.m21) * extent_z
		local world_extent_z = math.abs(matrix.m02) * extent_x + math.abs(matrix.m12) * extent_y + math.abs(matrix.m22) * extent_z
		local min_x = world_x - world_extent_x
		local min_y = world_y - world_extent_y
		local min_z = world_z - world_extent_z
		local max_x = world_x + world_extent_x
		local max_y = world_y + world_extent_y
		local max_z = world_z + world_extent_z

		if min_x < target.min_x then target.min_x = min_x end

		if min_y < target.min_y then target.min_y = min_y end

		if min_z < target.min_z then target.min_z = min_z end

		if max_x > target.max_x then target.max_x = max_x end

		if max_y > target.max_y then target.max_y = max_y end

		if max_z > target.max_z then target.max_z = max_z end

		return
	end

	local function expand_point(x, y, z)
		local transformed_x, transformed_y, transformed_z = matrix:TransformVectorUnpacked(x, y, z)

		if transformed_x < target.min_x then target.min_x = transformed_x end

		if transformed_y < target.min_y then target.min_y = transformed_y end

		if transformed_z < target.min_z then target.min_z = transformed_z end

		if transformed_x > target.max_x then target.max_x = transformed_x end

		if transformed_y > target.max_y then target.max_y = transformed_y end

		if transformed_z > target.max_z then target.max_z = transformed_z end
	end

	expand_point(source.min_x, source.min_y, source.min_z)
	expand_point(source.min_x, source.min_y, source.max_z)
	expand_point(source.min_x, source.max_y, source.min_z)
	expand_point(source.min_x, source.max_y, source.max_z)
	expand_point(source.max_x, source.min_y, source.min_z)
	expand_point(source.max_x, source.min_y, source.max_z)
	expand_point(source.max_x, source.max_y, source.min_z)
	expand_point(source.max_x, source.max_y, source.max_z)
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
Visual:GetSet("CullDistance", 500)
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
	elseif not enabled and self.occlusion_query then
		self.occlusion_query:Delete()
		self.occlusion_query = nil
	end

	refresh_occlusion_registries(self)
end

function Visual:SetCastShadows(enabled)
	prototype.CommitProperty(self, "CastShadows", enabled)
	refresh_shadow_registry(self)
end

function Visual:InvalidateRenderEntries()
	self.RenderEntriesDirty = true
	self.HasIgnoreZRenderEntries = false
	self.HasOpaqueRenderEntries = false
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
		if is_managed_visual_child(child) then to_remove[#to_remove + 1] = child end
	end

	for i = 1, #to_remove do
		to_remove[i]:Remove()
	end

	self:InvalidateHierarchyState()
end

function Visual:MakeError()
	self:RemovePrimitives()
	self:SetLoading(false)
	local poly = Polygon3D.New()
	poly:CreateCube(0.5, 1.0)
	poly:BuildBoundingBox()
	poly:Upload()
	self:CreatePrimitiveEntity(
		poly,
		Material.New{
			AlbedoTexture = Texture.GetFallback(),
			DoubleSided = true,
		},
		((self.Owner and self.Owner.Name) or "visual") .. "_error"
	)
	self:BuildAABB()
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
	local has_ignore_z_entries = false
	local has_opaque_entries = false

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive

		if primitive then
			local polygon3d = primitive:GetPolygon3D()

			if polygon3d then
				local source_aabb = primitive:GetLocalAABB()
				local transform = child.transform
				local material = primitive:GetMaterial()
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
					material = material,
					aabb = local_aabb,
					source_aabb = source_aabb,
				}

				if material_ignores_z(material) then
					has_ignore_z_entries = true
				else
					has_opaque_entries = true
				end

				if local_aabb then bounds:Expand(local_aabb) end
			end
		end
	end

	self.RenderEntries = entries
	self.RenderEntriesDirty = false
	self.HasIgnoreZRenderEntries = has_ignore_z_entries
	self.HasOpaqueRenderEntries = has_opaque_entries
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
	if self.Owner and self.Owner.transform then
		return self.Owner.transform:GetWorldMatrix()
	end

	return nil
end

function Visual:GetWorldMatrixInverse()
	if self.Owner and self.Owner.transform then
		return self.Owner.transform:GetWorldMatrixInverse()
	end

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

	local world_aabb = create_empty_aabb()
	expand_aabb_with_transformed(local_aabb, world_matrix, world_aabb)
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
	visual.shadow_casters = visual.shadow_casters or {}
	visual.occlusion_query_visuals = visual.occlusion_query_visuals or {}
	visual.non_occlusion_visuals = visual.non_occlusion_visuals or {}

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
	local cached_frustum_view = nil
	local cached_frustum_proj = nil

	local function matrix_equals(a, b)
		if not a or not b then return false end

		return a.m00 == b.m00 and
			a.m01 == b.m01 and
			a.m02 == b.m02 and
			a.m03 == b.m03 and
			a.m10 == b.m10 and
			a.m11 == b.m11 and
			a.m12 == b.m12 and
			a.m13 == b.m13 and
			a.m20 == b.m20 and
			a.m21 == b.m21 and
			a.m22 == b.m22 and
			a.m23 == b.m23 and
			a.m30 == b.m30 and
			a.m31 == b.m31 and
			a.m32 == b.m32 and
			a.m33 == b.m33
	end

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
			not matrix_equals(cached_frustum_view, view)
			or
			not matrix_equals(cached_frustum_proj, proj)
		then
			local vp = view * proj
			extract_frustum_planes(vp, cached_frustum_planes)
			cached_frustum_frame = current_frame
			cached_frustum_view = view:Copy()
			cached_frustum_proj = proj:Copy()
		end

		return cached_frustum_planes
	end

	local function is_aabb_visible_world(world_aabb)
		if visual.noculling then return true end

		if not world_aabb then return true end

		return is_aabb_visible_frustum(world_aabb, get_frustum_planes())
	end

	local function is_aabb_within_cull_distance(world_aabb, cull_distance)
		if visual.noculling then return true end

		if not world_aabb or not cull_distance or cull_distance <= 0 then return true end

		local camera = render3d.GetCamera()

		if not camera or not camera.GetPosition then return true end

		local camera_position = camera:GetPosition()

		if not camera_position then return true end

		local nearest_x = math.clamp(camera_position.x, world_aabb.min_x, world_aabb.max_x)
		local nearest_y = math.clamp(camera_position.y, world_aabb.min_y, world_aabb.max_y)
		local nearest_z = math.clamp(camera_position.z, world_aabb.min_z, world_aabb.max_z)
		local dx = camera_position.x - nearest_x
		local dy = camera_position.y - nearest_y
		local dz = camera_position.z - nearest_z
		return dx * dx + dy * dy + dz * dz <= cull_distance * cull_distance
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

		local world_aabb = self:GetWorldAABB()

		if not world_aabb then return true end

		if not is_aabb_within_cull_distance(world_aabb, self:GetCullDistance()) then
			return false
		end

		return is_aabb_visible_world(world_aabb)
	end

	function Visual:IsWithinCullDistance()
		if visual.noculling then return true end

		local world_aabb = self:GetWorldAABB()

		if not world_aabb then return true end

		return is_aabb_within_cull_distance(world_aabb, self:GetCullDistance())
	end

	Visual.Library = visual
end

function Visual:HasRenderEntriesForPass(ignore_z, render_entries)
	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return false end

	if self.MaterialOverride then
		return material_ignores_z(self.MaterialOverride) == ignore_z
	end

	return ignore_z and self.HasIgnoreZRenderEntries or self.HasOpaqueRenderEntries
end

function Visual:DrawEntriesForPass(ignore_z, upload_constants, render_entries)
	local drew_any = false
	render_entries = render_entries or self:GetRenderEntries()

	for _, entry in ipairs(render_entries) do
		local material = self:GetResolvedMaterial(entry)

		if material_ignores_z(material) == ignore_z then
			local transform = entry.transform
			local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

			if world_matrix then
				if
					not ignore_z and
					upload_constants == render3d.UploadGBufferConstants and
					not self.using_conditional_rendering and
					render3d.QueueGBufferInstance(entry.polygon3d, material, world_matrix, self:GetModelPath())
				then
					drew_any = true
				else
					render3d.SetWorldMatrix(world_matrix)
					render3d.SetCurrentPolygon3D(entry.polygon3d)
					render3d.SetMaterial(material)
					upload_constants()
					entry.polygon3d:Draw()
				end

				drew_any = true
			end
		end
	end

	return drew_any
end

function Visual:OnDraw3DGeometry()
	if not self.Visible then return end

	local render_entries = self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(false, render_entries) then return end

	local cmd = render.GetCommandBuffer()

	if not self:IsAABBVisibleLocal() then
		self.frustum_culled = true
		return
	end

	self.frustum_culled = false
	local using_occlusion = false

	if
		self.UseOcclusionCulling and
		self.occlusion_query and
		visual.IsOcclusionCullingEnabled()
	then
		using_occlusion = self.occlusion_query:BeginConditional(cmd)
		self.using_conditional_rendering = using_occlusion
	else
		self.using_conditional_rendering = false
	end

	self:DrawEntriesForPass(false, render3d.UploadGBufferConstants, render_entries)

	if using_occlusion then self.occlusion_query:EndConditional(cmd) end
end

function Visual:OnDraw3DForwardOverlay()
	if not self.Visible then return end

	local render_entries = self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(true, render_entries) then return end

	if not self:IsAABBVisibleLocal() then return end

	self:DrawEntriesForPass(true, render3d.UploadForwardOverlayConstants, render_entries)
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
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			render3d.SetMaterial(self:GetResolvedMaterial(entry))
			render3d.UploadGBufferConstants()
			entry.polygon3d:Draw()
		end
	end

	if query then query:EndQuery(cmd) end
end

function Visual:DrawShadow(shadow_map, cascade_idx)
	if not self.CastShadows then return end

	if not self:IsWithinCullDistance() then return end

	local render_entries = self:GetRenderEntries()
	local can_use_shadow_aabb_cull = true

	for _, entry in ipairs(render_entries) do
		local material = self:GetResolvedMaterial(entry)

		if material and material:GetHeightTexture() and material:GetHeightScale() > 0 then
			can_use_shadow_aabb_cull = false

			break
		end
	end

	if can_use_shadow_aabb_cull then
		local world_aabb = self:GetWorldAABB()

		if world_aabb and not shadow_map:IsWorldAABBVisible(cascade_idx, world_aabb) then
			return
		end
	end

	for _, entry in ipairs(render_entries) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			shadow_map:UploadConstants(world_matrix, self:GetResolvedMaterial(entry), cascade_idx)
			entry.polygon3d:Draw()
		end
	end
end

function Visual:DrawProbeGeometry(lightprobes)
	if not self.Visible then return end

	if not self:IsWithinCullDistance() then return end

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetWorldMatrix(world_matrix)
			render3d.SetCurrentPolygon3D(entry.polygon3d)
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

	refresh_visual_registries(self)
end

function Visual:OnRemove()
	registry_remove(visual.shadow_casters, "shadow_registry_index", self)
	registry_remove(visual.occlusion_query_visuals, "occlusion_registry_index", self)
	registry_remove(visual.non_occlusion_visuals, "non_occlusion_registry_index", self)

	if self.occlusion_query then
		self.occlusion_query:Delete()
		self.occlusion_query = nil
	end

	self.RenderEntries = {}
	self:InvalidateRenderEntries()
end

function Visual:OnFirstCreated()
	event.AddListener("PrimeAllShadowMaterials", "visual_shadow_prime", function(shadow_map)
		for _, component in ipairs(visual.shadow_casters) do
			for _, entry in ipairs(component:GetRenderEntries()) do
				shadow_map:PrimeMaterial(component:GetResolvedMaterial(entry))
			end
		end
	end)

	event.AddListener("DrawAllShadows", "visual_shadow_draw", function(shadow_map, cascade_idx)
		for _, component in ipairs(visual.shadow_casters) do
			component:DrawShadow(shadow_map, cascade_idx)
		end
	end)

	event.AddListener("PreRenderPass", "visual_occlusion_culling_maintenance", function()
		if not visual.IsOcclusionCullingEnabled() then return end

		local cmd = render.GetCommandBuffer()
		visual.UpdateOcclusionQueryTiming()

		if visual.should_run_queries_this_frame and not visual.freeze_culling then
			for _, component in ipairs(visual.occlusion_query_visuals) do
				component.occlusion_query:ResetQuery(cmd)
			end
		end
	end)

	event.AddListener("PreDraw3D", "visual_draw_occlusion_queries", function()
		if visual.IsOcclusionCullingEnabled() and visual.should_run_queries_this_frame then
			if visual.freeze_culling then return end

			for _, component in ipairs(visual.non_occlusion_visuals) do
				if component.Visible then component:DrawOcclusionQuery() end
			end

			for _, component in ipairs(visual.occlusion_query_visuals) do
				if component.Visible then component:DrawOcclusionQuery() end
			end
		end
	end)

	event.AddListener("PostRenderPass", "visual_copy_occlusion_results", function(cmd)
		if visual.IsOcclusionCullingEnabled() and visual.should_run_queries_this_frame then
			if visual.freeze_culling then return end

			for _, component in ipairs(visual.occlusion_query_visuals) do
				component.occlusion_query:CopyQueryResults(cmd)
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
	event.RemoveListener("PrimeAllShadowMaterials", "visual_shadow_prime")
	event.RemoveListener("PreRenderPass", "visual_occlusion_culling_maintenance")
	event.RemoveListener("PreDraw3D", "visual_draw_occlusion_queries")
	event.RemoveListener("PostRenderPass", "visual_copy_occlusion_results")
	event.RemoveListener("DrawProbeGeometry", "visual_probe_draw")
end

return Visual:Register()
