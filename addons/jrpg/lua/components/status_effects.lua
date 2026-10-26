local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local META = objects.CreateTemplate("status_effects")
META.Network = {
	Encoded = {"string", 0.1, "reliable", to_owner = true},
}
META:GetSet("Encoded", "")
local SMOOTH_SPEED = 6
local names = {}

function META:Initialize()
	self.amounts = {}
	self.targets = {}
	self.sources = {}
	self.next_think = {}
	self.time = 0
	self:AddGlobalEvent("Update")
end

function META:GetAmount(name)
	return self.amounts[name] or 0
end

function META:GetSource(name)
	return self.sources[name]
end

function META:SetAmount(name, amount, source)
	local definition = status_effects.GetDefinition(name)
	amount = math.clamp(amount, 0, definition.Max)

	if amount <= 0 then
		if self.amounts[name] and definition.OnStop then
			definition.OnStop(self.Owner, self)
		end

		self.amounts[name] = nil
		self.sources[name] = nil
		self.next_think[name] = nil
		return
	end

	if not self.amounts[name] then
		self.next_think[name] = self.time + definition.Rate

		if definition.OnStart then definition.OnStart(self.Owner, self) end
	end

	self.amounts[name] = amount

	if source then self.sources[name] = source end
end

function META:Clear()
	for name in pairs(self.amounts) do
		self:SetAmount(name, 0)
	end
end

function META:OnDeath()
	if network.HasAuthority() then self:Clear() end
end

function META:Encode()
	local parts = {}

	for _, definition in ipairs(status_effects.List) do
		local amount = self.amounts[definition.Name]

		if amount then
			parts[#parts + 1] = definition.Name .. "=" .. math.ceil(amount * 100)
		end
	end

	return table.concat(parts, " ")
end

function META:OnUpdate(dt)
	self.time = self.time + dt

	if not network.HasAuthority() then
		if self.decoded ~= self.Encoded then
			self.decoded = self.Encoded
			table.clear(self.targets)

			for name, amount in self.Encoded:gmatch("(%w+)=(%d+)") do
				self.targets[name] = tonumber(amount) / 100
			end
		end

		for name, amount in pairs(self.amounts) do
			if not self.targets[name] then
				amount = amount - dt * SMOOTH_SPEED * 0.5
				self.amounts[name] = amount > 0.001 and amount or nil
			end
		end

		for name, target in pairs(self.targets) do
			local amount = self.amounts[name] or target
			self.amounts[name] = amount + (target - amount) * math.min(dt * SMOOTH_SPEED, 1)
		end

		return
	end

	table.clear(names)

	for name in pairs(self.amounts) do
		names[#names + 1] = name
	end

	for _, name in ipairs(names) do
		local amount = self.amounts[name]

		if amount then
			local definition = status_effects.Registered[name]

			if definition.Think and self.time >= self.next_think[name] then
				self.next_think[name] = self.time + definition.Rate
				definition.Think(self.Owner, amount, self.sources[name], self)
			end

			if self.amounts[name] then
				self:SetAmount(name, self.amounts[name] - definition.Decay * dt)
			end
		end
	end

	self:SetEncoded(self:Encode())
end

function META:OnCanAttack()
	if not status_effects.CanAttack(self.Owner) then return false end
end

return META:Register()
