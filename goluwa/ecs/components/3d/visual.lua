local event = import("goluwa/event.lua")
local prototype = import("goluwa/prototype.lua")
local BVH = import("goluwa/physics/bvh.lua")
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

local function has_occlusion_query_visuals()
	return visual.occlusion_query_visuals and visual.occlusion_query_visuals[1] ~= nil
end

local function get_shadow_debug_target_name(component)
	local owner = component and component.Owner
	return owner and owner.Name or tostring(component)
end

local function shadow_debug_matches(component)
	local filter = visual.shadow_debug_filter

	if filter == nil or filter == false then return false end

	local name = get_shadow_debug_target_name(component)

	if filter == true then return true end

	return name == filter or name:find(filter, 1, true) ~= nil
end

local function get_shadow_debug_frame_hits()
	local frame = system.GetFrameNumber and system.GetFrameNumber() or 0

	if visual.shadow_debug_frame ~= frame then
		visual.shadow_debug_frame = frame
		visual.shadow_debug_hits = {}
	end

	return visual.shadow_debug_hits
end

local function record_shadow_debug_hit(component, cascade_idx, state, entries)
	if not shadow_debug_matches(component) then return end

	local name = get_shadow_debug_target_name(component)
	local hits = get_shadow_debug_frame_hits()
	local hit = hits[name]

	if not hit then
		hit = {name = name, states = {}}
		hits[name] = hit
	end

	local state_key = tostring(cascade_idx) .. ":" .. state
	hit.states[state_key] = (hit.states[state_key] or 0) + (entries or 0)

	if visual.shadow_debug_log then
		logn(
			"[shadow-debug] ",
			name,
			" cascade=",
			cascade_idx,
			" state=",
			state,
			" entries=",
			entries or 0
		)
	end
end

local function get_shadow_draw_call_stats_store()
	visual.shadow_draw_call_stats = visual.shadow_draw_call_stats or setmetatable({}, {__mode = "k"})
	return visual.shadow_draw_call_stats
end

local function get_shadow_visible_list_cache_store()
	visual.shadow_visible_list_cache = visual.shadow_visible_list_cache or setmetatable({}, {__mode = "k"})
	return visual.shadow_visible_list_cache
end

local function get_shadow_visible_list_cache(shadow_map, cascade_idx)
	local stats = get_shadow_visible_list_cache_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	local cascade_cache = map_stats.cascades[cascade_idx]

	if not cascade_cache then
		cascade_cache = {list = {}}
		map_stats.cascades[cascade_idx] = cascade_cache
	end

	return cascade_cache
end

local function clear_array(list)
	for i = #list, 1, -1 do
		list[i] = nil
	end
end

local function shadow_cache_matches_aabb(cache, query_aabb)
	if cache.has_query_aabb ~= (query_aabb ~= nil) then return false end

	if not query_aabb then return true end

	return cache.query_min_x == query_aabb.min_x and
		cache.query_min_y == query_aabb.min_y and
		cache.query_min_z == query_aabb.min_z and
		cache.query_max_x == query_aabb.max_x and
		cache.query_max_y == query_aabb.max_y and
		cache.query_max_z == query_aabb.max_z
end

local function shadow_cache_matches_camera(cache, camera_position)
	if cache.has_camera_position ~= (camera_position ~= nil) then return false end

	if not camera_position then return true end

	return cache.camera_x == camera_position.x and
		cache.camera_y == camera_position.y and
		cache.camera_z == camera_position.z
end

