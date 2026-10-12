local T = import("test/environment.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local clients = import("goluwa/network/clients.lua")

T.Test2D("Entity tree groups the children of a root by owner", function()
	local other = clients.Create("tree_owner_other")
	other:SetNick("zed")
	local root = Entity.New{Name = "tree_owner_root"}
	local mine = Entity.New{Name = "mine", Parent = root}
	local theirs = Entity.New{Name = "theirs", Parent = root}
	local loose = Entity.New{Name = "loose", Parent = root}
	local nested = Entity.New{Name = "nested", Parent = theirs}
	mine:SetOwnedBy(clients.GetLocalClient())
	theirs:SetOwnedBy(other)
	local tree = EntityTree{RootEntities = {root}, GroupByOwner = true}
	tree:Refresh(true)
	local groups = tree:GetItems()[1].Children
	T(#groups)["=="](3)
	T(groups[1].Text)["=="]("you")
	T(groups[2].Text)["=="]("zed")
	T(groups[3].Text)["=="]("none")
	T(groups[1].Children[1].Entity)["=="](mine)
	T(groups[2].Children[1].Entity)["=="](theirs)
	T(groups[3].Children[1].Entity)["=="](loose)
	nested:SetOwnedBy(clients.GetLocalClient())
	tree:ExpandToEntity(nested)
	T(tree:GetItems()[1].Children[2].Children[1].Entity)["=="](theirs)
	loose:SetOwnedBy(other)
	tree:Refresh(true)
	T(#tree:GetItems()[1].Children)["=="](2)
	tree:Remove()
	root:Remove()
end)

T.Test2D("Entity tree without grouping lists children directly", function()
	local root = Entity.New{Name = "tree_plain_root"}
	local child = Entity.New{Name = "child", Parent = root}
	local tree = EntityTree{RootEntities = {root}}
	tree:Refresh(true)
	T(tree:GetItems()[1].Children[1].Entity)["=="](child)
	tree:Remove()
	root:Remove()
end)

T.Test3D("Entity tree lists the material of a shape under it", function()
	local shapes = import("goluwa/render3d/shapes.lua")
	local root = Entity.New{Name = "tree_material_root"}
	local sphere = shapes.Sphere{Name = "ball", Parent = root, Material = {Color = Color(1, 0, 0, 1)}, RigidBody = false}
	local tree = EntityTree{RootEntities = {root}, ShowVirtualChildren = true}
	tree:ExpandToEntity(sphere)
	tree:Refresh(true)
	local node = tree:GetItems()[1].Children[1]
	T(node.Entity)["=="](sphere)
	T(node.Children[1].Text)["=="]("Material")
	T(node.Children[1].Object)["=="](sphere.model.material)
	tree:Remove()
	root:Remove()
end)
