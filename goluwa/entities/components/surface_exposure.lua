local Vec3 = import("goluwa/structs/vec3.lua")
local objects = import("goluwa/objects/objects.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local SurfaceExposure = objects.CreateTemplate("surface_exposure")
SurfaceExposure:StartStorable()
SurfaceExposure:GetSet("Rate", 10)
SurfaceExposure:EndStorable()
local SAMPLE_PADDING = 0.25
local MIN_INTENSITY = 0.02

local function collect_visuals(entity, out)
	if entity.visual then out[#out + 1] = entity.visual end

	for _, child in ipairs(entity:GetChildren()) do
		collect_visuals(child, out)
	end
end

function SurfaceExposure:Initialize()
	self.time = 0
	self.states = {}
	self.visuals = {}
	self.children = false
	self.engaged = false
	self:AddGlobalEvent("Update")
end

function SurfaceExposure:ReleaseHandles(fade_out)
	for _, state in pairs(self.states) do
		for i = 1, #state.handles do
			state.handles[i]:Remove(fade_out)
			state.handles[i] = nil
		end
	end
end

function SurfaceExposure:OnUpdate(dt)
	self.time = self.time + dt

	if self.time < 1 / self.Rate then return end

	local step = self.time
	self.time = 0
	local sampling = surface_conditions.HasContent()

	if not sampling and not self.engaged then return end

	local owner = self.Owner
	local children = owner:GetChildrenList()

	if self.children ~= children then
		self.children = children
		self:ReleaseHandles()
		table.clear(self.visuals)
		collect_visuals(owner, self.visuals)
	end

	local visuals = self.visuals
	local min_x, min_y, min_z, max_x, max_z = math.huge, math.huge, math.huge, -math.huge, -math.huge

	for i = 1, #visuals do
		local box = visuals[i]:GetWorldAABB()

		if box then
			min_x, min_y, min_z = math.min(min_x, box.min_x), math.min(min_y, box.min_y), math.min(min_z, box.min_z)
			max_x, max_z = math.max(max_x, box.max_x), math.max(max_z, box.max_z)
		end
	end

	if min_x == math.huge then return end

	local position = self.sample_position or Vec3()
	self.sample_position = position
	position:Set((min_x + max_x) * 0.5, min_y, (min_z + max_z) * 0.5)
	local radius = math.max(max_x - min_x, max_z - min_z) * 0.5 + SAMPLE_PADDING
	local engaged = false

	for _, kind in ipairs(surface_conditions.kinds) do
		for _, entry in ipairs(kind.exposure or {}) do
			local state = self.states[entry]

			if not state then
				state = {handles = {}, level = 0}
				self.states[entry] = state
			end

			local over = 0

			if sampling then
				local threshold = entry.Threshold or 0
				over = math.clamp(
					(
						surface_conditions.Query(position, radius, entry.Channel) - threshold
					) / (
						1 - threshold
					),
					0,
					1
				)
			end

			if entry.Latch then
				state.level = math.min(state.level + over * entry.Latch * step, 1)
			else
				state.level = over
			end

			local intensity = state.level * (entry.Intensity or 1)
			local handles = state.handles

			if intensity > MIN_INTENSITY then
				if not handles[1] then
					local config = table.shallow_copy(entry.Config or {})
					config.Intensity = intensity

					for i = 1, #visuals do
						handles[i] = surface_overlays.Add(visuals[i], entry.Overlay, config)
					end

					state.applied = intensity
				elseif math.abs(intensity - state.applied) > MIN_INTENSITY then
					state.applied = intensity

					for i = 1, #handles do
						handles[i]:SetIntensity(intensity)
					end
				end
			elseif handles[1] and not entry.Latch then
				for i = 1, #handles do
					handles[i]:Remove(entry.FadeOut)
					handles[i] = nil
				end
			end

			if handles[1] then engaged = true end
		end
	end

	self.engaged = engaged
end

function SurfaceExposure:OnRemove()
	self:ReleaseHandles()
end

return SurfaceExposure:Register()