local function can_reuse_shadow_visible_list(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	if not cache.valid then return false end

	if not query_aabb then return false end

	if cache.shadow_volume_change_version ~= shadow_volume_change_version then
		return false
	end

	if cache.shadow_visible_list_version ~= shadow_visible_list_version then
		return false
	end

	if not shadow_cache_matches_aabb(cache, query_aabb) then return false end

	if not shadow_cache_matches_camera(cache, camera_position) then return false end

	return true
end

local function update_shadow_visible_list_cache(
	cache,
	query_aabb,
	camera_position,
	shadow_volume_change_version,
	shadow_visible_list_version
)
	cache.valid = true
	cache.shadow_volume_change_version = shadow_volume_change_version
	cache.shadow_visible_list_version = shadow_visible_list_version
	cache.has_query_aabb = query_aabb ~= nil
	cache.has_camera_position = camera_position ~= nil

	if query_aabb then
		cache.query_min_x = query_aabb.min_x
		cache.query_min_y = query_aabb.min_y
		cache.query_min_z = query_aabb.min_z
		cache.query_max_x = query_aabb.max_x
		cache.query_max_y = query_aabb.max_y
		cache.query_max_z = query_aabb.max_z
	end

	if camera_position then
		cache.camera_x = camera_position.x
		cache.camera_y = camera_position.y
		cache.camera_z = camera_position.z
	end
end

local function record_shadow_draw_calls(shadow_map, cascade_idx, draw_call_count)
	if not shadow_map or not cascade_idx or draw_call_count <= 0 then return end

	local stats = get_shadow_draw_call_stats_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	map_stats.cascades[cascade_idx] = (map_stats.cascades[cascade_idx] or 0) + draw_call_count
	map_stats.last_updated_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

local function reset_shadow_draw_calls(shadow_map, cascade_idx)
	if not shadow_map or not cascade_idx then return end

	local stats = get_shadow_draw_call_stats_store()
	local map_stats = stats[shadow_map]

	if not map_stats then
		map_stats = {cascades = {}}
		stats[shadow_map] = map_stats
	end

	map_stats.cascades[cascade_idx] = 0
	map_stats.last_updated_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

local function create_empty_aabb()
	return AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
end

local function material_ignores_z(material)
	return material and material.GetIgnoreZ and material:GetIgnoreZ() or false
end

local last_scene_voxelizer_invalidation_frame = -1

local function voxelizer_has_dirty_work(voxelizer)
	if not voxelizer or not voxelizer.GetClipmaps then return false end

	for _, clipmap in ipairs(voxelizer.GetClipmaps() or {}) do
		if clipmap.dirty then return true end
	end

	return false
end

local function invalidate_scene_voxelizer(full_rebuild)
	if not render3d or not render3d.GetSceneVoxelizer then return end

	local voxelizer = render3d.GetSceneVoxelizer()

	if not voxelizer or not voxelizer.InvalidateAll then return end
	if voxelizer.IsEnabled and not voxelizer:IsEnabled() then return end

	local frame = system.GetFrameNumber and system.GetFrameNumber() or -1

	if last_scene_voxelizer_invalidation_frame == frame and voxelizer_has_dirty_work(voxelizer) then return end

	last_scene_voxelizer_invalidation_frame = frame
	voxelizer.InvalidateAll(full_rebuild ~= false)
end

local function invalidate_scene_acceleration()
	visual.scene_acceleration = visual.scene_acceleration or {}
	visual.scene_acceleration.dirty = true
	visual.scene_acceleration.tree = nil
	visual.scene_acceleration.shadow_tree = nil
	visual.scene_acceleration.visible_frame = nil
	visual.scene_acceleration.visible_components = nil
	visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1
	invalidate_scene_voxelizer(true)
end

local function next_shadow_change_version()
	visual.shadow_change_version_counter = (visual.shadow_change_version_counter or 0) + 1
	return visual.shadow_change_version_counter
end

local function mark_shadow_change(component)
	if not component then return end

	component.shadow_change_version = next_shadow_change_version()
end

local function is_visual_dynamic(component)
	local owner = component and component.Owner

	if owner and owner.rigid_body then return true end

	local transform = owner and owner.transform
	return transform and transform.IsFrameDynamic and transform:IsFrameDynamic() or false
end

local function add_scene_acceleration_item(items, component, bounds)
	if not bounds or bounds.min_x > bounds.max_x then return end

	items[#items + 1] = {
		component = component,
		world_aabb = bounds,
		cull_distance = component.CullDistance,
		shadow_change_version = component.shadow_change_version or 0,
		min_x = bounds.min_x,
		min_y = bounds.min_y,
		min_z = bounds.min_z,
		max_x = bounds.max_x,
		max_y = bounds.max_y,
		max_z = bounds.max_z,
		centroid_x = (bounds.min_x + bounds.max_x) * 0.5,
		centroid_y = (bounds.min_y + bounds.max_y) * 0.5,
		centroid_z = (bounds.min_z + bounds.max_z) * 0.5,
	}
end

local function get_scene_acceleration_item_bounds(item)
	return item
end

local function get_scene_acceleration_item_centroid(item)
	return item.centroid_x, item.centroid_y, item.centroid_z
end

local function annotate_tree_max_cull_distance(node, items)
	if not node then return 0 end

	if node.first then
		local max_cull_distance = 0

		for i = node.first, node.last do
			local cull_distance = items[i].cull_distance or 0

			if cull_distance > max_cull_distance then max_cull_distance = cull_distance end
		end

		node.max_cull_distance = max_cull_distance
		return max_cull_distance
	end

	local left_distance = annotate_tree_max_cull_distance(node.left, items)
	local right_distance = annotate_tree_max_cull_distance(node.right, items)
	node.max_cull_distance = math.max(left_distance, right_distance)
	return node.max_cull_distance
end

local function annotate_tree_max_shadow_change_version(node, items)
	if not node then return 0 end

	if node.first then
		local max_shadow_change_version = 0

		for i = node.first, node.last do
			local shadow_change_version = items[i].shadow_change_version or 0

			if shadow_change_version > max_shadow_change_version then
				max_shadow_change_version = shadow_change_version
			end
		end

		node.max_shadow_change_version = max_shadow_change_version
		return max_shadow_change_version
	end

	local left_version = annotate_tree_max_shadow_change_version(node.left, items)
	local right_version = annotate_tree_max_shadow_change_version(node.right, items)
	node.max_shadow_change_version = math.max(left_version, right_version)
	return node.max_shadow_change_version
end

local function is_aabb_intersecting(a, b)
	if not a or not b then return true end

	return not (
		a.min_x > b.max_x or
		b.min_x > a.max_x or
		a.min_y > b.max_y or
		b.min_y > a.max_y or
		a.min_z > b.max_z or
		b.min_z > a.max_z
	)
end

local function can_use_shadow_aabb_cull(component, render_entries)
	render_entries = render_entries or component:GetRenderEntries()

	for _, entry in ipairs(render_entries) do
		local material = component:GetResolvedMaterial(entry)

		if material and material:GetHeightTexture() and material:GetHeightScale() > 0 then
			return false
		end
	end

	return true
end

local function rebuild_scene_acceleration()
	local items = {}
	local dynamic_components = {}
	local shadow_items = {}
	local dynamic_shadow_components = {}
	local non_aabb_shadow_components = {}

	for _, component in ipairs(Visual.Instances or {}) do
		local render_entries = component:GetRenderEntries()

		if render_entries[1] then
			local world_aabb = component:GetWorldAABB()
			local shadow_aabb_cull = component.CastShadows and can_use_shadow_aabb_cull(component, render_entries)

			if is_visual_dynamic(component) then
				dynamic_components[#dynamic_components + 1] = component

				if component.CastShadows then
					if shadow_aabb_cull then
						dynamic_shadow_components[#dynamic_shadow_components + 1] = component
					else
						non_aabb_shadow_components[#non_aabb_shadow_components + 1] = component
					end
				end
			else
				add_scene_acceleration_item(items, component, world_aabb)

				if component.CastShadows then
					if shadow_aabb_cull then
						add_scene_acceleration_item(shadow_items, component, world_aabb)
					else
						non_aabb_shadow_components[#non_aabb_shadow_components + 1] = component
					end
				end
			end
		end
	end

	visual.scene_acceleration = visual.scene_acceleration or {}
	visual.scene_acceleration.items = items
	visual.scene_acceleration.dynamic_components = dynamic_components
	visual.scene_acceleration.shadow_items = shadow_items
	visual.scene_acceleration.dynamic_shadow_components = dynamic_shadow_components
	visual.scene_acceleration.non_aabb_shadow_components = non_aabb_shadow_components
	visual.scene_acceleration.tree = #items > 0 and
		BVH.Build(
			items,
			get_scene_acceleration_item_bounds,
			get_scene_acceleration_item_centroid,
			8
		) or
		nil
	visual.scene_acceleration.shadow_tree = #shadow_items > 0 and
		BVH.Build(
			shadow_items,
			get_scene_acceleration_item_bounds,
			get_scene_acceleration_item_centroid,
			8
		) or
		nil
	visual.scene_acceleration.visual_count = #(Visual.Instances or {})
	visual.scene_acceleration.dirty = false
	visual.scene_acceleration.visible_frame = nil
	visual.scene_acceleration.visible_components = nil

	if visual.scene_acceleration.tree then
		visual.scene_acceleration.tree.components = visual.scene_acceleration.tree.items
		visual.scene_acceleration.tree.items = nil
		annotate_tree_max_cull_distance(visual.scene_acceleration.tree.root, visual.scene_acceleration.tree.components)
		visual.scene_acceleration.tree.traversal_context = visual.scene_acceleration.tree.traversal_context or {
			node_stack = {},
		}
	end

	if visual.scene_acceleration.shadow_tree then
		visual.scene_acceleration.shadow_tree.components = visual.scene_acceleration.shadow_tree.items
		visual.scene_acceleration.shadow_tree.items = nil
		annotate_tree_max_cull_distance(visual.scene_acceleration.shadow_tree.root, visual.scene_acceleration.shadow_tree.components)
		annotate_tree_max_shadow_change_version(visual.scene_acceleration.shadow_tree.root, visual.scene_acceleration.shadow_tree.components)
		visual.scene_acceleration.shadow_tree.traversal_context = visual.scene_acceleration.shadow_tree.traversal_context or
			{
				node_stack = {},
			}
	end

	return visual.scene_acceleration
end

local function ensure_scene_acceleration()
	local acceleration = visual.scene_acceleration

	if
		not acceleration or
		acceleration.dirty or
		acceleration.visual_count ~= #(
			Visual.Instances or
			{}
		)
	then
		return rebuild_scene_acceleration()
	end

	return acceleration
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
	mark_shadow_change(self)
	refresh_shadow_registry(self)
	invalidate_scene_acceleration()
end

function Visual:InvalidateRenderEntries()
	self.RenderEntriesDirty = true
	self.HasIgnoreZRenderEntries = false
	self.HasOpaqueRenderEntries = false
	self.WorldAABBCache = nil
	self.WorldAABBCacheMatrix = nil
	self.WorldAABBCacheSource = nil
	self.raycast_primitive_acceleration = nil
	mark_shadow_change(self)
	invalidate_scene_acceleration()
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
	visual.occlusion_culling_enabled = false
	visual.shadow_debug_filter = nil
	visual.shadow_debug_log = true
	visual.shadow_debug_frame = -1
	visual.shadow_debug_hits = {}
	visual.shadow_draw_call_stats = setmetatable({}, {__mode = "k"})
	visual.shadow_visible_list_cache = setmetatable({}, {__mode = "k"})
	visual.shadow_visible_list_version = 0
	visual.shadow_change_version_counter = 0
	visual.occlusion_query_fps = 30
	visual.last_occlusion_query_time = 0
	visual.should_run_queries_this_frame = true
	visual.shadow_casters = visual.shadow_casters or {}
	visual.occlusion_query_visuals = visual.occlusion_query_visuals or {}
	visual.non_occlusion_visuals = visual.non_occlusion_visuals or {}

	function visual.EnableShadowDrawDebug(filter, should_log)
		visual.shadow_debug_filter = filter == nil and true or filter
		visual.shadow_debug_log = should_log ~= false
		visual.shadow_debug_frame = -1
		visual.shadow_debug_hits = {}
	end

	function visual.DisableShadowDrawDebug()
		visual.shadow_debug_filter = nil
		visual.shadow_debug_hits = {}
	end

	function visual.GetShadowDrawDebugHits()
		return get_shadow_debug_frame_hits()
	end

	function visual.GetShadowDrawCallStats(shadow_map)
		local stats = get_shadow_draw_call_stats_store()
		return stats[shadow_map] and stats[shadow_map].cascades or nil
	end

	local function get_shadow_tree_volume_change_version(query_aabb)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.shadow_tree and acceleration.shadow_tree.root) then
			return 0
		end

		local tree = acceleration.shadow_tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		node_stack[1] = tree.root
		local stack_size = 1
		local max_version = 0

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if is_aabb_intersecting(node.aabb, query_aabb) then
				if (node.max_shadow_change_version or 0) > max_version then
					if node.first then
						for i = node.first, node.last do
							local item = tree.components[i]

							if is_aabb_intersecting(item.world_aabb, query_aabb) then
								max_version = math.max(max_version, item.shadow_change_version or 0)
							end
						end
					else
						if node.right then
							stack_size = stack_size + 1
							node_stack[stack_size] = node.right
						end

						if node.left then
							stack_size = stack_size + 1
							node_stack[stack_size] = node.left
						end
					end
				end
			end
		end

		return max_version
	end

	function visual.TouchShadowChange(component)
		mark_shadow_change(component)
	end

	function visual.GetShadowVolumeChangeVersion(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local max_version = get_shadow_tree_volume_change_version(query_aabb)

		for _, component in ipairs(acceleration.dynamic_shadow_components or {}) do
			local world_aabb = component:GetWorldAABB()

			if is_aabb_intersecting(world_aabb, query_aabb) then
				max_version = math.max(max_version, component.shadow_change_version or 0)
			end
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
			local world_aabb = component:GetWorldAABB()

			if not world_aabb or is_aabb_intersecting(world_aabb, query_aabb) then
				max_version = math.max(max_version, component.shadow_change_version or 0)
			end
		end

		return max_version
	end

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
	local cached_cull_camera_frame = -1
	local cached_cull_camera_position = nil

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

	local function get_cull_camera_position()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0

		if cached_cull_camera_frame == current_frame and cached_cull_camera_position then
			return cached_cull_camera_position
		end

		local camera = render3d.GetCamera()
		cached_cull_camera_position = camera and camera.GetPosition and camera:GetPosition() or nil
		cached_cull_camera_frame = current_frame
		return cached_cull_camera_position
	end

	local function is_aabb_visible_world(world_aabb)
		if visual.noculling then return true end

		if not world_aabb then return true end

		return is_aabb_visible_frustum(world_aabb, get_frustum_planes())
	end

	local function is_aabb_within_cull_distance(world_aabb, cull_distance, camera_position)
		if visual.noculling then return true end

		if not world_aabb or not cull_distance or cull_distance <= 0 then return true end

		camera_position = camera_position or get_cull_camera_position()

		if not camera_position then return true end

		local nearest_x = math.clamp(camera_position.x, world_aabb.min_x, world_aabb.max_x)
		local nearest_y = math.clamp(camera_position.y, world_aabb.min_y, world_aabb.max_y)
		local nearest_z = math.clamp(camera_position.z, world_aabb.min_z, world_aabb.max_z)
		local dx = camera_position.x - nearest_x
		local dy = camera_position.y - nearest_y
		local dz = camera_position.z - nearest_z
		return dx * dx + dy * dy + dz * dz <= cull_distance * cull_distance
	end

	local function is_node_within_cull_distance(node, camera_position)
		return is_aabb_within_cull_distance(
			node and node.aabb or nil,
			node and node.max_cull_distance or nil,
			camera_position
		)
	end

	local function is_world_aabb_visible(component, world_aabb, frustum_planes)
		if visual.noculling then return true end

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, component:GetCullDistance(), get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes or get_frustum_planes())
	end

	local function is_static_item_visible(item, frustum_planes)
		if visual.noculling then return true end

		local world_aabb = item.world_aabb

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes)
	end

	local function append_visible_component(out, component, frustum_planes)
		if not component.Visible then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then
			component.frustum_culled = false
			return out
		end

		local world_aabb = component:GetWorldAABB()
		local visible = is_world_aabb_visible(component, world_aabb, frustum_planes)
		component.frustum_culled = not visible

		if visible then out[#out + 1] = component end

		return out
	end

	local function append_visible_static_item(out, item, frustum_planes)
		local component = item.component

		if not component.Visible then return out end

		local visible = is_static_item_visible(item, frustum_planes)
		component.frustum_culled = not visible

		if visible then out[#out + 1] = component end

		return out
	end

	local function append_shadow_visible_component(out, component, shadow_map, cascade_idx, skip_shadow_aabb)
		if not component.CastShadows then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		if not component:IsWithinCullDistance() then return out end

		if not skip_shadow_aabb then
			local world_aabb = component:GetWorldAABB()

			if world_aabb and not shadow_map:IsWorldAABBVisible(cascade_idx, world_aabb) then
				return out
			end

			if world_aabb and shadow_map:IsWorldAABBTooSmall(cascade_idx, world_aabb) then
				return out
			end
		end

		out[#out + 1] = component
		return out
	end

	local function append_shadow_visible_static_item(out, item, shadow_map, cascade_idx)
		local component = item.component

		if not component.CastShadows then return out end

		if
			not is_aabb_within_cull_distance(item.world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return out
		end

		if not shadow_map:IsWorldAABBVisible(cascade_idx, item.world_aabb) then
			return out
		end

		if shadow_map:IsWorldAABBTooSmall(cascade_idx, item.world_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function append_volume_visible_component(out, component, query_aabb)
		if not component.Visible then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		if not component:IsWithinCullDistance() then return out end

		local world_aabb = component:GetWorldAABB()

		if world_aabb and query_aabb and not is_aabb_intersecting(world_aabb, query_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function append_volume_visible_static_item(out, item, query_aabb)
		local component = item.component

		if not component.Visible then return out end

		if
			not is_aabb_within_cull_distance(item.world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return out
		end

		if query_aabb and not is_aabb_intersecting(item.world_aabb, query_aabb) then
			return out
		end

		out[#out + 1] = component
		return out
	end

	local function get_shadow_sort_state(component, shadow_map)
		local render_entries = component:GetRenderEntries()
		local first_entry = render_entries[1]
		local material = first_entry and component:GetResolvedMaterial(first_entry) or nil
		local polygon3d = first_entry and first_entry.polygon3d or nil
		return shadow_map:UsesTessellatedMaterial(material) and 1 or 0,
		material and material:GetGUID() or "",
		polygon3d and polygon3d:GetGUID() or "",
		component:GetModelPath() or "",
		component:GetGUID()
	end

	local active_shadow_sort_map

	local function compare_shadow_visible_components(a, b)
		local a_pipeline, a_material, a_polygon, a_model, a_component = get_shadow_sort_state(a, active_shadow_sort_map)
		local b_pipeline, b_material, b_polygon, b_model, b_component = get_shadow_sort_state(b, active_shadow_sort_map)

		if a_pipeline ~= b_pipeline then return a_pipeline < b_pipeline end

		if a_material ~= b_material then return a_material < b_material end

		if a_polygon ~= b_polygon then return a_polygon < b_polygon end

		if a_model ~= b_model then return a_model < b_model end

		return a_component < b_component
	end

	local function sort_shadow_visible_components(out, shadow_map)
		active_shadow_sort_map = shadow_map
		table.sort(out, compare_shadow_visible_components)
		active_shadow_sort_map = nil
		return out
	end

	local function collect_visible_static_components(out, frustum_planes)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.tree and acceleration.tree.root) then
			return out
		end

		local tree = acceleration.tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				is_aabb_visible_frustum(node.aabb, frustum_planes)
			then
				if node.first then
					for i = node.first, node.last do
						append_visible_static_item(out, tree.components[i], frustum_planes)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	local function collect_shadow_visible_static_components(out, shadow_map, cascade_idx)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.shadow_tree and acceleration.shadow_tree.root) then
			return out
		end

		local tree = acceleration.shadow_tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				shadow_map:IsWorldAABBVisible(cascade_idx, node.aabb)
			then
				if node.first then
					for i = node.first, node.last do
						append_shadow_visible_static_item(out, tree.components[i], shadow_map, cascade_idx)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	local function collect_volume_visible_static_components(out, query_aabb)
		local acceleration = ensure_scene_acceleration()

		if not (acceleration and acceleration.tree and acceleration.tree.root) then
			return out
		end

		local tree = acceleration.tree
		local node_stack = tree.traversal_context and tree.traversal_context.node_stack or {}
		local camera_position = get_cull_camera_position()
		node_stack[1] = tree.root
		local stack_size = 1

		while stack_size > 0 do
			local node = node_stack[stack_size]
			node_stack[stack_size] = nil
			stack_size = stack_size - 1

			if
				is_node_within_cull_distance(node, camera_position) and
				(
					not query_aabb or
					is_aabb_intersecting(node.aabb, query_aabb)
				)
			then
				if node.first then
					for i = node.first, node.last do
						append_volume_visible_static_item(out, tree.components[i], query_aabb)
					end
				else
					if node.right then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.right
					end

					if node.left then
						stack_size = stack_size + 1
						node_stack[stack_size] = node.left
					end
				end
			end
		end

		return out
	end

	function visual.InvalidateSceneAcceleration()
		invalidate_scene_acceleration()
	end

	function visual.GetVisibleVisuals()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local acceleration = ensure_scene_acceleration()

		if acceleration.visible_frame == current_frame and acceleration.visible_components then
			return acceleration.visible_components
		end

		local frustum_planes = get_frustum_planes()
		local out = {}

		for _, item in ipairs(acceleration.items or {}) do
			item.component.frustum_culled = true
		end

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			component.frustum_culled = true
		end

		collect_visible_static_components(out, frustum_planes)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_visible_component(out, component, frustum_planes)
		end

		acceleration.visible_frame = current_frame
		acceleration.visible_components = out
		return out
	end

	function visual.GetShadowVisibleVisuals(shadow_map, cascade_idx)
		local cache = get_shadow_visible_list_cache(shadow_map, cascade_idx)
		local acceleration = ensure_scene_acceleration()
		local camera_position = get_cull_camera_position()
		local query_aabb = shadow_map.GetCascadeWorldAABB and
			shadow_map:GetCascadeWorldAABB(cascade_idx) or
			nil
		local shadow_volume_change_version = query_aabb and visual.GetShadowVolumeChangeVersion(query_aabb) or nil
		local shadow_visible_list_version = visual.shadow_visible_list_version or 0

		if
			can_reuse_shadow_visible_list(
				cache,
				query_aabb,
				camera_position,
				shadow_volume_change_version,
				shadow_visible_list_version
			)
		then
			return cache.list
		end

		local out = cache.list
		clear_array(out)
		collect_shadow_visible_static_components(out, shadow_map, cascade_idx)

		for _, component in ipairs(acceleration.dynamic_shadow_components or {}) do
			append_shadow_visible_component(out, component, shadow_map, cascade_idx)
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
			append_shadow_visible_component(out, component, shadow_map, cascade_idx, true)
		end

		sort_shadow_visible_components(out, shadow_map)
		update_shadow_visible_list_cache(
			cache,
			query_aabb,
			camera_position,
			shadow_volume_change_version,
			shadow_visible_list_version
		)
		return out
	end

	function visual.GetVolumeVisibleVisuals(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local out = {}
		collect_volume_visible_static_components(out, query_aabb)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_volume_visible_component(out, component, query_aabb)
		end

		return out
	end

	function visual.GetAABBVisibleVisuals(query_aabb)
		return visual.GetVolumeVisibleVisuals(query_aabb)
	end

	function visual.GetSceneAccelerationVersion()
		return visual.shadow_visible_list_version or 0
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

		return is_world_aabb_visible(self, world_aabb)
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

function Visual:DrawGeometryPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(false, render_entries) then return end

	local cmd = render.GetCommandBuffer()

	if not skip_visibility and not self:IsAABBVisibleLocal() then
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

function Visual:OnDraw3DGeometry()
	return self:DrawGeometryPass()
end

function Visual:DrawForwardOverlayPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(true, render_entries) then return end

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

	self:DrawEntriesForPass(true, render3d.UploadForwardOverlayConstants, render_entries)
end

function Visual:OnDraw3DForwardOverlay()
	return self:DrawForwardOverlayPass()
end

function Visual:DrawOcclusionQuery(skip_visibility)
	if self.frustum_culled then return end

	local cmd = render.GetCommandBuffer()

	if visual.freeze_culling then return end

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

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

	return query ~= nil
end

function Visual:DrawShadow(shadow_map, cascade_idx, render_entries, skip_visibility_checks)
	if not self.CastShadows then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not skip_visibility_checks then
		if not self:IsWithinCullDistance() then
			record_shadow_debug_hit(self, cascade_idx, "culled_distance")
			return
		end

		if can_use_shadow_aabb_cull(self, render_entries) then
			local world_aabb = self:GetWorldAABB()

			if world_aabb and not shadow_map:IsWorldAABBVisible(cascade_idx, world_aabb) then
				record_shadow_debug_hit(self, cascade_idx, "culled_aabb")
				return
			end
		end
	end

	local submitted_entries = 0

	for _, entry in ipairs(render_entries) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			local material = self:GetResolvedMaterial(entry)

			if material then
				material.shadow_debug_force_opaque = shadow_debug_matches(self)
			end

			render3d.SetWorldMatrix(world_matrix)
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			shadow_map:UploadConstants(world_matrix, material, cascade_idx)
			entry.polygon3d:Draw()
			submitted_entries = submitted_entries + 1
		end
	end

	if submitted_entries > 0 then
		record_shadow_draw_calls(shadow_map, cascade_idx, submitted_entries)
		record_shadow_debug_hit(self, cascade_idx, "submitted", submitted_entries)
	else
		record_shadow_debug_hit(self, cascade_idx, "no_world_matrix")
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

function Visual:DrawVoxelGeometry(scene_voxelizer, clipmap_index, submit_entry)
	if not self.Visible then return 0 end

	if not self:IsWithinCullDistance() then return 0 end

	local submitted_entries = 0

	for _, entry in ipairs(self:GetRenderEntries()) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			local material = self:GetResolvedMaterial(entry)

			if scene_voxelizer.ShouldVoxelizeMaterial(material) then
				render3d.SetWorldMatrix(world_matrix)
				render3d.SetCurrentPolygon3D(entry.polygon3d)
				render3d.SetMaterial(material)

				if submit_entry then
					submit_entry(scene_voxelizer, clipmap_index, self, entry, world_matrix, material)
				end

				submitted_entries = submitted_entries + 1
			end
		end
	end

	return submitted_entries
end

function Visual:OnChildAdd()
	self:InvalidateHierarchyState()
end

function Visual:OnChildRemove()
	self:InvalidateHierarchyState()
end

function Visual:OnAdd()
	mark_shadow_change(self)

	if self.UseOcclusionCulling and visual.IsOcclusionCullingEnabled() then
		self.occlusion_query = render.CreateOcclusionQuery()
	end

	invalidate_scene_acceleration()
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
	invalidate_scene_acceleration()
end

function Visual:OnFirstCreated()
	event.AddListener("Draw3DGeometry", "visual_geometry_draw", function()
		for _, component in ipairs(visual.GetVisibleVisuals()) do
			component:DrawGeometryPass(nil, true)
		end
	end)

	event.AddListener("Draw3DForwardOverlay", "visual_forward_overlay_draw", function()
		for _, component in ipairs(visual.GetVisibleVisuals()) do
			component:DrawForwardOverlayPass(nil, true)
		end
	end)

	event.AddListener("PrimeAllShadowMaterials", "visual_shadow_prime", function(shadow_map)
		for _, component in ipairs(visual.shadow_casters) do
			for _, entry in ipairs(component:GetRenderEntries()) do
				shadow_map:PrimeMaterial(component:GetResolvedMaterial(entry))
			end
		end
	end)

	event.AddListener("DrawAllShadows", "visual_shadow_draw", function(shadow_map, cascade_idx)
		reset_shadow_draw_calls(shadow_map, cascade_idx)

		for _, component in ipairs(visual.GetShadowVisibleVisuals(shadow_map, cascade_idx)) do
			component:DrawShadow(shadow_map, cascade_idx, nil, true)
		end
	end)

	event.AddListener("PreRenderPass", "visual_occlusion_culling_maintenance", function()
		if not visual.IsOcclusionCullingEnabled() then return end

		if not has_occlusion_query_visuals() then return end

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

			if not has_occlusion_query_visuals() then return end

			visual.occlusion_query_submitted = visual.occlusion_query_submitted or {}

			for i = #visual.occlusion_query_submitted, 1, -1 do
				visual.occlusion_query_submitted[i] = nil
			end

			for _, component in ipairs(visual.GetVisibleVisuals()) do
				if component:DrawOcclusionQuery(true) then
					visual.occlusion_query_submitted[#visual.occlusion_query_submitted + 1] = component
				end
			end
		end
	end)

	event.AddListener("PostRenderPass", "visual_copy_occlusion_results", function(cmd)
		if visual.IsOcclusionCullingEnabled() and visual.should_run_queries_this_frame then
			if visual.freeze_culling then return end

			if not has_occlusion_query_visuals() then return end

			for _, component in ipairs(visual.occlusion_query_submitted or {}) do
				local query = component.occlusion_query

				if query then query:CopyQueryResults(cmd) end
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
