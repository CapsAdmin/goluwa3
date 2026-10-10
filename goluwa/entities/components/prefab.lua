local objects = import("goluwa/objects/objects.lua")
local prefab = import("goluwa/entities/prefab.lua")
local META = objects.CreateTemplate("prefab")
META.Network = {
	Inputs = {"table", 0.5, "reliable"},
	Path = {"string", 0.5, "reliable"},
}
META:StartStorable()
-- inputs are declared before the path so an instance that is constructed or loaded builds once, with its inputs
META:GetSet("Inputs", nil, {callback = "OnInputsChanged", Hidden = true})
META:GetSet("Path", "", {callback = "Rebuild", asset = "prefabs"})
META:EndStorable()

function META:OnCreate()
	self.nodes = {}
	self.owned = {}
	self.applied = {}
end

function META:Initialize()
	self.initialized = true
	self:Rebuild()
end

function META:Rebuild()
	if not self.initialized then return end

	prefab.Release(self)

	if self.Path ~= "" then prefab.Build(self) end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

function META:OnInputsChanged(_, old, new)
	if self.definition then prefab.ApplyInputs(self, old, new) end
end

function META:OnRemove()
	prefab.Release(self)
end

function META:GetInput(name)
	return prefab.GetInput(self, name)
end

function META:SetInput(name, value)
	assert(self.definition, "prefab instance is not built")
	local inputs = {}

	for key, current in pairs(self.Inputs or {}) do
		inputs[key] = current
	end

	inputs[name] = value
	self:SetInputs(inputs)
end

function META:GetNode(id)
	return self.nodes[id]
end

do
	local function use_current(component, input)
		prefab.SetInputDefault(component.Path, input.Name, component:GetInput(input.Name))
	end

	local function remove(component, input)
		prefab.RemoveInput(component.Path, input.Name)
	end

	local function input_property(input)
		return {
			var_name = input.Name,
			type = input.Type,
			default = input.Default,
			min = input.Min,
			max = input.Max,
			category = "Inputs",
			get = function(component)
				return component:GetInput(input.Name)
			end,
			set = function(component, value)
				component:SetInput(input.Name, value)
			end,
			context_actions = {
				{
					Text = "Use current value as default",
					action = function(component)
						use_current(component, input)
					end,
				},
				{
					Text = "Remove input",
					action = function(component)
						remove(component, input)
					end,
				},
			},
		}
	end

	function META:GetDynamicProperties()
		local properties = {}

		if not self.definition then return properties end

		for _, input in ipairs(self.definition.inputs) do
			if not input.Hidden then properties[#properties + 1] = input_property(input) end
		end

		return properties
	end
end

return META:Register()
