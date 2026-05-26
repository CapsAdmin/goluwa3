local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Quat = import("goluwa/structs/quat.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local Visual = import("goluwa/ecs/components/3d/visual.lua")
local event = import("goluwa/event.lua")
local Light = prototype.CreateTemplate("light")
local MAX_SHADOW_PASSES_PER_FRAME = 4
local shadow_pass_budget_frame = -1
local shadow_passes_used = 0

local function reset_shadow_pass_budget()
	local frame = system.GetFrameNumber()

	if shadow_pass_budget_frame ~= frame then
		shadow_pass_budget_frame = frame
		shadow_passes_used = 0
	end
end

local function consume_shadow_pass_budget(pass_count)
	reset_shadow_pass_budget()
	local remaining = math.max(MAX_SHADOW_PASSES_PER_FRAME - shadow_passes_used, 0)
	local granted = math.min(pass_count, remaining)
	shadow_passes_used = shadow_passes_used + granted
	return granted
end

Light.Events = {"PreFrame"}
Light:StartStorable()
Light:GetSet("LightType", "directional")
Light:GetSet("Color", Color(1.0, 1.0, 1.0, 1.0))
Light:GetSet("Intensity", 1.0)
Light:GetSet("Range", 200.0)
Light:GetSet("InnerCone", 0.9)
Light:GetSet("OuterCone", 0.8)
Light:GetSet("Enabled", true)
Light:GetSet("CastShadows", false)
Light:GetSet("ShadowMap", nil)
Light:EndStorable()

function Light:Initialize()
	self:AddGlobalEvent("PreFrame")
	self.LastShadowUpdateFrame = nil
	self.LastShadowPosition = nil
	self.LastShadowRotation = nil
	self.NextShadowCascadeIndex = 1
	self.NextInsetShadowCascadeIndex = 1
	self.ShadowSceneDirty = true
	self.ShadowNeedsCompletion = false
	local world = self.Owner and self.Owner.GetRoot and self.Owner:GetRoot()

	if world and world.AddLocalListener then
		local remove_listener = world:AddLocalListener("OnEntityHierarchyChanged", function()
			self.ShadowSceneDirty = true
		end)
		self:CallOnRemove(remove_listener, remove_listener)
	end
end

function Light:SetLightType(light_type)
	self.LightType = light_type

	if light_type == "sun" then self:SetName("sun") end
end

local function position_changed(a, b, epsilon)
	if not a or not b then return true end

	epsilon = epsilon or 0

	if epsilon <= 0 then return a.x ~= b.x or a.y ~= b.y or a.z ~= b.z end

	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return dx * dx + dy * dy + dz * dz > epsilon * epsilon
end

local function rotation_changed(a, b, epsilon)
	if not a or not b then return true end

	epsilon = epsilon or 0

	if epsilon <= 0 then
		return a.x ~= b.x or a.y ~= b.y or a.z ~= b.z or a.w ~= b.w
	end

	return 1 - math.abs(a:Dot(b)) > epsilon
end

local function shadow_transform_dirty(self, config)
	if self.ShadowSceneDirty then return true end

	local transform = self.Owner and self.Owner.transform

	if not transform then return true end

	local position = transform:GetPosition()
	local rotation = transform:GetRotation()
	local position_epsilon = config.shadow_position_epsilon or 0
	local rotation_epsilon = config.shadow_rotation_epsilon or 0

	if self.LightType == "sun" then
		return rotation_changed(rotation, self.LastShadowRotation, rotation_epsilon)
	elseif self.LightType == "point" then
		return position_changed(position, self.LastShadowPosition, position_epsilon)
	elseif self.LightType == "directional" then
		return position_changed(position, self.LastShadowPosition, position_epsilon) or
			rotation_changed(rotation, self.LastShadowRotation, rotation_epsilon)
	end

	return position_changed(position, self.LastShadowPosition, position_epsilon) or
		rotation_changed(rotation, self.LastShadowRotation, rotation_epsilon)
end

local function get_shadow_volume_change_version(shadow_map, cascade_idx)
	local visual_library = Visual and Visual.Library

	if not visual_library or not visual_library.GetShadowVolumeChangeVersion then
		return nil
	end

	local world_aabb = shadow_map:GetCascadeWorldAABB(cascade_idx)

	if not world_aabb then return nil end

	return visual_library.GetShadowVolumeChangeVersion(world_aabb)
end

local function build_shadow_cascade_update_mask(self, shadow_map)
	local config = self.CastShadows or {}

	if not shadow_map or shadow_map.mode == "point" then return nil end

	if config.farthest_cascade_update_mode ~= "world_changed" then return nil end

	local farthest_cascade_idx = shadow_map:GetCascadeCount()

	if farthest_cascade_idx <= 1 then return nil end

	local mask = {}

	for i = 1, farthest_cascade_idx do
		mask[i] = true
	end

	local farthest_cascade = shadow_map.cascade[farthest_cascade_idx]

	if not farthest_cascade or not farthest_cascade.last_rendered_frame then
		return mask
	end

	local light_rotation = self.Owner and self.Owner.transform and self.Owner.transform:GetRotation() or nil

	if
		rotation_changed(light_rotation, self.LastShadowRotation, config.shadow_rotation_epsilon or 0)
	then
		return mask
	end

	local camera = render3d.GetCamera()
	local camera_position = camera and camera.GetPosition and camera:GetPosition() or nil
	local camera_moved = position_changed(
		camera_position,
		farthest_cascade.last_camera_position,
		config.farthest_cascade_camera_position_threshold or 0
	)
	local shadow_volume_change_version = get_shadow_volume_change_version(shadow_map, farthest_cascade_idx)
	local world_changed = shadow_volume_change_version == nil or
		shadow_volume_change_version > (
			farthest_cascade.last_shadow_volume_change_version or
			0
		)

	if not camera_moved and not world_changed then
		mask[farthest_cascade_idx] = false
	end

	return mask
end

local function mark_shadow_update_progress(self, complete)
	self.LastShadowUpdateFrame = system.GetFrameNumber()

	if not complete then
		self.ShadowNeedsCompletion = true
		return
	end

	local transform = self.Owner and self.Owner.transform

	if not transform then
		self.LastShadowPosition = nil
		self.LastShadowRotation = nil
	else
		self.LastShadowPosition = transform:GetPosition():Copy()
		self.LastShadowRotation = transform:GetRotation():Copy()
	end

	self.ShadowSceneDirty = false
	self.ShadowNeedsCompletion = false
	self.NextShadowCascadeIndex = 1
	self.NextInsetShadowCascadeIndex = 1
end

function Light:OnPreFrame(dt)
	if not self:GetCastShadows() then return end

	local config = self.CastShadows
	local mode = config.shadow_update_mode

	if mode == nil then
		mode = self.LightType == "sun" and "continuous" or "on_move"
	end

	local restart_shadow_update = false

	if mode == "on_move" then
		restart_shadow_update = shadow_transform_dirty(self, config)

		if not (restart_shadow_update or self.ShadowNeedsCompletion) then return end
	else
		local interval = config.shadow_update_interval

		if interval and interval > 1 then
			local frame = system.GetFrameNumber()

			if self.LastShadowUpdateFrame and frame - self.LastShadowUpdateFrame < interval then
				return
			end
		end

		restart_shadow_update = true
	end

	if restart_shadow_update and not self.ShadowNeedsCompletion then
		self.NextShadowCascadeIndex = 1
		self.NextInsetShadowCascadeIndex = 1
	end

	local complete, rendered_any = self:RenderShadows()

	if rendered_any then mark_shadow_update_progress(self, complete) end
end

local function get_default_shadow_config(self)
	if self.LightType == "sun" then
		return {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		}
	elseif self.LightType == "directional" then
		return {
			ortho_size = self.Range,
			near_plane = 0.1,
			far_plane = self.Range,
			max_shadow_distance = self.Range,
		}
	elseif self.LightType == "point" then
		return {
			near_plane = 0.05,
			far_plane = self.Range,
			range = self.Range,
		}
	elseif self.LightType == "spot" then
		error("NYI spot light", 2)
	end

	error("Unknown light type: " .. tostring(self.LightType), 2)
end

function Light:SetCastShadows(config)
	if not config then
		self.CastShadows = false
		self.ShadowMap = nil
		self.InsetShadowMap = nil
		self.LastShadowUpdateFrame = nil
		self.LastShadowPosition = nil
		self.LastShadowRotation = nil
		self.NextShadowCascadeIndex = 1
		self.NextInsetShadowCascadeIndex = 1
		self.ShadowSceneDirty = true
		self.ShadowNeedsCompletion = false
		return
	end

	if config == true then
		config = type(self.CastShadows) == "table" and
			self.CastShadows or
			get_default_shadow_config(self)
	elseif type(config) ~= "table" then
		error("SetCastShadows expects false, true, or a config table", 2)
	end

	self.CastShadows = config
	self.LastShadowUpdateFrame = nil
	self.LastShadowPosition = nil
	self.LastShadowRotation = nil
	self.NextShadowCascadeIndex = 1
	self.NextInsetShadowCascadeIndex = 1
	self.ShadowSceneDirty = true
	self.ShadowNeedsCompletion = false
	local cascade_count = config.cascade_count or (config.cascade_sizes and #config.cascade_sizes) or nil

	if self.LightType == "sun" then
		local disable_vertex_animation_cascades = {}

		if
			config.farthest_cascade_disable_vertex_animation and
			cascade_count and
			cascade_count > 0
		then
			disable_vertex_animation_cascades[cascade_count] = true
		end

		self.ShadowMap = ShadowMap.New{
			mode = "sun",
			size = config.size,
			cascade_formats = config.cascade_formats,
			cascade_sizes = config.cascade_sizes,
			cascade_zoom_factors = config.cascade_zoom_factors,
			min_caster_texel_size = config.min_caster_texel_size,
			sticky_cascade_index = cascade_count,
			disable_vertex_animation_cascades = disable_vertex_animation_cascades,
			cascade_count = cascade_count,
			cascade_split_lambda = config.cascade_split_lambda,
			max_shadow_distance = config.max_shadow_distance or config.far_plane,
			ortho_size = config.ortho_size or 50.0,
			near_plane = config.near_plane or 1.0,
			far_plane = config.far_plane or 200.0,
		}

		if config.inset_shadows then
			local inset = config.inset_shadows
			self.InsetShadowMap = ShadowMap.New{
				size = inset.size or config.size,
				cascade_count = 1,
				cascade_formats = inset.cascade_formats,
				cascade_sizes = {inset.size or config.size},
				cascade_zoom_factors = {inset.zoom_factor or 1},
				min_caster_texel_size = inset.min_caster_texel_size or config.min_caster_texel_size,
				cascade_split_lambda = 1,
				max_shadow_distance = inset.distance or 64,
				ortho_size = inset.ortho_size or config.ortho_size or 50.0,
				near_plane = inset.near_plane or config.near_plane or 1.0,
				far_plane = inset.far_plane or inset.distance or config.far_plane or 200.0,
			}
		else
			self.InsetShadowMap = nil
		end
	elseif self.LightType == "directional" then
		self.ShadowMap = ShadowMap.New{
			mode = "directional",
			size = config.size,
			cascade_count = 1,
			cascade_formats = config.cascade_formats,
			cascade_sizes = {config.size},
			min_caster_texel_size = config.min_caster_texel_size,
			ortho_size = config.ortho_size or self.Range,
			near_plane = config.near_plane or 0.1,
			far_plane = config.far_plane or self.Range,
			max_shadow_distance = config.max_shadow_distance or self.Range,
		}
		self.InsetShadowMap = nil
	elseif self.LightType == "point" then
		self.ShadowMap = ShadowMap.New{
			mode = "point",
			size = config.size,
			min_caster_texel_size = config.min_caster_texel_size,
			near_plane = config.near_plane or 0.05,
			far_plane = config.far_plane or config.range or self.Range,
		}
		self.InsetShadowMap = nil
	elseif self.LightType == "spot" then
		error("NYI spot light", 2)
		self.CastShadows = false
	else
		error("Unknown light type: " .. tostring(self.LightType), 2)
		self.CastShadows = false
	end
end

function Light:UpdateShadowMap(main_cascade_update_mask)
	if not self.ShadowMap then return end

	if self.LightType == "point" then
		self.ShadowMap:UpdatePointLightMatrices(self.Owner.transform:GetPosition())
	elseif self.LightType == "directional" then
		local shadow_rotation = self.Owner.transform:GetRotation() * Quat():SetAngles(Deg3(0, 180, 0))
		self.ShadowMap:UpdateLocalDirectionalLightMatrices(
			self.Owner.transform:GetPosition(),
			shadow_rotation,
			self.Range,
			self.ShadowMap:GetSize().w > 0 and self.ShadowMap.ortho_size or self.Range
		)
	else
		self.ShadowMap:UpdateCascadeLightMatrices(self.Owner.transform:GetRotation(), main_cascade_update_mask)
	end

	if self.InsetShadowMap then
		self.InsetShadowMap:UpdateCascadeLightMatrices(self.Owner.transform:GetRotation())
	end
end

function Light:RenderShadows()
	if not self:GetCastShadows() then return true, false end

	local function render_shadow_map_batch(light, shadow_map, next_index_key)
		local start_index = light[next_index_key] or 1
		local cascade_count = shadow_map:GetCascadeCount()

		if start_index > cascade_count then start_index = 1 end

		local cascade_update_mask = next_index_key == "NextShadowCascadeIndex" and
			build_shadow_cascade_update_mask(light, shadow_map) or
			nil
		local eligible_indices = {}

		for cascade_idx = start_index, cascade_count do
			if not cascade_update_mask or cascade_update_mask[cascade_idx] ~= false then
				eligible_indices[#eligible_indices + 1] = cascade_idx
			end
		end

		if #eligible_indices == 0 then
			light[next_index_key] = 1
			return true, false
		end

		local passes_to_render = consume_shadow_pass_budget(#eligible_indices)

		if passes_to_render <= 0 then return false, false end

		for i = 1, passes_to_render do
			local cascade_idx = eligible_indices[i]
			local shadow_cmd = shadow_map:Begin(cascade_idx, i == 1)
			render.PushCommandBuffer(shadow_cmd)
			event.Call("DrawAllShadows", shadow_map, cascade_idx)
			render.PopCommandBuffer()
			shadow_map:End(cascade_idx, i == passes_to_render)
			shadow_map:MarkCascadeRendered(
				cascade_idx,
				get_shadow_volume_change_version(shadow_map, cascade_idx),
				render3d.GetCamera() and render3d.GetCamera():GetPosition() or nil
			)
		end

		if passes_to_render >= #eligible_indices then
			light[next_index_key] = 1
			return true, true
		end

		light[next_index_key] = eligible_indices[passes_to_render] + 1
		return false, true
	end

	self:UpdateShadowMap(build_shadow_cascade_update_mask(self, self.ShadowMap))
	event.Call("PrimeAllShadowMaterials", self.ShadowMap)

	if self.InsetShadowMap then
		event.Call("PrimeAllShadowMaterials", self.InsetShadowMap)
	end

	local main_complete, main_rendered = render_shadow_map_batch(self, self.ShadowMap, "NextShadowCascadeIndex")
	local inset_complete = true
	local inset_rendered = false

	if main_complete and self.InsetShadowMap then
		inset_complete, inset_rendered = render_shadow_map_batch(self, self.InsetShadowMap, "NextInsetShadowCascadeIndex")
	end

	return main_complete and inset_complete, main_rendered or inset_rendered
end

return Light:Register()
