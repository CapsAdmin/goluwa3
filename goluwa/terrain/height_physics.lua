local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local TerrainPhysics = import("goluwa/terrain/physics.lua")
local ffi = require("ffi")
local FloatArray = ffi.typeof("float[?]")
local HeightPhysics = {}
HeightPhysics.__index = HeightPhysics

function HeightPhysics.New(config)
	local self = setmetatable({}, HeightPhysics)
	self.Name = config.Name or "terrain"
	self.Height = config.Height
	self.PhysicsConfig = config.Physics
	self.UpdateInterval = config.UpdateInterval or 0.1
	self.UpdateId = self.Name .. "_update"
	self.time_until_update = 0
	return self
end

function HeightPhysics:AcquireChunk(request, callback)
	local samples = request.samples
	local step = request.size / (samples - 1)
	local heights = FloatArray(samples * samples)
	local height = self.Height

	for z = 0, samples - 1 do
		for x = 0, samples - 1 do
			heights[z * samples + x] = height(request.min_x + x * step, request.min_z + z * step)
		end
	end

	callback{heights = heights, request = request}
	return request
end

function HeightPhysics:ReleaseChunk() end

function HeightPhysics:Start()
	self:Stop()
	self.Root = Entity.New{Name = self.Name}
	self.Root:SetTransient(true)
	self.Root:AddComponent("transform")
	self.Physics = TerrainPhysics.New(self, self.PhysicsConfig)
	self.time_until_update = 0

	event.AddListener("Update", self.UpdateId, function(dt)
		if not self.Root:IsValid() then
			event.RemoveListener("Update", self.UpdateId)
			return
		end

		self.time_until_update = self.time_until_update - dt

		if self.time_until_update > 0 then return end

		self.time_until_update = self.UpdateInterval
		self.Physics:Update()
	end)

	return self
end

function HeightPhysics:Stop()
	event.RemoveListener("Update", self.UpdateId)

	if self.Physics then
		self.Physics:Remove()
		self.Physics = nil
	end

	if self.Root and self.Root:IsValid() then self.Root:Remove() end

	self.Root = nil
	return self
end

return HeightPhysics
