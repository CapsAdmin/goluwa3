local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")

local function record(entity)
	local log = {}
	entity:AddLocalListener("OnHide", function()
		log[#log + 1] = "hide"
	end)
	entity:AddLocalListener("OnShow", function()
		log[#log + 1] = "show"
	end)
	return log
end

T.Test("Hiding an entity hides everything below it and the root wins over own flags", function()
	local root = Entity.New{transform = {}, visibility = {}}
	local middle = Entity.New{Parent = root, transform = {}, visual = {}}
	local leaf = Entity.New{Parent = middle, transform = {}, visual = {}, visibility = {}}
	leaf.visual:SetVisible(false)
	leaf.visibility:SetVisible(false)
	local middle_log, leaf_log = record(middle), record(leaf)
	root.visibility:SetVisible(false)
	T(middle.visibility_hidden)["=="](true)
	T(middle.visual.Visible)["=="](false)
	T(leaf.visibility:IsHidden())["=="](true)
	T(leaf.visibility:IsSelfHidden())["=="](true)
	T(middle_log[1])["=="]("hide")
	T(leaf_log[1])["=="](nil)
	middle.visual:SetVisible(true)
	T(middle.visual.Visible)["=="](false)
	root.visibility:SetVisible(true)
	T(middle.visual.Visible)["=="](true)
	T(middle_log[2])["=="]("show")
	T(leaf.visual.Visible)["=="](false)
	leaf.visibility:SetVisible(true)
	T(leaf.visibility:IsHidden())["=="](false)
	T(leaf.visual.Visible)["=="](false)
	leaf.visual:SetVisible(true)
	T(leaf.visual.Visible)["=="](true)
	root:Remove()
end)

T.Test("Entities added or moved under a hidden entity are hidden and shown again when they leave", function()
	local root = Entity.New{transform = {}, visibility = {}}
	root.visibility:SetVisible(false)
	local built = Entity.New{Parent = root, transform = {}, visual = {}}
	T(built.visual.Visible)["=="](false)
	local moved = Entity.New{transform = {}, visual = {}}
	T(moved.visual.Visible)["=="](true)
	moved:SetParent(root)
	T(moved.visual.Visible)["=="](false)
	local nested = Entity.New{Parent = moved, transform = {}}
	local nested_log = record(nested)
	moved:SetParent(Entity.World)
	T(moved.visual.Visible)["=="](true)
	T(nested.visibility_hidden)["=="](false)
	T(nested_log[1])["=="]("show")
	root:Remove()
	moved:Remove()
end)

T.Test("Hiders are named reasons that stack and each is removed on its own", function()
	local root = Entity.New{transform = {}, visibility = {}}
	local child = Entity.New{Parent = root, transform = {}, visibility = {}}
	local log = record(child)
	root.visibility:AddHider("first_person")
	root.visibility:AddHider("editor")
	root.visibility:AddHider("editor")
	T(child.visibility:IsHidden())["=="](true)
	root.visibility:RemoveHider("first_person")
	T(child.visibility:IsHidden())["=="](true)
	T(root.visibility:HasHider("editor"))["=="](true)
	T(child.visibility:GetReasonsHidden()[root])["=="]("editor")
	root.visibility:RemoveHider("editor")
	T(child.visibility:IsHidden())["=="](false)
	T(#log)["=="](2)
	root:Remove()
end)

T.Test("A script gets OnHide and OnShow", function()
	local entity = Entity.New{
		transform = {},
		visibility = {},
		script = {Source = "local objects = import('goluwa/objects/objects.lua') local META = objects.CreateTemplate('test_visibility_script') function META:OnHide() self.seen = (self.seen or 0) + 1 end function META:OnShow() self.seen = (self.seen or 0) + 10 end return META:Register()"},
	}
	entity.visibility:SetVisible(false)
	T(entity.test_visibility_script.seen)["=="](1)
	entity.visibility:SetVisible(true)
	T(entity.test_visibility_script.seen)["=="](11)
	entity:Remove()
end)

T.Test("Lights and water volumes leave the scene while their entity is hidden and keep their own Visible", function()
	local Light = import("goluwa/entities/components/light.lua")
	local root = Entity.New{transform = {}, visibility = {}}
	local lamp = Entity.New{Parent = root, transform = {}, light_point = {Lumen = 100}}
	local light = lamp.light_point
	local function listed()
		for _, other in ipairs(Light.GetInstances()) do
			if other == light then return true end
		end

		return false
	end
	T(listed())["=="](true)
	root.visibility:SetVisible(false)
	T(listed())["=="](false)
	T(light.Visible)["=="](true)
	light:SetVisible(false)
	root.visibility:SetVisible(true)
	T(listed())["=="](false)
	light:SetVisible(true)
	T(listed())["=="](true)
	root.visibility:SetVisible(false)
	local late = Entity.New{Parent = root, transform = {}, light_point = {Lumen = 100}}
	T(late.light_point.registered)["=="](false)
	root:Remove()
end)
