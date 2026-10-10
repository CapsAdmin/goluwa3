local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local scene = import("goluwa/entities/scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local vfs = import("goluwa/vfs.lua")
local assets = import("goluwa/assets.lua")

local function register(name)
	return prefab.Register(
		name,
		{
			inputs = {
				{
					Name = "Group",
					Type = "string",
					Default = "a",
					Targets = {
						{Node = "root", Component = "spawn_point", Property = "Group"},
						{Node = "child", Component = "spawn_point", Property = "Group"},
					},
				},
			},
			entities = {
				{guid = "root", components = {spawn_point = {}}},
				{
					guid = "child",
					parent = "root",
					properties = {Name = "child"},
					components = {
						transform = {Position = Vec3(0, 1, 0)},
						spawn_point = {Enabled = false},
					},
				},
			},
		}
	)
end

local function instance(name, inputs)
	return Entity.New{prefab = {Path = name, Inputs = inputs}}
end

T.Test("Prefab instance builds its nodes and applies the input defaults", function()
	register("test_prefab_basic")
	local root = instance("test_prefab_basic")
	T(root.transform ~= nil)["=="](true)
	T(root.spawn_point:GetGroup())["=="]("a")
	local child = root.prefab:GetNode("child")
	T(child:GetParent())["=="](root)
	T(child:GetName())["=="]("child")
	T(child.transform:GetPosition())["=="](Vec3(0, 1, 0))
	T(child.spawn_point:GetGroup())["=="]("a")
	T(child.spawn_point:GetEnabled())["=="](false)
	root:Remove()
end)

T.Test("Prefab inputs push into the nodes they target and stay per instance", function()
	register("test_prefab_inputs")
	local a = instance("test_prefab_inputs", {Group = "x"})
	local b = instance("test_prefab_inputs")
	T(a.spawn_point:GetGroup())["=="]("x")
	T(a.prefab:GetNode("child").spawn_point:GetGroup())["=="]("x")
	T(b.spawn_point:GetGroup())["=="]("a")
	b.prefab:SetInput("Group", "y")
	T(b.spawn_point:GetGroup())["=="]("y")
	T(b.prefab:GetNode("child").spawn_point:GetGroup())["=="]("y")
	T(b.prefab:GetInput("Group"))["=="]("y")
	T(a.spawn_point:GetGroup())["=="]("x")
	b.prefab:SetInput("Group", nil)
	T(b.prefab:GetInput("Group"))["=="]("a")
	T(b.spawn_point:GetGroup())["=="]("a")
	a:Remove()
	b:Remove()
end)

T.Test("Prefab ownership tells instance state from definition state", function()
	register("test_prefab_owner")
	local root = instance("test_prefab_owner")
	local child = root.prefab:GetNode("child")
	T(prefab.GetOwner(child))["=="](root.prefab)
	T(prefab.GetOwner(child.spawn_point))["=="](root.prefab)
	T(prefab.GetOwner(root.spawn_point))["=="](root.prefab)
	T(prefab.GetOwner(root.transform))["=="](nil)
	T(prefab.GetOwner(root))["=="](nil)
	root:Remove()
end)

T.Test("Prefab edits made through one instance reach the others", function()
	local definition = register("test_prefab_edit")
	local a = instance("test_prefab_edit")
	local b = instance("test_prefab_edit")
	local child_a = a.prefab:GetNode("child")
	child_a.spawn_point:SetEnabled(true)
	child_a.transform:SetPosition(Vec3(0, 5, 0))
	a.prefab:SetInput("Group", "x")
	prefab.MarkDirty(child_a.spawn_point, "Enabled")
	prefab.MarkDirty(child_a.transform, "Position")
	prefab.Flush()
	local child_b = b.prefab:GetNode("child")
	T(child_b.spawn_point:GetEnabled())["=="](true)
	T(child_b.transform:GetPosition())["=="](Vec3(0, 5, 0))
	T(child_b.spawn_point:GetGroup())["=="]("a")
	T(a.spawn_point:GetGroup())["=="]("x")
	T(definition.entities[2].components.spawn_point.Group)["=="](nil)
	T(definition.entities[2].components.spawn_point.Enabled)["=="](nil)
	T(prefab.Commit(a.prefab))["=="](false)
	a:Remove()
	b:Remove()
end)

T.Test("Prefab editing a linked property changes the input of that instance", function()
	local definition = register("test_prefab_linked_edit")
	local a = instance("test_prefab_linked_edit")
	local b = instance("test_prefab_linked_edit")
	local child_a = a.prefab:GetNode("child")
	child_a.spawn_point:SetGroup("z")
	prefab.MarkDirty(child_a.spawn_point, "Group")
	prefab.Flush()
	T(a.prefab:GetInput("Group"))["=="]("z")
	T(a.spawn_point:GetGroup())["=="]("z")
	T(b.spawn_point:GetGroup())["=="]("a")
	T(definition.entities[2].components.spawn_point.Group)["=="](nil)
	a:Remove()
	b:Remove()
end)

T.Test("Prefab writes what was edited and not what code changed", function()
	local definition = register("test_prefab_volatile")
	local a = instance("test_prefab_volatile")
	local child = a.prefab:GetNode("child")
	child.transform:SetPosition(Vec3(7, 7, 7))
	child.spawn_point:SetEnabled(true)
	prefab.MarkDirty(child.spawn_point, "Enabled")
	prefab.Flush()
	T(definition.entities[2].components.spawn_point.Enabled)["=="](nil)
	T(definition.entities[2].components.transform.Position)["=="](Vec3(0, 1, 0))
	local extra = Entity.New{Name = "extra", Parent = a}
	extra:AddComponent("transform")
	prefab.Commit(a.prefab)
	T(#prefab.Get("test_prefab_volatile").entities)["=="](3)
	T(prefab.Get("test_prefab_volatile").entities[2].components.transform.Position)["=="](Vec3(0, 1, 0))
	prefab.Suppress()
	child.spawn_point:SetEnabled(false)
	prefab.MarkDirty(child.spawn_point, "Enabled")
	prefab.Unsuppress()
	prefab.Flush()
	T(prefab.Get("test_prefab_volatile").entities[2].components.spawn_point.Enabled)["=="](nil)
	a:Remove()
end)

T.Test("Prefab structure changes reach the others", function()
	register("test_prefab_structure")
	local a = instance("test_prefab_structure")
	local b = instance("test_prefab_structure")
	local extra = Entity.New{Name = "extra", Parent = a}
	extra:AddComponent("transform")
	prefab.Commit(a.prefab)
	T(#b:GetChildren())["=="](2)
	T(extra.prefab_owner)["=="](a.prefab)
	extra:Remove()
	prefab.Commit(a.prefab)
	T(#b:GetChildren())["=="](1)
	a.prefab:GetNode("child"):RemoveComponent("spawn_point")
	prefab.Commit(a.prefab)
	T(b.prefab:GetNode("child").spawn_point)["=="](nil)
	T(#prefab.Get("test_prefab_structure").inputs[1].Targets)["=="](1)
	a:Remove()
	b:Remove()
end)

T.Test("Prefab instances are saved as a path and inputs", function()
	register("test_prefab_scene")
	local root = instance("test_prefab_scene", {Group = "x"})
	root:SetTransient(false)
	root.transform:SetPosition(Vec3(1, 2, 3))
	local data = scene.SerializeEntities({root})
	T(#data.entities)["=="](1)
	local components = data.entities[1].components
	T(components.prefab.Path)["=="]("test_prefab_scene")
	T(components.prefab.Inputs.Group)["=="]("x")
	T(components.spawn_point)["=="](nil)
	T(components.transform.Position)["=="](Vec3(1, 2, 3))
	local text = scene.Encode(data)
	root:Remove()
	local holder = Entity.New{Name = "holder", Parent = Entity.World}
	local loaded = scene.Deserialize(scene.Decode(text), holder)[1]
	T(loaded.transform:GetPosition())["=="](Vec3(1, 2, 3))
	T(loaded.spawn_point:GetGroup())["=="]("x")
	T(loaded.prefab:GetNode("child").spawn_point:GetGroup())["=="]("x")
	T(#loaded:GetChildren())["=="](1)
	holder:Remove()
end)

T.Test("Prefab files keep inputs and records", function()
	local name = "test_prefab_file"
	register(name)
	prefab.Save(name)
	prefab.definitions[name] = nil
	local loaded = prefab.Get(name)
	T(#loaded.entities)["=="](2)
	T(loaded.entities[2].components.transform.Position)["=="](Vec3(0, 1, 0))
	T(loaded.inputs[1].Name)["=="]("Group")
	T(loaded.inputs[1].Targets[2].Node)["=="]("child")
	T(loaded.saved)["=="](true)
	local root = instance(name)
	T(root.prefab:GetNode("child").spawn_point:GetGroup())["=="]("a")
	root:Remove()
	prefab.definitions[name] = nil
	vfs.Delete(prefab.GetPath(name))
end)

T.Test("Prefab nested instances keep their own nodes", function()
	register("test_prefab_inner")
	prefab.Register(
		"test_prefab_outer",
		{
			entities = {
				{guid = "root", components = {}},
				{
					guid = "part",
					parent = "root",
					components = {
						transform = {Position = Vec3(1, 0, 0)},
						prefab = {Path = "test_prefab_inner", Inputs = {Group = "n"}},
					},
				},
			},
		}
	)
	local outer = instance("test_prefab_outer")
	local part = outer.prefab:GetNode("part")
	T(part.spawn_point:GetGroup())["=="]("n")
	T(part.prefab:GetNode("child"):GetParent())["=="](part)
	T(prefab.GetOwner(part.spawn_point))["=="](part.prefab)
	T(prefab.GetOwner(part.transform))["=="](outer.prefab)
	T(prefab.GetDependencies("test_prefab_outer").test_prefab_inner)["=="](true)
	T(prefab.Commit(outer.prefab))["=="](false)
	T(#prefab.Get("test_prefab_outer").entities)["=="](2)
	outer:Remove()
end)

T.Test("Prefab unpack turns the nodes into plain entities", function()
	register("test_prefab_unpack")
	local root = instance("test_prefab_unpack")
	root:SetTransient(false)
	local child = root.prefab:GetNode("child")
	prefab.Unpack(root)
	T(root.prefab)["=="](nil)
	T(child:IsValid())["=="](true)
	T(child.prefab_owner)["=="](nil)
	T(#scene.SerializeEntities({root}).entities)["=="](2)
	root:Remove()
end)

T.Test("Prefab removing the root removes the nodes", function()
	local definition = register("test_prefab_remove")
	local root = instance("test_prefab_remove")
	local child = root.prefab:GetNode("child")
	root:Remove()
	T(child:IsValid())["=="](false)
	T(next(definition.instances))["=="](nil)
end)

T.Test("Prefab made from an entity becomes an instance of it", function()
	local name = "test_prefab_made"
	local root = Entity.New{Name = "crate"}
	root:AddComponent("transform"):SetPosition(Vec3(1, 2, 3))
	root:AddComponent("spawn_point"):SetGroup("g")
	local lid = Entity.New{Name = "lid", Parent = root}
	lid:AddComponent("transform"):SetPosition(Vec3(0, 1, 0))
	prefab.CreateFromEntity(root, name)
	T(root.prefab ~= nil)["=="](true)
	T(root.transform:GetPosition())["=="](Vec3(1, 2, 3))
	T(root.spawn_point:GetGroup())["=="]("g")
	T(lid:IsValid())["=="](false)
	T(#root:GetChildren())["=="](1)
	T(root:GetChildren()[1]:GetName())["=="]("lid")
	T(root:GetChildren()[1].transform:GetPosition())["=="](Vec3(0, 1, 0))
	root:Remove()
	prefab.definitions[name] = nil
	vfs.Delete(prefab.GetPath(name))
end)

T.Test("Prefab definitions are validated before they are used", function()
	local ok, err = pcall(
		prefab.Register,
		"test_prefab_invalid",
		{
			entities = {{guid = "root", components = {}}},
			inputs = {
				{
					Name = "X",
					Type = "number",
					Targets = {{Node = "nowhere", Component = "entity", Property = "Name"}},
				},
			},
		}
	)
	T(ok)["=="](false)
	T(tostring(err):find("missing node", 1, true) ~= nil)["=="](true)
	T(prefab.definitions.test_prefab_invalid)["=="](nil)
end)

T.Test("Prefab entities find their instance and its nodes", function()
	register("test_prefab_helpers")
	local root = instance("test_prefab_helpers")
	local child = root.prefab:GetNode("child")
	T(child:GetPrefab())["=="](root)
	T(root:GetPrefab())["=="](root)
	T(child:GetNode("child"))["=="](child)
	local plain = Entity.New{Name = "plain"}
	T(plain:GetPrefab())["=="](nil)
	plain:Remove()
	root:Remove()
end)

T.Test("Prefab nodes moved out of an instance leave its definition", function()
	register("test_prefab_move")
	local a = instance("test_prefab_move")
	local b = instance("test_prefab_move")
	local child = a.prefab:GetNode("child")
	local holder = Entity.New{Name = "holder"}
	child:SetParent(holder)
	prefab.Commit(a.prefab)
	T(child.prefab_owner)["=="](nil)
	T(child.prefab_node)["=="](nil)
	T(b.prefab:GetNode("child"))["=="](nil)
	T(#prefab.Get("test_prefab_move").entities)["=="](1)
	holder:Remove()
	a:Remove()
	b:Remove()
end)

T.Test("Prefab inputs can get a new default and be removed", function()
	local name = "test_prefab_input_edit"
	register(name)
	local a = instance(name, {Group = "x"})
	local b = instance(name)
	prefab.SetInputDefault(name, "Group", "z")
	T(b.spawn_point:GetGroup())["=="]("z")
	T(a.spawn_point:GetGroup())["=="]("x")
	prefab.RemoveInput(name, "Group")
	T(#prefab.Get(name).inputs)["=="](0)
	T(a.spawn_point:GetGroup())["=="]("")
	T(a.prefab.Inputs.Group)["=="](nil)
	T(b.prefab:GetNode("child").spawn_point:GetGroup())["=="]("")
	a:Remove()
	b:Remove()
end)

T.Test("Prefabs are assets, registered ones are virtual until they are saved", function()
	local name = "test_prefab_asset"
	register(name)
	local category = assets.categories.prefabs
	local key = category.get_path(name):lower()
	local entry = assets.GetIndex("prefabs").by_path[key]
	T(entry ~= nil)["=="](true)
	T(entry.source)["=="]("virtual")
	T(category.get_value(entry))["=="](name)
	T(assets.GetIndex("prefabs").by_path["prefabs/box.prefab"] ~= nil)["=="](true)
	T(list.has_value(prefab.GetNames(), name))["=="](true)
	prefab.Save(name)
	entry = assets.GetIndex("prefabs").by_path[key]
	T(entry ~= nil)["=="](true)
	T(entry.source ~= "virtual")["=="](true)
	prefab.definitions[name] = nil
	vfs.Delete(prefab.GetPath(name))
	assets.InvalidateIndex("prefabs")
end)

T.Test("Prefab describes itself and previews only what is drawn", function()
	local name = "test_prefab_describe"
	register(name)
	local info = prefab.Describe(name)
	T(info.nodes)["=="](2)
	T(table.concat(info.components, ","))["=="]("spawn_point,transform")
	T(#info.inputs)["=="](1)
	T(info.scripts)["=="](0)
	T(info.builtin)["=="](false)
	local preview = prefab.CreatePreview(name)
	T(preview:GetTransient())["=="](true)
	T(preview.spawn_point)["=="](nil)
	local child = preview.prefab:GetNode("child")
	T(child.transform ~= nil)["=="](true)
	T(child.spawn_point)["=="](nil)
	preview:Remove()
end)

T.Test("Prefab inputs without targets can gain and lose them", function()
	local name = "test_prefab_targets"
	register(name)
	prefab.AddInput(name, {Name = "Switch", Type = "boolean", Default = true, Targets = {}})
	prefab.AddTarget(name, "Switch", {Node = "child", Component = "spawn_point", Property = "Enabled"})
	T(prefab.IsExposed(name, "child", "spawn_point", "Enabled"))["=="](true)
	T(prefab.FindInput(name, "child", "spawn_point", "Enabled").Name)["=="]("Switch")
	T(prefab.FindInput(name, "child", "spawn_point", "Group").Name)["=="]("Group")
	T(prefab.FindInput(name, "root", "spawn_point", "Enabled"))["=="](nil)
	local a = instance(name)
	local child = a.prefab:GetNode("child")
	T(child.spawn_point:GetEnabled())["=="](true)
	a.prefab:SetInput("Switch", false)
	T(child.spawn_point:GetEnabled())["=="](false)
	a.prefab:SetInput("Switch", true)
	prefab.Unlink(name, "child", "spawn_point", "Enabled")
	T(#prefab.Get(name).inputs)["=="](1)
	T(prefab.IsExposed(name, "child", "spawn_point", "Enabled"))["=="](false)
	T(child.spawn_point:GetEnabled())["=="](false)
	T(a.prefab.Inputs.Switch)["=="](nil)
	local ok = pcall(prefab.AddTarget, name, "Group", {Node = "nowhere", Component = "entity", Property = "Name"})
	T(ok)["=="](false)
	T(#prefab.Get(name).inputs[1].Targets)["=="](2)
	a:Remove()
end)

T.Test("Prefab inputs and the properties they push into never share a value object", function()
	local name = "test_prefab_alias"
	prefab.Register(
		name,
		{
			inputs = {
				{
					Name = "Where",
					Type = "vec3",
					Default = Vec3(1, 2, 3),
					Targets = {{Node = "child", Component = "transform", Property = "Position"}},
				},
			},
			entities = {
				{guid = "root", components = {}},
				{guid = "child", parent = "root", components = {transform = {}}},
			},
		}
	)
	local definition = prefab.Get(name)
	local a = instance(name)
	local b = instance(name)
	local position = a.prefab:GetNode("child").transform:GetPosition()
	position.x = 9
	T(definition.inputs[1].Default.x)["=="](1)
	T(b.prefab:GetNode("child").transform:GetPosition().x)["=="](1)
	local edited = Vec3(4, 5, 6)
	local child = a.prefab:GetNode("child")
	child.transform:SetPosition(edited)
	prefab.MarkDirty(child.transform, "Position")
	prefab.Flush()
	T(a.prefab.Inputs.Where)["=="](Vec3(4, 5, 6))
	edited.x = 100
	T(a.prefab.Inputs.Where.x)["=="](4)
	child.transform:GetPosition().y = 50
	T(a.prefab.Inputs.Where.y)["=="](5)
	T(definition.inputs[1].Default)["=="](Vec3(1, 2, 3))
	T(b.prefab:GetNode("child").transform:GetPosition())["=="](Vec3(1, 2, 3))
	a:Remove()
	b:Remove()
end)

T.Test("Prefab syncing does not set properties that already have their value", function()
	register("test_prefab_inner")
	prefab.Register(
		"test_prefab_sync_outer",
		{
			entities = {
				{guid = "root", components = {}},
				{
					guid = "part",
					parent = "root",
					components = {
						transform = {},
						prefab = {Path = "test_prefab_inner", Inputs = {Group = "n"}},
					},
				},
			},
		}
	)
	local a = instance("test_prefab_sync_outer")
	local b = instance("test_prefab_sync_outer")
	local part_a = a.prefab:GetNode("part")
	local part_b = b.prefab:GetNode("part")
	local notified = 0
	part_b.prefab:AddPropertyListener(function()
		notified = notified + 1
	end, "test")
	part_a.transform:SetPosition(Vec3(1, 2, 3))
	prefab.MarkDirty(part_a.transform, "Position")
	prefab.Flush()
	T(part_b.transform:GetPosition())["=="](Vec3(1, 2, 3))
	T(notified)["=="](0)
	a:Remove()
	b:Remove()
end)
