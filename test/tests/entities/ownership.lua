local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local clients = import("goluwa/network/clients.lua")
local event = import("goluwa/event.lua")

T.Test("Entities belong to their world unless an owner is set", function()
	local entity = Entity.New{}
	T(entity:GetOwnedBy())["=="](Entity.World)
	T(Entity.World:GetOwnedBy())["=="](Entity.World)
	T(Entity.World.GetOwnerLabel(Entity.World))["=="]("none")
	entity:Remove()
end)

T.Test("Children inherit the owner of their parent and can override it", function()
	local client = clients.Create("ownership_test_1")
	local other = clients.Create("ownership_test_2")
	local parent = Entity.New{}
	local child = Entity.New{Parent = parent}
	local grandchild = Entity.New{Parent = child}
	parent:SetOwnedBy(client)
	T(child:GetOwnedBy())["=="](client)
	T(grandchild:GetOwnedBy())["=="](client)
	child:SetOwnedBy(other)
	T(grandchild:GetOwnedBy())["=="](other)
	T(parent:GetOwnedBy())["=="](client)
	T(Entity.World.GetOwnerKey(other))["=="]("ownership_test_2")
	child:SetOwnedBy(nil)
	T(child:GetOwnedBy())["=="](client)
	parent:Remove()
end)

T.Test("Changing the owner tells the world", function()
	local entity = Entity.New{}
	local actions = {}
	local remove = Entity.World:AddLocalListener("OnEntityHierarchyChanged", function(_, changed, action)
		if changed == entity then actions[#actions + 1] = action end
	end)
	entity:SetOwnedBy(clients.Create("ownership_test_3"))
	T(actions[#actions])["=="]("owned")
	remove()
	entity:Remove()
end)
