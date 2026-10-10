local objects = import("goluwa/objects/objects.lua")
local Visibility = objects.CreateTemplate("visibility")
Visibility:StartStorable()
Visibility:GetSet("Visible", true)
Visibility:EndStorable()

-- an entity is hidden when it hides itself (Visible off, or any hider added by name) or any entity above it does, like a part in pac3:
-- hiding a root hides what is below it, and what is below keeps its own state for when the root shows again.
-- Entities without this component only inherit, entity.visibility_hidden is the state of every entity, kept up to date as
-- the hierarchy and the components change, and OnHide / OnShow are local events of the entity when it changes
-- (components and scripts receive them, a visual follows them).
local function propagate(entity, parent_hidden)
	local component = entity.visibility
	local hidden = parent_hidden or (component ~= nil and component:IsSelfHidden())

	if (entity.visibility_hidden or false) == hidden then return end

	entity.visibility_hidden = hidden
	entity:CallLocalEvent(hidden and "OnHide" or "OnShow")

	for _, child in ipairs(entity.Children) do
		propagate(child, hidden)
	end
end

-- called when an entity is built or moved in the hierarchy, and by the component when its own state changes
function Visibility.Refresh(entity)
	local parent = entity:GetParent()
	propagate(entity, parent:IsValid() and parent.visibility_hidden or false)
end

function Visibility:Initialize()
	self.hiders = {}
	self.hider_count = 0
	Visibility.Refresh(self.Owner)
end

function Visibility:SetVisible(visible)
	self.Visible = visible
	Visibility.Refresh(self.Owner)
end

function Visibility:IsSelfHidden()
	return not self.Visible or self.hider_count > 0
end

-- hidden by itself or by anything above it
function Visibility:IsHidden()
	return self.Owner.visibility_hidden == true
end

-- a named reason to hide, several can be active at once (first person, an editor, a script) and each is removed on its own
function Visibility:AddHider(key)
	if self.hiders[key] then return end

	self.hiders[key] = true
	self.hider_count = self.hider_count + 1
	Visibility.Refresh(self.Owner)
end

function Visibility:RemoveHider(key)
	if not self.hiders[key] then return end

	self.hiders[key] = nil
	self.hider_count = self.hider_count - 1
	Visibility.Refresh(self.Owner)
end

function Visibility:HasHider(key)
	return self.hiders[key] == true
end

-- entity -> why it hides, for this entity and the ones above it
function Visibility:GetReasonsHidden()
	local reasons = {}

	for _, entity in ipairs{self.Owner, unpack(self.Owner:GetParentList())} do
		local component = entity.visibility

		if component and component:IsSelfHidden() then
			local list = {}

			if not component.Visible then list[1] = "invisible" end

			for key in pairs(component.hiders) do
				list[#list + 1] = key
			end

			table.sort(list)
			reasons[entity] = table.concat(list, ", ")
		end
	end

	return reasons
end

function Visibility:OnRemove()
	if self:IsSelfHidden() then
		self.Visible = true
		self.hiders = {}
		self.hider_count = 0
		Visibility.Refresh(self.Owner)
	end
end

return Visibility:Register()
