local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Flex = objects.CreateTemplate("flex")
Flex.Is3D = true

function Flex:Initialize()
	self.values = {}
end

function Flex:GetFlexNames()
	return self.rig and self.rig:GetFlexNames() or {}
end

function Flex:GetFlexRange(name)
	return self.rig:GetFlexRange(name)
end

function Flex:GetFlexByName(name)
	return self.values[name] or 0
end

function Flex:SetFlexByName(name, value)
	local old = self.values[name]
	self.values[name] = value ~= 0 and value or nil

	if self.rig then self.rig:SetFlex(name, value) end

	if self.property_change_listeners then
		objects.NotifyPropertyListeners(self, {var_name = "flex " .. name}, old or 0, value)
	end
end

function Flex:ClearFlexes()
	for name in pairs(self.values) do
		self:SetFlexByName(name, 0)
	end
end

function Flex:GetDynamicProperties()
	local out = {}

	for _, name in ipairs(self:GetFlexNames()) do
		local min, max = self:GetFlexRange(name)
		out[#out + 1] = {
			var_name = "flex " .. name,
			type = "number",
			default = 0,
			min = min,
			max = max,
			slider = true,
			get = function(flex)
				return flex:GetFlexByName(name)
			end,
			set = function(flex, value)
				flex:SetFlexByName(name, value)
			end,
		}
	end

	return out
end

function Flex:OnSerialize()
	return {values = table.copy(self.values)}
end

function Flex:OnDeserialize(data)
	for name, value in pairs(data and data.values or {}) do
		self:SetFlexByName(name, value)
	end
end

function Flex:Update()
	local animator = self.Owner.animator
	local rig = animator and animator.rig

	if rig == self.rig then return end

	self.rig = rig

	if rig and rig.skeleton.Flex then
		for name, value in pairs(self.values) do
			rig:SetFlex(name, value)
		end
	end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

function Flex:OnFirstCreated()
	event.AddListener("Update", "flex", function()
		for _, flex in ipairs(Flex.Instances) do
			flex:Update()
		end
	end)
end

function Flex:OnLastRemoved()
	event.RemoveListener("Update", "flex")
end

return Flex:Register()
