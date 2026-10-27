local event = import("goluwa/event.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local pvars = import("goluwa/cli/pvars.lua")
local objects = import("goluwa/objects/objects.lua")
local Visual = objects.CreateTemplate("visual")
import.loaded["goluwa/entities/components/visual.lua"] = Visual
Visual.Is3D = true
local BVH = import("goluwa/physics/bvh.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local scene_bridge = import("goluwa/render3d/scene/bridge.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local lod = import("goluwa/render3d/lod.lua")
local billboard = import("goluwa/render3d/billboard.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local terrain_shadow = import("goluwa/render3d/terrain_shadow.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/entities/entity.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local ffi = require("ffi")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local memcmp = import("goluwa/bindings/memory.lua").memcmp
local visual = {}
visual.scene_dirty_components = {}
visual.scene_version = 0

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

local function refresh_forward_overlay_registry(component)
	if
		not component.scene_removed and
		(
			component.HasIgnoreZRenderEntries or
			component.OverlayMaterial
		)
	then
		registry_insert(visual.forward_overlay_components, "forward_overlay_registry_index", component)
	else
		registry_remove(visual.forward_overlay_components, "forward_overlay_registry_index", component)
	end
end

local function refresh_translucent_registry(component)
	if component.HasTranslucentRenderEntries then
		registry_insert(visual.translucent_components, "translucent_registry_index", component)
	else
		registry_remove(visual.translucent_components, "translucent_registry_index", component)
	end
end

local function refresh_occlusion_registries(component)
	component.using_conditional_rendering = component.UseOcclusionCulling and
		visual.IsOcclusionCullingEnabled and
		visual.IsOcclusionCullingEnabled() or
		false
end

local function refresh_visual_registries(component)
	refresh_shadow_registry(component)
	refresh_forward_overlay_registry(component)
	refresh_occlusion_registries(component)
end

local get_cull_camera_position

local function create_empty_aabb()
	return AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
end

local function material_ignores_z(material)
	return material and material.GetIgnoreZ and material:GetIgnoreZ() or false
end

local function material_is_translucent(material)
	return material:IsTransparent() and not material_ignores_z(material)
end

local function material_draws_in_gbuffer(material)
	return not material_ignores_z(material) and
		(
			not material_is_translucent(material) or
			not render3d.pipelines.translucent_surface
		)
end

visual.MaterialDrawsInGBuffer = material_draws_in_gbuffer

function visual.MaterialDrawsTranslucent(material)
	return material_is_translucent(material) and
		render3d.pipelines.translucent_surface ~= nil
end

local function invalidate_scene_acceleration()
	visual.scene_full_rebuild = true
	visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1
end

local function mark_scene_component_dirty(component, structure)
	local dirty = visual.scene_dirty_components
	dirty[component] = structure or dirty[component] or false
	visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1
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
	local body = owner and owner.rigid_body

	if body then return body:IsKinematic() or body:IsDynamic() end

	local parent = owner and owner:GetParent()

	while parent and parent:IsValid() do
		body = parent.rigid_body

		if parent.armature or (body and (body:IsKinematic() or body:IsDynamic())) then
			return true
		end

		parent = parent:GetParent()
	end

	local transform = owner and owner.transform
	return transform and transform.IsFrameDynamic and transform:IsFrameDynamic() or false
end

visual.IsVisualDynamic = is_visual_dynamic

local function add_scene_acceleration_item(items, component, bounds)
	if not bounds or bounds.min_x > bounds.max_x then return nil end

	local item = {
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
	items[#items + 1] = item
	return item
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

		if material and material:HasHeightMap() then return false end
	end

	return true
end

local function classify_scene_component(component)
	if component.scene_removed or not component.Visible or component.RaysOnly then
		return false, false
	end

	local render_entries = component:GetRenderEntries()

	if not render_entries[1] then return false, false end

	local shadow_aabb_cull = component.CastShadows and can_use_shadow_aabb_cull(component, render_entries)

	if is_visual_dynamic(component) then
		return "dynamic",
		component.CastShadows and (shadow_aabb_cull and "dynamic" or "non_aabb") or false
	end

	local bounds = component:GetWorldAABB()
	local has_bounds = bounds and bounds.min_x <= bounds.max_x or false
	local shadow_kind = false

	if component.CastShadows then
		if not shadow_aabb_cull then
			shadow_kind = "non_aabb"
		elseif has_bounds then
			shadow_kind = "static"
		end
	end

	return has_bounds and "static" or false, shadow_kind, bounds
end

local function remove_scene_item(acceleration, pending_field, dead_field, item)
	if item.pending_index then
		registry_remove(acceleration[pending_field], "pending_index", item)
	else
		item.dead = true
		acceleration[dead_field] = acceleration[dead_field] + 1
	end
end

local function add_pending_scene_item(pending, component, bounds)
	local item = add_scene_acceleration_item(pending, component, bounds)
	item.pending_index = #pending
	return item
end

local function set_component_scene_items(acceleration, component, main_kind, shadow_kind, bounds)
	if component.scene_acceleration_owner ~= acceleration then
		component.scene_acceleration_owner = acceleration
		component.scene_acceleration_item = nil
		component.scene_shadow_acceleration_item = nil
		component.scene_dynamic_index = nil
		component.scene_dynamic_shadow_index = nil
		component.scene_non_aabb_shadow_index = nil
	end

	if component.scene_acceleration_item then
		remove_scene_item(acceleration, "pending", "dead_count", component.scene_acceleration_item)
		component.scene_acceleration_item = nil
	end

	registry_remove(acceleration.dynamic_components, "scene_dynamic_index", component)

	if main_kind == "static" then
		component.scene_acceleration_item = add_pending_scene_item(acceleration.pending, component, bounds)
	elseif main_kind == "dynamic" then
		registry_insert(acceleration.dynamic_components, "scene_dynamic_index", component)
	end

	if component.scene_shadow_acceleration_item then
		remove_scene_item(
			acceleration,
			"shadow_pending",
			"shadow_dead_count",
			component.scene_shadow_acceleration_item
		)
		component.scene_shadow_acceleration_item = nil
	end

	registry_remove(acceleration.dynamic_shadow_components, "scene_dynamic_shadow_index", component)
	registry_remove(acceleration.non_aabb_shadow_components, "scene_non_aabb_shadow_index", component)

	if shadow_kind == "static" then
		component.scene_shadow_acceleration_item = add_pending_scene_item(acceleration.shadow_pending, component, bounds)
	elseif shadow_kind == "dynamic" then
		registry_insert(acceleration.dynamic_shadow_components, "scene_dynamic_shadow_index", component)
	elseif shadow_kind == "non_aabb" then
		registry_insert(acceleration.non_aabb_shadow_components, "scene_non_aabb_shadow_index", component)
	end
end

local function refresh_material_users(component, in_scene)
	local users = visual.material_users

	if component.scene_material_users == users then
		for _, material in ipairs(component.scene_materials) do
			local set = users[material]

			if set then
				set[component] = nil

				if next(set) == nil then users[material] = nil end
			end
		end
	end

	component.scene_material_users = nil
	component.scene_materials = nil

	if not in_scene then return end

	local materials = {}

	for _, entry in ipairs(component:GetRenderEntries()) do
		local material = component:GetResolvedMaterial(entry)
		local set = users[material]

		if not set then
			set = setmetatable({}, {__mode = "k"})
			users[material] = set
		end

		set[component] = true
		materials[#materials + 1] = material
	end

	component.scene_material_users = users
	component.scene_materials = materials
end

local function build_scene_tree(items, annotate_shadow_versions)
	for _, item in ipairs(items) do
		item.pending_index = nil
	end

	local tree = BVH.BuildFast(
		items,
		get_scene_acceleration_item_bounds,
		get_scene_acceleration_item_centroid,
		8
	)

	if not tree then return nil end

	tree.components = tree.items
	tree.items = nil
	annotate_tree_max_cull_distance(tree.root, tree.components)

	if annotate_shadow_versions then
		annotate_tree_max_shadow_change_version(tree.root, tree.components)
	end

	tree.traversal_context = {node_stack = {}}
	return tree
end

local function rebuild_scene_tree_if_stale(acceleration, tree_field, pending_field, dead_field, annotate_shadow_versions)
	local tree = acceleration[tree_field]
	local pending = acceleration[pending_field]
	local count = tree and #tree.components or 0

	if
		#pending <= math.max(32, count * 0.1) and
		acceleration[dead_field] <= math.max(256, count * 0.25)
	then
		return
	end

	local items = {}

	if tree then
		for _, item in ipairs(tree.components) do
			if not item.dead then items[#items + 1] = item end
		end
	end

	for _, item in ipairs(pending) do
		items[#items + 1] = item
	end

	acceleration[tree_field] = build_scene_tree(items, annotate_shadow_versions)
	acceleration[pending_field] = {}
	acceleration[dead_field] = 0
end

local function reset_visible_caches(acceleration)
	acceleration.visible_frame = nil
	acceleration.visible_camera = nil
	acceleration.visible_components = nil
	acceleration.visible_render_entries = nil
	acceleration.visible_render_entries_frame = nil
end

local function rebuild_scene_acceleration()
	if next(Material.scene_dirty_materials) then
		for _, component in ipairs(Visual.Instances) do
			if not component.RenderEntriesDirty then
				for _, entry in ipairs(component.RenderEntries) do
					if Material.scene_dirty_materials[component:GetResolvedMaterial(entry)] then
						component:InvalidateRenderEntries()

						break
					end
				end
			end
		end
	end

	visual.scene_full_rebuild = false
	visual.scene_publish_pending = false
	visual.scene_dirty_components = {}
	table.clear(Material.scene_dirty_materials)
	visual.material_users = setmetatable({}, {__mode = "k"})
	local acceleration = {
		pending = {},
		shadow_pending = {},
		dead_count = 0,
		shadow_dead_count = 0,
		dynamic_components = {},
		dynamic_shadow_components = {},
		non_aabb_shadow_components = {},
	}

	for _, component in ipairs(Visual.Instances) do
		local main_kind, shadow_kind, bounds = classify_scene_component(component)
		set_component_scene_items(acceleration, component, main_kind, shadow_kind, bounds)
		refresh_material_users(component, main_kind or shadow_kind)
		scene_bridge.UpdateVisual(component, is_visual_dynamic(component))
	end

	acceleration.tree = build_scene_tree(acceleration.pending, false)
	acceleration.shadow_tree = build_scene_tree(acceleration.shadow_pending, true)
	acceleration.pending = {}
	acceleration.shadow_pending = {}
	visual.scene_acceleration = acceleration
	visual.scene_version = visual.scene_version + 1
	return acceleration
end

local function patch_scene_acceleration(acceleration)
	visual.scene_publish_pending = false

	for material in pairs(Material.scene_dirty_materials) do
		for component in pairs(visual.material_users[material] or {}) do
			component:InvalidateRenderEntries()
		end
	end

	table.clear(Material.scene_dirty_materials)
	local dirty = visual.scene_dirty_components
	visual.scene_dirty_components = {}

	for component, structure in pairs(dirty) do
		if component:IsValid() then
			local main_kind, shadow_kind, bounds = classify_scene_component(component)
			set_component_scene_items(acceleration, component, main_kind, shadow_kind, bounds)
			-- a component whose bounds arrive after its render entries (a streamed terrain tile) joins the scene
			-- without a structure change, and its materials would never know about it
			local in_scene = (main_kind or shadow_kind) and true or false

			if structure or in_scene ~= (component.scene_material_users ~= nil) then
				refresh_material_users(component, in_scene)
			end

			scene_bridge.UpdateVisual(component, is_visual_dynamic(component))
		end
	end

	rebuild_scene_tree_if_stale(acceleration, "tree", "pending", "dead_count", false)
	rebuild_scene_tree_if_stale(acceleration, "shadow_tree", "shadow_pending", "shadow_dead_count", true)
	reset_visible_caches(acceleration)
	visual.scene_version = visual.scene_version + 1
	return acceleration
end

local function ensure_scene_acceleration()
	visual.ScanWorldAABBs()
	local acceleration = visual.scene_acceleration

	if not acceleration or visual.scene_full_rebuild then
		acceleration = rebuild_scene_acceleration()
	elseif
		visual.scene_publish_pending or
		next(visual.scene_dirty_components) or
		next(Material.scene_dirty_materials)
	then
		patch_scene_acceleration(acceleration)
	end

	local frame = system.GetFrameNumber()

	if visual.dynamic_refresh_frame ~= frame then
		visual.dynamic_refresh_frame = frame
		scene_bridge.RefreshDynamic()
	end

	return acceleration
end

local function expand_point(matrix, target, x, y, z)
	local transformed_x, transformed_y, transformed_z = matrix:TransformVectorUnpacked(x, y, z)

	if transformed_x < target.min_x then target.min_x = transformed_x end

	if transformed_y < target.min_y then target.min_y = transformed_y end

	if transformed_z < target.min_z then target.min_z = transformed_z end

	if transformed_x > target.max_x then target.max_x = transformed_x end

	if transformed_y > target.max_y then target.max_y = transformed_y end

	if transformed_z > target.max_z then target.max_z = transformed_z end
end

local expand_aabb_with_transformed

do
	local function affine_bounds(source, matrix)
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
		return world_x - world_extent_x,
		world_y - world_extent_y,
		world_z - world_extent_z,
		world_x + world_extent_x,
		world_y + world_extent_y,
		world_z + world_extent_z
	end

	function expand_aabb_with_transformed(source, matrix, target)
		if not source then return end

		if matrix.m03 == 0 and matrix.m13 == 0 and matrix.m23 == 0 and matrix.m33 == 1 then
			local min_x, min_y, min_z, max_x, max_y, max_z = affine_bounds(source, matrix)

			if min_x < target.min_x then target.min_x = min_x end

			if min_y < target.min_y then target.min_y = min_y end

			if min_z < target.min_z then target.min_z = min_z end

			if max_x > target.max_x then target.max_x = max_x end

			if max_y > target.max_y then target.max_y = max_y end

			if max_z > target.max_z then target.max_z = max_z end

			return
		end

		expand_point(matrix, target, source.min_x, source.min_y, source.min_z)
		expand_point(matrix, target, source.min_x, source.min_y, source.max_z)
		expand_point(matrix, target, source.min_x, source.max_y, source.min_z)
		expand_point(matrix, target, source.min_x, source.max_y, source.max_z)
		expand_point(matrix, target, source.max_x, source.min_y, source.min_z)
		expand_point(matrix, target, source.max_x, source.min_y, source.max_z)
		expand_point(matrix, target, source.max_x, source.max_y, source.min_z)
		expand_point(matrix, target, source.max_x, source.max_y, source.max_z)
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
Visual:GetSet("ReceivesDecals", true)
Visual:GetSet("RaysOnly", false)
Visual:GetSet("InSceneBVH", true)
Visual:GetSet("Raycast", true)
Visual:GetSet("UseOcclusionCulling", true)
Visual:GetSet("CullDistance", 1000000)
Visual:GetSet("Billboard", false)
Visual:GetSet("ClipBounds", nil, {type = "table"})
Visual:GetSet("ModelPath", "", {asset = "models"})
Visual:GetSet(
	"MaterialOverridePath",
	"",
	{callback = "LoadMaterialOverride", asset = "materials"}
)
Visual:EndStorable()
Visual:GetSet("ViewHidden", false)
Visual:GetSet("MaterialOverride", nil)
Visual:GetSet("OverlayMaterial", nil)
Visual:GetSet("MaterialSlotOverrides", nil)
Visual:GetSet("AABB", create_empty_aabb())
Visual:GetSet("ClipWorldAABB", nil)

function Visual:SetLoading(loading)
	loading = loading and true or false

	if self.Loading == loading then return end

	self.Loading = loading

	if loading then scene_loading.Begin() else scene_loading.End() end
end

Visual:IsSet("Loading", false)

function Visual:Initialize()
	-- a visual added while its entity is being built is initialized once more when the build ends, which would drop its load
	if self.initialized then return end

	self.initialized = true
	self.RenderEntries = {}
	self.LODRenderEntries = self.RenderEntries
	self.RenderEntriesDirty = true
	self.LoadGeneration = self.LoadGeneration or 0
	refresh_forward_overlay_registry(self)
	refresh_translucent_registry(self)

	if self.Owner.visibility_hidden then self:RefreshVisible() end
end

function Visual:SetUseOcclusionCulling(enabled)
	if self.UseOcclusionCulling ~= enabled then mark_scene_component_dirty(self) end

	self.UseOcclusionCulling = enabled
	refresh_occlusion_registries(self)
end

function Visual:GetClipBounds()
	local box = self.ClipWorldAABB

	if not box then return nil end

	return {box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z}
end

function Visual:SetClipBounds(values)
	if values == nil then
		self:SetClipWorldAABB(nil)
	else
		self:SetClipWorldAABB(AABB(values[1], values[2], values[3], values[4], values[5], values[6]))
	end
end

function Visual:LoadMaterialOverride()
	if self.MaterialOverridePath == "" then
		self:SetMaterialOverride(nil)
		self:SetMaterialSlotOverrides(nil)
		return
	end

	local slots, material = Material.GetOverrideFromPath(self.MaterialOverridePath)

	if slots then
		self:SetMaterialSlotOverrides(slots)
	else
		self:SetMaterialOverride(material)
	end
end

function Visual:SetMaterialOverride(material)
	objects.CommitProperty(self, "MaterialOverride", material)
	self:InvalidateRenderEntries()
end

function Visual:SetOverlayMaterial(material)
	objects.CommitProperty(self, "OverlayMaterial", material)
	refresh_forward_overlay_registry(self)
end

function Visual:SetMaterialSlotOverrides(slots)
	objects.CommitProperty(self, "MaterialSlotOverrides", slots)
	self:InvalidateRenderEntries()
end

function Visual:SetCastShadows(enabled)
	objects.CommitProperty(self, "CastShadows", enabled)
	mark_shadow_change(self)
	visual.ForgetWorldAABB(self)
	refresh_shadow_registry(self)
	mark_scene_component_dirty(self)
end

function Visual:SetInSceneBVH(enabled)
	if self.InSceneBVH == enabled then return end

	objects.CommitProperty(self, "InSceneBVH", enabled)
	mark_scene_component_dirty(self, true)
end

function Visual:SetViewHidden(enabled)
	if self.ViewHidden == enabled then return end

	objects.CommitProperty(self, "ViewHidden", enabled)
	mark_scene_component_dirty(self, true)
end

function Visual:SetRaysOnly(enabled)
	if self.RaysOnly == enabled then return end

	objects.CommitProperty(self, "RaysOnly", enabled)
	mark_shadow_change(self)
	mark_scene_component_dirty(self, true)
end

do
	local hide_list

	local function get_hide_list()
		if hide_list then return hide_list end

		hide_list = {}

		for word in tostring(visual.hide_pvar:Get()):lower():gmatch("[^,%s]+") do
			hide_list[#hide_list + 1] = word
		end

		return hide_list
	end

	visual.hide_pvar = pvars.Setup2{
		key = "visual_hide",
		category = "Debug",
		group = "Visual",
		store = false,
		default = "",
		help = "comma separated words, every visual whose entity name contains one is hidden everywhere (gbuffer, shadows, scene bvh so gi and reflections). for isolating what a debug view shows, try world (static decals and roads), cry_terrain, vegetation, rock",
		callback = function()
			hide_list = nil

			for _, component in ipairs(Visual.Instances) do
				component:RefreshVisible()
			end
		end,
	}

	function Visual:IsDebugHidden()
		local list = get_hide_list()

		if not list[1] then return false end

		local name = self.Owner:GetName():lower()

		for i = 1, #list do
			if name:find(list[i], 1, true) then return true end
		end

		return false
	end
end

function Visual:ApplyVisible(visible)
	if self.Visible == visible then return end

	objects.CommitProperty(self, "Visible", visible)
	mark_shadow_change(self)
	mark_scene_component_dirty(self)
end

function Visual:SetVisible(visible)
	self.OwnVisible = visible
	self:ApplyVisible(visible and not self.Owner.visibility_hidden and not self:IsDebugHidden())
end

function Visual:RefreshVisible()
	self:ApplyVisible(
		self.OwnVisible ~= false and
			not self.Owner.visibility_hidden and
			not self:IsDebugHidden()
	)
end

Visual.OnHide = Visual.RefreshVisible
Visual.OnShow = Visual.RefreshVisible
Visual.OnEntityConstructed = Visual.RefreshVisible

function Visual:SetCullDistance(distance)
	if self.CullDistance == distance then return end

	objects.CommitProperty(self, "CullDistance", distance)
	mark_scene_component_dirty(self)
end

function Visual:InvalidateRenderEntries()
	self.RenderEntriesDirty = true
	self.HasIgnoreZRenderEntries = false
	self.HasOpaqueRenderEntries = false
	self.HasTranslucentRenderEntries = false
	self.gpu_dataset_static_serialized = nil
	self.gpu_dataset_shadow_serialized = nil
	self.WorldAABBCache = nil
	self.WorldAABBCacheMatrix = nil
	self.WorldAABBCacheSource = nil
	self.raycast_primitive_acceleration = nil
	mark_shadow_change(self)
	refresh_forward_overlay_registry(self)
	refresh_translucent_registry(self)
	mark_scene_component_dirty(self, true)
end

function Visual:NotifyGeometryChanged()
	mark_shadow_change(self)
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
	self.billboard_entity = nil
	self.billboard_pending = false
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
	shapes.BuildCube(poly, 0.5, 1.0)
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

function Visual:WantsBillboard()
	return not self.NoBillboard and
		(
			self.Billboard or
			lod.AreBillboardsForced() and
			not self.Skeleton
		)
end

function Visual:AddBillboard()
	if self.billboard_entity or self.billboard_pending or not render.IsInitialized() then
		return
	end

	local load_generation = self.LoadGeneration
	self.billboard_pending = true

	billboard.Request(self.ModelPath, function(polygon, material)
		if not self:IsValid() or self.LoadGeneration ~= load_generation then return end

		self.billboard_pending = false

		if not self:WantsBillboard() then return end

		self.billboard_entity = self:CreatePrimitiveEntity(
			polygon,
			material,
			((self.Owner and self.Owner.Name) or "visual") .. "_billboard"
		)
	end)
end

function Visual:RemoveBillboard()
	if self.billboard_entity then
		self.billboard_entity:Remove()
		self.billboard_entity = nil
	end
end

function Visual:SetBillboard(enabled)
	objects.CommitProperty(self, "Billboard", enabled)

	if enabled and self.ModelPath ~= "" and not self.Loading then
		self:AddBillboard()
	end
end

local failed_models = setmetatable({}, {__mode = "k"})
local retry_models = {}
local seen_mount_generation = vfs.mount_generation

event.AddListener("Update", "visual_retry_failed_models", function()
	if vfs.mount_generation == seen_mount_generation then return end

	seen_mount_generation = vfs.mount_generation

	for component in pairs(failed_models) do
		retry_models[#retry_models + 1] = component
	end

	for i = #retry_models, 1, -1 do
		local component = retry_models[i]
		retry_models[i] = nil
		failed_models[component] = nil

		if component:IsValid() then component:SetModelPath(component.ModelPath) end
	end
end)

function Visual:SetModelPath(path)
	self.LoadGeneration = (self.LoadGeneration or 0) + 1
	local load_generation = self.LoadGeneration
	self:RemovePrimitives()
	self.Skeleton = nil
	objects.CommitProperty(self, "ModelPath", path)
	self:SetLoading(true)

	if path == "" then
		self:SetLoading(false)
		return
	end

	local primitive_index = 0

	model_loader.LoadModel(
		path,
		function(data)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			self.Skeleton = data.skeleton
			self:SetLoading(false)
			self:BuildAABB()

			if self:WantsBillboard() then self:AddBillboard() end
		end,
		function(data)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				print("visual became invalid while loading")
				return
			end

			local mesh = data.mesh

			if not mesh.mesh:IsValid() then return end

			primitive_index = primitive_index + 1

			if self.ClipWorldAABB then
				mesh = mesh:CopyOutsideWorldAABB(self.Owner.transform:GetWorldMatrix(), self.ClipWorldAABB)

				if not mesh then return end
			end

			self:CreatePrimitiveEntity(
				mesh,
				data.material,
				((self.Owner and self.Owner.Name) or "visual") .. "_primitive_" .. primitive_index
			)
		end,
		function(err)
			if not self:IsValid() or self.LoadGeneration ~= load_generation then
				return
			end

			logf("%s failed to load model %q: %s\n", self, path, err)
			self:MakeError()
			failed_models[self] = true
		end
	)
end

function Visual:RebuildRenderEntries()
	local entries = {}
	local lod_entries = {}
	local bounds = create_empty_aabb()
	local has_ignore_z_entries = false
	local has_opaque_entries = false
	local has_translucent_entries = false
	local base_level = math.huge

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local primitive = child.visual_primitive

		if primitive then
			local polygon3d = primitive:GetPolygon3D()

			if polygon3d then
				local source_aabb = primitive:GetLocalAABB()
				local transform = child.transform
				local material = primitive:GetMaterial()

				if self.MaterialSlotOverrides and not polygon3d.LODBillboard then
					material = self.MaterialSlotOverrides[polygon3d:GetMaterialSlot()] or material
				end

				local local_matrix = transform and transform:GetLocalMatrix() or nil
				local local_matrix_inverse = local_matrix and local_matrix:GetInverse() or nil
				local local_aabb = build_transformed_aabb(source_aabb, local_matrix)
				local entry = {
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

				if self:GetResolvedMaterial(entry):GetNoDraw() then goto continue end

				local level = polygon3d.LODLevel

				if level < base_level then base_level = level end

				lod_entries[#lod_entries + 1] = entry
			end
		end

		::continue::
	end

	local levels = {}

	for _, entry in ipairs(lod_entries) do
		local level = entry.polygon3d.LODLevel
		local distance = entry.polygon3d.LODDistance

		if level == base_level then
			entries[#entries + 1] = entry
		elseif not levels[level] or distance < levels[level] then
			levels[level] = distance
		end
	end

	for _, entry in ipairs(entries) do
		local resolved_material = self:GetResolvedMaterial(entry)

		if material_ignores_z(resolved_material) then
			has_ignore_z_entries = true
		elseif material_is_translucent(resolved_material) then
			has_translucent_entries = true
		else
			has_opaque_entries = true
		end

		if entry.aabb then bounds:Expand(entry.aabb) end
	end

	if next(levels) then
		local sorted = {base_level}
		levels[base_level] = 0

		for level in pairs(levels) do
			if level ~= base_level then sorted[#sorted + 1] = level end
		end

		table.sort(sorted)
		local ranks = {}

		for rank, level in ipairs(sorted) do
			local previous = levels[sorted[rank - 1]]
			ranks[level] = rank

			if previous and levels[level] < previous then levels[level] = previous end
		end

		local has_billboard = false

		for _, entry in ipairs(lod_entries) do
			if entry.polygon3d.LODBillboard then has_billboard = true end
		end

		-- a decal on the most detailed level that has no counterpart on the next ones is not replaced by anything, so it
		-- stays when the rest of the model switches to a lower level
		local slot_has_lower_detail = {}

		for _, entry in ipairs(lod_entries) do
			if entry.polygon3d.LODLevel ~= base_level then
				slot_has_lower_detail[entry.polygon3d:GetMaterialSlot() or -1] = true
			end
		end

		for _, entry in ipairs(lod_entries) do
			local rank = ranks[entry.polygon3d.LODLevel]
			entry.lod_level = rank - 1
			entry.lod_near = levels[sorted[rank]]
			entry.lod_far = sorted[rank + 1] and levels[sorted[rank + 1]] or lod.NEVER

			if
				rank == 1 and
				self:GetResolvedMaterial(entry):GetDecal() and
				not slot_has_lower_detail[entry.polygon3d:GetMaterialSlot() or
				-1]
			then
				entry.lod_far = lod.NEVER
			end

			entry.lod_last = #sorted - 1
			entry.lod_billboard = entry.polygon3d.LODBillboard
			entry.lod_before_billboard = has_billboard and rank == #sorted - 1
		end

		self.LODRenderEntries = lod_entries
	else
		self.LODRenderEntries = entries
	end

	self.RenderEntries = entries
	self.RenderEntriesDirty = false
	self.HasIgnoreZRenderEntries = has_ignore_z_entries
	self.HasOpaqueRenderEntries = has_opaque_entries
	self.HasTranslucentRenderEntries = has_translucent_entries
	self:SetAABB(bounds)
	refresh_forward_overlay_registry(self)
	refresh_translucent_registry(self)
	return entries
end

function Visual:GetRenderEntries()
	if self.RenderEntriesDirty then return self:RebuildRenderEntries() end

	return self.RenderEntries
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

function Visual:GetPreviousWorldMatrix()
	if self.Owner and self.Owner.transform then
		return self.Owner.transform:GetPreviousWorldMatrix()
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
	if entry.polygon3d.LODBillboard then return entry.material end

	return self.MaterialOverride or entry.material or render3d.GetDefaultMaterial()
end

function Visual:GetBVHRenderEntries()
	local level = lod.GetBVHLevel()
	local entries = self:GetLODRenderEntries()

	if level == 0 or entries == self.RenderEntries then return self.RenderEntries end

	local cache = self.bvh_entries

	if cache and cache.source == entries and cache.level == level then
		return cache.list
	end

	local last = 0

	for _, entry in ipairs(entries) do
		if not entry.lod_billboard and entry.lod_level > last then
			last = entry.lod_level
		end
	end

	local target = math.min(level, last)
	local list = {}

	for _, entry in ipairs(entries) do
		if not entry.lod_billboard and entry.lod_level == target then
			list[#list + 1] = entry
		end
	end

	self.bvh_entries = {source = entries, level = level, list = list}
	return list
end

function Visual:GetLODEntriesAt(camera_position)
	local entries = self:GetLODRenderEntries()

	if entries == self.RenderEntries then return entries end

	local aabb = self:GetWorldAABB()
	local center_x, center_y, center_z = (aabb.min_x + aabb.max_x) * 0.5,
	(aabb.min_y + aabb.max_y) * 0.5,
	(aabb.min_z + aabb.max_z) * 0.5
	local dx, dy, dz = camera_position.x - center_x, camera_position.y - center_y, camera_position.z - center_z
	local extent_x, extent_y, extent_z = aabb.max_x - aabb.min_x, aabb.max_y - aabb.min_y, aabb.max_z - aabb.min_z
	local radius = math.sqrt(extent_x * extent_x + extent_y * extent_y + extent_z * extent_z) * 0.5
	local ratio = math.sqrt(dx * dx + dy * dy + dz * dz) / (
			math.max(radius, 0.001) * lod.GetScale()
		)
	local forced = lod.GetForcedLevel()
	local first = entries[1]
	local target = first.lod_last

	if forced >= 0 then
		target = math.min(forced, first.lod_last)
	else
		for _, entry in ipairs(entries) do
			if
				(
					entry.lod_level == 0 or
					ratio >= entry.lod_near
				)
				and
				(
					entry.lod_level == entry.lod_last or
					ratio < entry.lod_far
				)
			then
				target = entry.lod_level

				break
			end
		end
	end

	local cache = self.lod_entry_lists

	if not cache or cache.source ~= entries then
		cache = {source = entries}
		self.lod_entry_lists = cache
	end

	local list = cache[target]

	if not list then
		list = {}

		for _, entry in ipairs(entries) do
			if
				entry.lod_level == target and
				not entry.lod_billboard or
				entry.lod_before_billboard and
				target > entry.lod_level
			then
				list[#list + 1] = entry
			end
		end

		cache[target] = list
	end

	return list
end

function Visual:GetLODRenderEntries()
	if self.RenderEntriesDirty then self:RebuildRenderEntries() end

	return self.LODRenderEntries
end

do
	visual.noculling = false
	visual.freeze_frustum_planes = false
	visual.occlusion_culling_enabled = true
	visual.AABB_TOLERANCE = 0.005
	visual.DIRTY_BOX_CAP = 4096
	visual.aabb_signatures = nil
	visual.aabb_scan_frame = -1
	visual.aabb_forgotten_boxes = {}
	visual.aabb_scan_candidates = {}
	visual.aabb_scan_changed = false
	visual.AABB_CHANGED_BOXES = nil
	visual.AABB_CHANGED_COMPONENTS = nil
	visual.AABB_CHANGED_ALL = false

	event.AddListener("CullingSettingsChanged", "visual_culling_settings", function()
		visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1
	end)

	event.AddListener("LODSettingsChanged", "visual_lod_settings", function()
		visual.shadow_visible_list_version = (visual.shadow_visible_list_version or 0) + 1

		if visual.bvh_level ~= lod.GetBVHLevel() then
			visual.bvh_level = lod.GetBVHLevel()

			for _, component in ipairs(Visual.Instances) do
				mark_scene_component_dirty(component, true)
			end
		end

		for _, component in ipairs(Visual.Instances) do
			if component.ModelPath ~= "" and not component.Loading then
				if component:WantsBillboard() then
					component:AddBillboard()
				elseif not component.Billboard then
					component:RemoveBillboard()
				end
			end
		end
	end)

	event.AddListener("OnTransformChanged", "visual_aabb_scan", function(transform)
		local owner = transform.Owner

		if owner.visual then visual.aabb_scan_candidates[owner.visual] = true end

		if owner:HasChildren() then
			local candidates = visual.aabb_scan_candidates
			local descendants = owner:GetChildrenList()

			for i = 1, #descendants do
				local child_visual = descendants[i].visual

				if child_visual then candidates[child_visual] = true end
			end
		end
	end)

	visual.shadow_prime_versions = setmetatable({}, {__mode = "k"})
	visual.shadow_visible_list_version = 0
	visual.shadow_change_version_counter = 0
	visual.shadow_casters = visual.shadow_casters or {}
	visual.forward_overlay_components = visual.forward_overlay_components or {}
	visual.translucent_components = visual.translucent_components or {}

	local function get_shadow_tree_volume_change_version(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local max_version = 0
		local tree = acceleration.shadow_tree

		if tree then
			local node_stack = tree.traversal_context.node_stack
			node_stack[1] = tree.root
			local stack_size = 1

			while stack_size > 0 do
				local node = node_stack[stack_size]
				node_stack[stack_size] = nil
				stack_size = stack_size - 1

				if is_aabb_intersecting(node.aabb, query_aabb) then
					if (node.max_shadow_change_version or 0) > max_version then
						if node.first then
							for i = node.first, node.last do
								local item = tree.components[i]

								if not item.dead and is_aabb_intersecting(item.world_aabb, query_aabb) then
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
		end

		for _, item in ipairs(acceleration.shadow_pending) do
			if is_aabb_intersecting(item.world_aabb, query_aabb) then
				max_version = math.max(max_version, item.shadow_change_version or 0)
			end
		end

		return max_version
	end

	function visual.TouchShadowChange(component)
		mark_shadow_change(component)
	end

	local function get_dynamic_shadow_aabb_cache()
		visual.dynamic_shadow_aabb_cache = visual.dynamic_shadow_aabb_cache or setmetatable({}, {__mode = "k"})
		return visual.dynamic_shadow_aabb_cache
	end

	local function get_cached_component_world_aabb(aabb_cache, component, version)
		local cached = aabb_cache[component]

		if not cached or cached.version ~= version then
			cached = {version = version, aabb = component:GetWorldAABB()}
			aabb_cache[component] = cached
		end

		return cached.aabb
	end

	function visual.GetShadowVolumeChangeVersion(query_aabb)
		local acceleration = ensure_scene_acceleration()
		local max_version = get_shadow_tree_volume_change_version(query_aabb)
		local aabb_cache = get_dynamic_shadow_aabb_cache()

		for _, component in ipairs(acceleration.dynamic_shadow_components or {}) do
			local version = component.shadow_change_version or 0

			if
				is_aabb_intersecting(get_cached_component_world_aabb(aabb_cache, component, version), query_aabb)
			then
				max_version = math.max(max_version, version)
			end
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
			local version = component.shadow_change_version or 0
			local world_aabb = get_cached_component_world_aabb(aabb_cache, component, version)

			if not world_aabb or is_aabb_intersecting(world_aabb, query_aabb) then
				max_version = math.max(max_version, version)
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
		if not gpu_culling.culling_enabled then return true end

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
		if visual.freeze_frustum_planes and cached_frustum_frame >= 0 then
			print(cached_frustum_planes)
			return cached_frustum_planes
		end

		local current_frame = system.GetFrameNumber()
		local camera = render3d.GetCamera()
		local view = camera:BuildViewMatrix()
		local proj = camera:BuildUnjitteredProjectionMatrix()

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

	get_cull_camera_position = function()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0

		if cached_cull_camera_frame == current_frame and cached_cull_camera_position then
			return cached_cull_camera_position
		end

		local camera = render3d.GetCamera()
		cached_cull_camera_position = camera and camera.GetPosition and camera:GetPosition() or nil
		cached_cull_camera_frame = current_frame
		return cached_cull_camera_position
	end

	local function is_aabb_within_cull_distance(world_aabb, cull_distance, camera_position)
		if visual.noculling or not gpu_culling.culling_enabled then return true end

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
		if visual.noculling or not gpu_culling.culling_enabled then return true end

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, component:GetCullDistance(), get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes or get_frustum_planes())
	end

	local function is_static_item_visible(item, frustum_planes)
		if visual.noculling or not gpu_culling.culling_enabled then return true end

		local world_aabb = item.world_aabb

		if not world_aabb then return true end

		if
			not is_aabb_within_cull_distance(world_aabb, item.cull_distance, get_cull_camera_position())
		then
			return false
		end

		return is_aabb_visible_frustum(world_aabb, frustum_planes)
	end

	local function is_component_visible_in_current_cpu_list(component, frame, camera)
		local acceleration = ensure_scene_acceleration()

		if
			acceleration.visible_frame ~= frame or
			acceleration.visible_camera ~= camera or
			not acceleration.visible_components
		then
			return nil
		end

		for i = 1, #acceleration.visible_components do
			if acceleration.visible_components[i] == component then return true end
		end

		return false
	end

	local function scan_component(component, signatures, boxes, components, tolerance)
		local aabb = component:GetWorldAABB()
		local sig = signatures[component]

		if not aabb then
			if sig then
				signatures[component] = nil
				boxes[#boxes + 1] = sig
				components[#components + 1] = component
			end

			return
		end

		if not sig then
			signatures[component] = {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z}
			boxes[#boxes + 1] = signatures[component]
			components[#components + 1] = component
			return
		end

		if
			math.abs(aabb.min_x - sig[1]) > tolerance or
			math.abs(aabb.min_y - sig[2]) > tolerance or
			math.abs(aabb.min_z - sig[3]) > tolerance or
			math.abs(aabb.max_x - sig[4]) > tolerance or
			math.abs(aabb.max_y - sig[5]) > tolerance or
			math.abs(aabb.max_z - sig[6]) > tolerance
		then
			boxes[#boxes + 1] = {
				math.min(sig[1], aabb.min_x),
				math.min(sig[2], aabb.min_y),
				math.min(sig[3], aabb.min_z),
				math.max(sig[4], aabb.max_x),
				math.max(sig[5], aabb.max_y),
				math.max(sig[6], aabb.max_z),
			}
			components[#components + 1] = component
			sig[1] = aabb.min_x
			sig[2] = aabb.min_y
			sig[3] = aabb.min_z
			sig[4] = aabb.max_x
			sig[5] = aabb.max_y
			sig[6] = aabb.max_z
		end
	end

	function visual.ScanWorldAABBs()
		local frame = system.GetFrameNumber()

		if visual.aabb_scan_frame == frame then return visual.aabb_scan_changed end

		visual.aabb_scan_frame = frame
		local signatures = visual.aabb_signatures
		local candidates = visual.aabb_scan_candidates

		if
			signatures and
			not next(candidates)
			and
			not visual.aabb_forgotten_boxes[1]
		then
			visual.aabb_scan_changed = false
			visual.AABB_CHANGED_BOXES = nil
			visual.AABB_CHANGED_COMPONENTS = nil
			visual.AABB_CHANGED_ALL = false
			return false
		end

		visual.aabb_scan_candidates = {}

		if not signatures then
			local fresh = {}

			for _, component in ipairs(Visual.Instances) do
				local aabb = component:GetWorldAABB()

				if aabb then
					fresh[component] = {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z}
				end
			end

			visual.aabb_signatures = fresh
			visual.aabb_scan_changed = true
			visual.AABB_CHANGED_BOXES = nil
			visual.AABB_CHANGED_COMPONENTS = nil
			visual.AABB_CHANGED_ALL = true
			visual.scene_full_rebuild = true
			return true
		end

		local tolerance = visual.AABB_TOLERANCE
		local boxes = visual.aabb_forgotten_boxes
		visual.aabb_forgotten_boxes = {}
		local components = {}

		for component in pairs(candidates) do
			if component:IsValid() and not component.scene_removed then
				scan_component(component, signatures, boxes, components, tolerance)
			end
		end

		local changed = #boxes > 0
		visual.aabb_scan_changed = changed
		visual.AABB_CHANGED_BOXES = changed and boxes or nil
		visual.AABB_CHANGED_COMPONENTS = changed and components or nil
		visual.AABB_CHANGED_ALL = false

		if changed and #boxes > visual.DIRTY_BOX_CAP then
			visual.AABB_CHANGED_BOXES = nil
			visual.AABB_CHANGED_ALL = true
		end

		for _, component in ipairs(components) do
			mark_scene_component_dirty(component)
		end

		return changed
	end

	function visual.ForgetWorldAABB(component)
		local signatures = visual.aabb_signatures
		visual.aabb_scan_candidates[component] = true

		if not signatures or not signatures[component] then return end

		local list = visual.aabb_forgotten_boxes
		list[#list + 1] = signatures[component]
		signatures[component] = nil
	end

	local function is_component_frustum_culled(component)
		local frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local camera = render3d.GetCamera()
		local cpu_visible = is_component_visible_in_current_cpu_list(component, frame, camera)

		if cpu_visible ~= nil then return not cpu_visible end

		if not component.Visible then return true end

		if not component:GetRenderEntries()[1] then return false end

		return not is_world_aabb_visible(component, component:GetWorldAABB(), get_frustum_planes())
	end

	visual.IsComponentFrustumCulled = is_component_frustum_culled

	local function append_visible_component(out, component, frustum_planes)
		if not component.Visible then return out end

		local render_entries = component:GetRenderEntries()

		if not render_entries[1] then return out end

		local world_aabb = component:GetWorldAABB()
		local visible = is_world_aabb_visible(component, world_aabb, frustum_planes)

		if visible then out[#out + 1] = component end

		return out
	end

	local function append_component_render_entries(out, component, payloads)
		for _, entry in ipairs(component:GetRenderEntries() or {}) do
			local index = #out + 1
			local payload = payloads and payloads[index] or nil

			if not payload then
				payload = {
					component = component,
					entry = entry,
				}

				if payloads then payloads[index] = payload end
			else
				payload.component = component
				payload.entry = entry
			end

			out[index] = payload
		end

		return out
	end

	local function append_visible_static_item(out, item, frustum_planes)
		local component = item.component

		if not component.Visible then return out end

		local visible = is_static_item_visible(item, frustum_planes)

		if visible then out[#out + 1] = component end

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

	local function collect_visible_static_components(out, frustum_planes)
		local acceleration = ensure_scene_acceleration()
		local tree = acceleration.tree
		local camera_position = get_cull_camera_position()

		if tree then
			local node_stack = tree.traversal_context.node_stack
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
							local item = tree.components[i]

							if not item.dead then append_visible_static_item(out, item, frustum_planes) end
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

		for _, item in ipairs(acceleration.pending) do
			append_visible_static_item(out, item, frustum_planes)
		end

		return out
	end

	local function collect_volume_visible_static_components(out, query_aabb)
		local acceleration = ensure_scene_acceleration()
		local tree = acceleration.tree
		local camera_position = get_cull_camera_position()

		if tree then
			local node_stack = tree.traversal_context.node_stack
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
							local item = tree.components[i]

							if not item.dead then
								append_volume_visible_static_item(out, item, query_aabb)
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

		for _, item in ipairs(acceleration.pending) do
			append_volume_visible_static_item(out, item, query_aabb)
		end

		return out
	end

	function visual.InvalidateSceneAcceleration(component)
		if component then
			mark_scene_component_dirty(component)
		else
			invalidate_scene_acceleration()
		end
	end

	function visual.UpdateScene()
		ensure_scene_acceleration()
	end

	function visual.GetVisibleVisuals()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local acceleration = ensure_scene_acceleration()
		local camera = render3d.GetCamera()

		if
			acceleration.visible_frame == current_frame and
			acceleration.visible_camera == camera and
			acceleration.visible_components
		then
			return acceleration.visible_components
		end

		local frustum_planes = get_frustum_planes()
		local out = acceleration.visible_components or {}
		table.clear(out)
		collect_visible_static_components(out, frustum_planes)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_visible_component(out, component, frustum_planes)
		end

		acceleration.visible_frame = current_frame
		acceleration.visible_camera = camera
		acceleration.visible_components = out
		acceleration.visible_render_entries = nil
		acceleration.visible_render_entries_frame = nil
		return out
	end

	function visual.CollectCPUVisibleComponents(out)
		local acceleration = ensure_scene_acceleration()
		local frustum_planes = get_frustum_planes()
		table.clear(out)
		collect_visible_static_components(out, frustum_planes)

		for _, component in ipairs(acceleration.dynamic_components or {}) do
			append_visible_component(out, component, frustum_planes)
		end

		return out
	end

	function visual.GetVisibleRenderEntries()
		local current_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
		local acceleration = ensure_scene_acceleration()

		if
			acceleration.visible_render_entries_frame == current_frame and
			acceleration.visible_render_entries
		then
			return acceleration.visible_render_entries
		end

		visual.GetVisibleVisuals()
		local out = acceleration.visible_render_entries or {}
		local payloads = acceleration.visible_render_entry_payloads or {}
		table.clear(out)
		acceleration.visible_render_entry_payloads = payloads

		for _, component in ipairs(acceleration.visible_components) do
			append_component_render_entries(out, component, payloads)
		end

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

	function visual.GetShadowCasterWorldAABB()
		local acceleration = ensure_scene_acceleration()
		local out = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
		local tree = acceleration.shadow_tree

		if tree then AABB.Expand(out, tree.root.aabb) end

		for _, item in ipairs(acceleration.shadow_pending) do
			AABB.Expand(out, item.world_aabb)
		end

		for _, component in ipairs(acceleration.dynamic_shadow_components) do
			local box = component:GetWorldAABB()

			if box then AABB.Expand(out, box) end
		end

		for _, component in ipairs(acceleration.non_aabb_shadow_components) do
			local box = component:GetWorldAABB()

			if box then AABB.Expand(out, box) end
		end

		return out.min_x <= out.max_x and out or nil
	end

	function visual.GetSceneAcceleration()
		return ensure_scene_acceleration()
	end

	function visual.GetSceneVersion()
		ensure_scene_acceleration()
		return visual.scene_version
	end

	function visual.GetSceneMaterialUsers()
		ensure_scene_acceleration()
		return visual.material_users
	end

	function visual.IsOcclusionCullingEnabled()
		return visual.occlusion_culling_enabled
	end

	function visual.SetOcclusionCulling(enabled)
		if visual.occlusion_culling_enabled == enabled then return end

		visual.occlusion_culling_enabled = enabled
		gpu_culling.SetOcclusionMode(enabled and "hiz" or "disabled")

		for _, component in ipairs(Visual.Instances or {}) do
			if component.UseOcclusionCulling then
				component:SetUseOcclusionCulling(true)
			else
				component.using_conditional_rendering = false
				refresh_occlusion_registries(component)
			end
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

				if is_component_frustum_culled(component) then
					frustum_culled = frustum_culled + 1
				end

				if component.UseOcclusionCulling then
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
		if visual.noculling or not gpu_culling.culling_enabled then return true end

		local local_aabb = self:GetAABB()

		if not local_aabb or local_aabb.min_x > local_aabb.max_x then return true end

		local world_aabb = self:GetWorldAABB()

		if not world_aabb then return true end

		return is_world_aabb_visible(self, world_aabb)
	end

	function Visual:IsCulled()
		return is_component_frustum_culled(self)
	end

	function Visual:IsWithinCullDistance()
		if visual.noculling or not gpu_culling.culling_enabled then return true end

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
		if ignore_z then return material_ignores_z(self.MaterialOverride) end

		return material_draws_in_gbuffer(self.MaterialOverride)
	end

	if ignore_z then return self.HasIgnoreZRenderEntries end

	return self.HasOpaqueRenderEntries or
		(
			self.HasTranslucentRenderEntries and
			not render3d.pipelines.translucent_surface
		)
end

function Visual:DrawEntriesForPass(ignore_z, upload_constants, render_entries)
	local drew_any = false
	render_entries = render_entries or self:GetRenderEntries()

	for _, entry in ipairs(render_entries) do
		local material = self:GetResolvedMaterial(entry)

		if
			ignore_z and
			material_ignores_z(material) or
			not ignore_z and
			material_draws_in_gbuffer(material)
		then
			local transform = entry.transform
			local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()
			local prev_world_matrix = transform and
				transform:GetPreviousWorldMatrix() or
				self:GetPreviousWorldMatrix()

			if world_matrix then
				if
					not ignore_z and
					upload_constants == render3d.UploadGBufferConstants and
					not self.using_conditional_rendering and
					gbuffer_instancing.Queue(entry.polygon3d, material, world_matrix, prev_world_matrix)
				then
					drew_any = true
				else
					render3d.SetWorldMatrix(world_matrix, prev_world_matrix)
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

local function draw_geometry_entry(component, entry)
	local material = component:GetResolvedMaterial(entry)

	if not material_draws_in_gbuffer(material) then return false end

	local transform = entry.transform
	local world_matrix = transform and transform:GetWorldMatrix() or component:GetWorldMatrix()
	local prev_world_matrix = transform and
		transform:GetPreviousWorldMatrix() or
		component:GetPreviousWorldMatrix()

	if not world_matrix then return false end

	if
		gbuffer_instancing.Queue(entry.polygon3d, material, world_matrix, prev_world_matrix)
	then
		return true
	end

	render3d.SetWorldMatrix(world_matrix, prev_world_matrix)
	render3d.SetCurrentPolygon3D(entry.polygon3d)
	render3d.SetMaterial(material)
	render3d.UploadGBufferConstants()
	entry.polygon3d:Draw()
	return true
end

function Visual:DrawGeometryPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	if not self:HasRenderEntriesForPass(false, render_entries) then return end

	local cmd = render.GetCommandBuffer()

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

	self:DrawEntriesForPass(false, render3d.UploadGBufferConstants, render_entries)
end

function Visual:OnDraw3DGeometry()
	return self:DrawGeometryPass()
end

function Visual:DrawForwardOverlayPass(render_entries, skip_visibility)
	if not self.Visible then return end

	render_entries = render_entries or self:GetRenderEntries()

	if not render_entries[1] then return end

	local overlay = self.OverlayMaterial

	if not overlay and not self:HasRenderEntriesForPass(true, render_entries) then
		return
	end

	if not skip_visibility and not self:IsAABBVisibleLocal() then return end

	if self.HasIgnoreZRenderEntries or self.MaterialOverride then
		self:DrawEntriesForPass(true, render3d.UploadForwardOverlayConstants, render_entries)
	end

	if not overlay then return end

	for _, entry in ipairs(render_entries) do
		local transform = entry.transform
		local world_matrix = transform and transform:GetWorldMatrix() or self:GetWorldMatrix()

		if world_matrix then
			render3d.SetWorldMatrix(world_matrix, world_matrix)
			render3d.SetCurrentPolygon3D(entry.polygon3d)
			render3d.SetMaterial(overlay)
			render3d.UploadForwardOverlayConstants()
			entry.polygon3d:Draw()
		end
	end
end

function Visual:OnDraw3DForwardOverlay()
	return self:DrawForwardOverlayPass()
end

function Visual:OnChildAdd()
	self:InvalidateHierarchyState()
end

function Visual:OnChildRemove()
	self:InvalidateHierarchyState()
end

function Visual:OnAdd()
	self.scene_removed = false

	if self:IsDebugHidden() then self:RefreshVisible() end

	visual.aabb_scan_candidates[self] = true
	mark_shadow_change(self)
	mark_scene_component_dirty(self, true)
	refresh_visual_registries(self)
end

function Visual:OnRemove()
	self:SetLoading(false)
	registry_remove(visual.shadow_casters, "shadow_registry_index", self)
	registry_remove(visual.forward_overlay_components, "forward_overlay_registry_index", self)
	registry_remove(visual.translucent_components, "translucent_registry_index", self)
	self.scene_removed = true
	scene_bridge.RemoveVisual(self)
	self.RenderEntries = {}
	self:InvalidateRenderEntries()
	visual.scene_dirty_components[self] = nil
	local acceleration = visual.scene_acceleration

	if acceleration then
		set_component_scene_items(acceleration, self, false, false)
		refresh_material_users(self, false)
		visual.scene_publish_pending = true
	end
end

function Visual:OnFirstCreated()
	local main_visible_components = {}
	local store_pipelines = {}

	event.AddListener("Draw3DGeometry", "visual_geometry_draw", function()
		store_pipelines[1] = render3d.pipelines.gbuffer_multi_draw
		store_pipelines[2] = render3d.pipelines.gbuffer_multi_draw_height_map
		local camera_position = render3d.GetCamera():GetPosition()

		if
			not visual.noculling and
			store_pipelines[2] and
			scene_draw.Draw(gbuffer_instancing, store_pipelines)
		then
			for component in pairs(scene_bridge.GetCPUDrawnVisuals()) do
				if component.Visible and not component:IsCulled() then
					for _, entry in ipairs(component:GetLODEntriesAt(camera_position)) do
						if not scene_bridge.IsRasterEntry(component, entry) then
							draw_geometry_entry(component, entry)
						end
					end
				end
			end

			return
		end

		for _, component in ipairs(visual.CollectCPUVisibleComponents(main_visible_components)) do
			for _, entry in ipairs(component:GetLODEntriesAt(camera_position)) do
				draw_geometry_entry(component, entry)
			end
		end
	end)

	event.AddListener("Draw3DForwardOverlay", "visual_forward_overlay_draw", function()
		for _, component in ipairs(visual.forward_overlay_components) do
			if not component:IsCulled() then
				component:DrawForwardOverlayPass(nil, true)
			end
		end
	end)

	do
		local draw_count = 0
		local draw_entries, draw_materials, draw_world_matrices, draw_prev_world_matrices, draw_thicknesses = {}, {}, {}, {}, {}
		local item_caches = setmetatable({}, {__mode = "k"})
		local MATRIX_SIZE = ffi.sizeof(Matrix44)

		local function get_refraction_thickness(material, entry, world_matrix)
			local thickness = material:GetRefractionThickness()

			if thickness >= 0 then return thickness end

			local aabb = entry.source_aabb

			if not aabb then return 0 end

			local m = world_matrix
			return math.min(
				(
						aabb.max_x - aabb.min_x
					) * math.sqrt(m.m00 * m.m00 + m.m01 * m.m01 + m.m02 * m.m02),
				(
						aabb.max_y - aabb.min_y
					) * math.sqrt(m.m10 * m.m10 + m.m11 * m.m11 + m.m12 * m.m12),
				(
						aabb.max_z - aabb.min_z
					) * math.sqrt(m.m20 * m.m20 + m.m21 * m.m21 + m.m22 * m.m22)
			)
		end

		local function get_items(component)
			local entries = component:GetRenderEntries()
			local cache = item_caches[component]

			if
				cache and
				cache.entries == entries and
				cache.material_override == component.MaterialOverride
			then
				local items = cache.items
				local valid = true

				for i = 1, #items do
					local item = items[i]

					if item.material.property_version ~= item.version then
						valid = false

						break
					end
				end

				if valid then return items end
			end

			local items = cache and cache.items or {}
			local count = 0

			for _, entry in ipairs(entries) do
				local material = component:GetResolvedMaterial(entry)
				count = count + 1
				local item = items[count]

				if not item then
					item = {matrix = Matrix44()}
					items[count] = item
				end

				local translucent = material_is_translucent(material)
				item.entry = entry
				item.material = material
				item.version = material.property_version
				item.translucent = translucent
				item.refractive = translucent and material:GetRefraction() > 0
				item.has_matrix = false
			end

			for i = count + 1, #items do
				items[i] = nil
			end

			if not cache then
				cache = {}
				item_caches[component] = cache
			end

			cache.entries = entries
			cache.material_override = component.MaterialOverride
			cache.items = items
			return items
		end

		local function get_item_matrix(component, item)
			local entry = item.entry
			local world_matrix = entry.transform and
				entry.transform:GetWorldMatrix() or
				component:GetWorldMatrix()

			if not world_matrix then return nil end

			if item.has_matrix and memcmp(item.matrix, world_matrix, MATRIX_SIZE) == 0 then
				return world_matrix
			end

			ffi.copy(item.matrix, world_matrix, MATRIX_SIZE)
			item.has_matrix = true
			local aabb = entry.source_aabb
			local x, y, z = 0, 0, 0
			local radius = math.huge

			if aabb then
				x, y, z = (aabb.min_x + aabb.max_x) * 0.5,
				(aabb.min_y + aabb.max_y) * 0.5,
				(aabb.min_z + aabb.max_z) * 0.5
				local m = world_matrix
				local dx, dy, dz = aabb.max_x - aabb.min_x, aabb.max_y - aabb.min_y, aabb.max_z - aabb.min_z
				radius = 0.5 * math.sqrt(dx * dx + dy * dy + dz * dz) * math.sqrt(
						math.max(
							m.m00 * m.m00 + m.m01 * m.m01 + m.m02 * m.m02,
							m.m10 * m.m10 + m.m11 * m.m11 + m.m12 * m.m12,
							m.m20 * m.m20 + m.m21 * m.m21 + m.m22 * m.m22
						)
					)
			end

			item.center_x, item.center_y, item.center_z = world_matrix:TransformVectorUnpacked(x, y, z)
			item.radius = radius
			item.thickness = item.refractive and
				get_refraction_thickness(item.material, entry, world_matrix) or
				0
			return world_matrix
		end

		event.AddListener("PreDraw3DTranslucent", "visual_translucent_collect", function()
			local camera_position = render3d.GetCamera():GetPosition()
			local camera_x, camera_y, camera_z = camera_position.x, camera_position.y, camera_position.z
			local previous_count = draw_count
			local in_store = scene_draw.IsCulled()
			draw_count = 0

			for _, component in ipairs(visual.translucent_components) do
				if component.Visible and not component:IsCulled() then
					local items = get_items(component)

					for i = 1, #items do
						local item = items[i]

						if
							item.translucent and
							not (
								component.ViewHidden or
								item.entry.primitive.ViewHidden
							)
						then
							local world_matrix = get_item_matrix(component, item)

							if world_matrix then
								local x, y, z = item.center_x - camera_x, item.center_y - camera_y, item.center_z - camera_z
								local distance = math.sqrt(x * x + y * y + z * z)
								render3d.ExtendTranslucentDepthRange(distance - item.radius, distance + item.radius)

								if item.refractive then render3d.RequestRefractionSource() end

								local entry = item.entry

								if not (in_store and scene_bridge.IsRasterEntry(component, entry)) then
									draw_count = draw_count + 1
									draw_entries[draw_count] = entry
									draw_materials[draw_count] = item.material
									draw_world_matrices[draw_count] = world_matrix
									draw_prev_world_matrices[draw_count] = entry.transform and
										entry.transform:GetPreviousWorldMatrix() or
										component:GetPreviousWorldMatrix()
									draw_thicknesses[draw_count] = item.thickness
								end
							end
						end
					end
				end
			end

			for i = draw_count + 1, previous_count do
				draw_entries[i] = nil
				draw_materials[i] = nil
				draw_world_matrices[i] = nil
				draw_prev_world_matrices[i] = nil
			end
		end)

		event.AddListener("Draw3DTranslucent", "visual_translucent_draw", function()
			local multi_draw_pipeline = render3d.translucent_multi_draw_pipeline

			if multi_draw_pipeline then
				scene_draw.DrawTranslucent(gbuffer_instancing, multi_draw_pipeline)
			end

			gpu_timing.SetInfo(render3d.translucent_scope, "cpu_draws", draw_count)
			gpu_timing.SetInfo(render3d.translucent_scope, "components", #visual.translucent_components)

			for i = 1, draw_count do
				local polygon3d = draw_entries[i].polygon3d
				render3d.SetWorldMatrix(draw_world_matrices[i], draw_prev_world_matrices[i])
				render3d.SetCurrentPolygon3D(polygon3d)
				render3d.SetMaterial(draw_materials[i])
				render3d.UploadTranslucentConstants(draw_thicknesses[i])
				polygon3d:Draw()
			end
		end)
	end

	event.AddListener("PrimeAllShadowMaterials", "visual_shadow_prime", function(shadow_map)
		local prime_versions = visual.shadow_prime_versions
		local current_visible_list_version = visual.shadow_visible_list_version or 0
		local current_shadow_change_version = visual.shadow_change_version_counter or 0
		local cache = prime_versions[shadow_map]

		if
			cache and
			cache.shadow_visible_list_version == current_visible_list_version and
			cache.shadow_change_version == current_shadow_change_version
		then
			return
		end

		ensure_scene_acceleration()

		for material, users in pairs(visual.material_users) do
			for component in pairs(users) do
				if component.CastShadows then
					shadow_map:PrimeMaterial(material)

					break
				end
			end
		end

		prime_versions[shadow_map] = {
			shadow_visible_list_version = current_visible_list_version,
			shadow_change_version = current_shadow_change_version,
		}
	end)

	event.AddListener("DrawAllShadows", "visual_shadow_draw", function(shadow_map, cascade_idx)
		shadow_map:DrawScene(cascade_idx)
	end)
end

function Visual:OnLastRemoved()
	event.RemoveListener("DrawAllShadows", "visual_shadow_draw")
	event.RemoveListener("PrimeAllShadowMaterials", "visual_shadow_prime")
end

return Visual:Register()
