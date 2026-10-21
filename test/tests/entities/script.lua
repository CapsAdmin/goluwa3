local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local prefab = import("goluwa/entities/prefab.lua")
local scene = import("goluwa/entities/scene.lua")
local use = import("goluwa/entities/use.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")

local function component(name, body)
	return string.format(
		"local objects = import('goluwa/objects/objects.lua') local META = objects.CreateTemplate(%q) %s return META:Register()",
		name,
		body
	)
end

T.Test("Script runs its component, events and removal", function()
	_G.script_test = {}
	local entity = Entity.New{
		Name = "scripted",
		script = {
			Source = component(
				"test_script_events",
				[[
				function META:OnCreate() script_test.created = self end
				function META:OnUse(user, hit) script_test.used = user return true end
				function META:OnRemove() script_test.removed = true end
			]]
			),
		},
	}
	T(script_test.created.Owner)["=="](entity)
	T(entity.test_script_events)["=="](script_test.created)
	T(entity:CallLocalEvent("OnUse", "someone"))["=="](true)
	T(script_test.used)["=="]("someone")
	entity:Remove()
	T(script_test.removed)["=="](true)
	_G.script_test = nil
end)

T.Test("Script reload runs OnRemove then OnCreate and keeps errors with the script", function()
	_G.script_test = {count = 0}
	local entity = Entity.New{
		script = {
			Source = component(
				"test_script_reload",
				"function META:OnCreate() script_test.count = script_test.count + 1 end function META:OnRemove() script_test.count = script_test.count + 10 end"
			),
		},
	}
	T(script_test.count)["=="](1)
	entity.script:SetSource(
		component(
			"test_script_reload",
			"function META:OnCreate() script_test.count = script_test.count + 100 end"
		)
	)
	T(script_test.count)["=="](111)
	entity.script:SetSource("this is not lua")
	T(entity.script.Error:find("script:entity:1:", 1, true) ~= nil)["=="](true)
	entity.script:SetSource("return 1")
	T(entity.script.Error:find("must return", 1, true) ~= nil)["=="](true)
	entity.script:SetSource(component("test_script_reload", "function META:OnUse() error('boom') end"))
	T(entity.script.Error)["=="](nil)
	entity:CallLocalEvent("OnUse")
	T(entity.script.Error:find("boom", 1, true) ~= nil)["=="](true)
	entity.script:SetSource(
		component("test_script_reload", "function META:OnUpdate(dt) script_test.dt = dt end")
	)
	T(entity.script.Error)["=="](nil)
	entity.test_script_reload:OnUpdate(0.25)
	T(script_test.dt)["=="](0.25)
	entity:Remove()
	_G.script_test = nil
end)

T.Test("Script on a prefab root starts after every node exists", function()
	_G.script_test = {}
	prefab.Register(
		"test_script_prefab",
		{
			inputs = {{Name = "Level", Type = "number", Default = 2, Targets = {}}},
			entities = {
				{
					guid = "root",
					components = {
						script = {
							Source = component(
								"test_script_prefab_root",
								[[
								function META:Initialize()
									local entity = self.Owner
									script_test.node = entity:GetNode("child")
									script_test.level = entity:GetPrefab().prefab:GetInput("Level")
								end
							]]
							),
						},
					},
				},
				{
					guid = "child",
					parent = "root",
					components = {transform = {}, spawn_point = {}},
				},
			},
		}
	)
	local entity = Entity.New{prefab = {Path = "test_script_prefab"}}
	T(script_test.node ~= nil)["=="](true)
	T(script_test.node.spawn_point ~= nil)["=="](true)
	T(script_test.level)["=="](2)
	T(script_test.node:GetPrefab())["=="](entity)
	entity:Remove()
	_G.script_test = nil
end)

T.Test("Use fires OnUse up the parents until a handler returns true", function()
	_G.script_test = {order = {}}
	local outer = Entity.New{
		script = {
			Source = component(
				"test_script_use",
				"function META:OnUse() table.insert(script_test.order, 'outer') end"
			),
		},
	}
	local middle = Entity.New{
		Parent = outer,
		script = {
			Source = component(
				"test_script_use",
				"function META:OnUse() table.insert(script_test.order, 'middle') return true end"
			),
		},
	}
	local inner = Entity.New{
		Parent = middle,
		script = {
			Source = component(
				"test_script_use",
				"function META:OnUse() table.insert(script_test.order, 'inner') end"
			),
		},
	}
	T(use.Fire(inner, nil, {}))["=="](middle)
	T(table.concat(script_test.order, ","))["=="]("inner,middle")
	outer:Remove()
	_G.script_test = nil
end)

T.Test("A script with the source of a real component does not touch the real component", function()
	local path = "addons/game/lua/components/player_controller.lua"
	local source = assert(vfs.Read(path))
	local real = objects.GetRegistered("player_controller")
	local entity = Entity.New{transform = {}, script = {Source = source}}
	T(entity.script.Error)["=="](nil)
	local controller = entity.player_controller
	T(controller ~= nil)["=="](true)
	T(controller.Owner)["=="](entity)
	T(getmetatable(controller) ~= real)["=="](true)
	T(objects.GetRegistered("player_controller"))["=="](real)
	T(controller:GetQueueSize())["=="](0)
	controller:PushCommands{{number = 1}, {number = 2}}
	T(controller:GetQueueSize())["=="](2)
	T(controller.Source)["=="]("local")
	entity:Remove()
	T(objects.GetRegistered("player_controller"))["=="](real)
end)

T.Test("Properties of the component show up on the script and persist in Values", function()
	local source = component(
		"test_script_props",
		[[
		META:StartStorable()
		META:GetSet("Speed", 2, {min = 0, max = 10})
		META:EndStorable()
		META:GetSet("Label", "x")
		META:GetSet("Source", "own")
	]]
	)
	local entity = Entity.New{transform = {}, script = {Source = source}}
	local script = entity.script
	local rows = script:GetDynamicProperties()
	local names = {}

	for _, row in ipairs(rows) do
		names[#names + 1] = row.var_name
	end

	T(table.concat(names, ","))["=="]("Speed,Label,Source")
	T(rows[3].key ~= "Source")["=="](true)
	T(rows[1].get(script))["=="](2)
	rows[1].set(script, 7)
	T(entity.test_script_props:GetSpeed())["=="](7)
	T(script.Values.Speed)["=="](7)
	rows[2].set(script, "y")
	T(script.Values.Label)["=="](nil)
	local seen

	script:AddPropertyListener(function(_, name)
		seen = name
	end, "test")

	entity.test_script_props:SetSpeed(5)
	T(seen)["=="]("properties/Speed")
	T(script.Values.Speed)["=="](5)
	entity.test_script_props:SetSpeed(2)
	T(script.Values)["=="](nil)
	entity.test_script_props:SetSpeed(9)
	script:SetSource(source .. " ")
	T(entity.test_script_props:GetSpeed())["=="](9)
	entity:SetTransient(false)
	local data = scene.SerializeEntities({entity})
	entity:Remove()
	local roots = scene.Apply(data)
	T(roots[1].test_script_props:GetSpeed())["=="](9)
	roots[1]:Remove()
end)

T.Test("Scripts with the same source share one class until the last is gone", function()
	local source = component("test_script_shared", "function META:Hello() return 1 end")
	local a = Entity.New{script = {Source = source}}
	local b = Entity.New{script = {Source = source}}
	T(getmetatable(a.test_script_shared))["=="](getmetatable(b.test_script_shared))
	a:Remove()
	T(b.test_script_shared:Hello())["=="](1)
	local key = b.script.class.meta.RegistryKey
	T(objects.registered[key] ~= nil)["=="](true)
	b:Remove()
	T(objects.registered[key])["=="](nil)
end)

T.Test("Prefab inputs link to properties of a script component", function()
	local definition = prefab.Register(
		"test_script_linked",
		{
			inputs = {
				{
					Name = "Speed",
					Type = "number",
					Default = 3,
					Targets = {{Node = "child", Component = "script", Property = "Values", Key = "Speed"}},
				},
			},
			entities = {
				{guid = "root", components = {}},
				{
					guid = "child",
					parent = "root",
					components = {
						transform = {},
						script = {
							Source = component(
								"test_script_linked_component",
								[[
								META:StartStorable()
								META:GetSet("Speed", 1)
								META:GetSet("Other", 5)
								META:EndStorable()
							]]
							),
						},
					},
				},
			},
		}
	)
	local a = Entity.New{prefab = {Path = "test_script_linked"}}
	local b = Entity.New{prefab = {Path = "test_script_linked"}}

	local function get(entity)
		return entity.prefab:GetNode("child").test_script_linked_component
	end

	T(get(a):GetSpeed())["=="](3)
	a.prefab:SetInput("Speed", 8)
	T(get(a):GetSpeed())["=="](8)
	T(get(b):GetSpeed())["=="](3)
	T(prefab.FindInput("test_script_linked", "child", "script", "Values", "Speed").Name)["=="]("Speed")
	T(prefab.FindInput("test_script_linked", "child", "script", "Values"))["=="](nil)
	local script = a.prefab:GetNode("child").script
	script:GetDynamicProperties()[1].set(script, 9)
	get(a):SetOther(6)
	prefab.MarkDirty(script, "Values")
	prefab.Flush()
	T(a.prefab:GetInput("Speed"))["=="](9)
	T(get(b):GetSpeed())["=="](3)
	T(get(b):GetOther())["=="](6)
	T(definition.entities[2].components.script.Values.Speed)["=="](nil)
	T(definition.entities[2].components.script.Values.Other)["=="](6)
	prefab.Unlink("test_script_linked", "child", "script", "Values", "Speed")
	T(prefab.FindInput("test_script_linked", "child", "script", "Values", "Speed"))["=="](nil)
	a:Remove()
	b:Remove()
	prefab.definitions.test_script_linked = nil
end)

T.Test("A script has to register for Update like any component, and then the engine calls it", function()
	_G.script_test = {count = 0}
	local silent = Entity.New{
		script = {
			Source = component(
				"test_script_silent",
				"function META:OnUpdate() script_test.count = script_test.count + 1 end"
			),
		},
	}
	event.Call("Update", 0.1)
	T(script_test.count)["=="](0)
	local listening = Entity.New{
		script = {
			Source = component(
				"test_script_listening",
				[[
				function META:Initialize() self:AddGlobalEvent("Update") end
				function META:OnUpdate() script_test.count = script_test.count + 1 end
			]]
			),
		},
	}
	event.Call("Update", 0.1)
	T(script_test.count)["=="](1)
	silent:Remove()
	listening:Remove()
	_G.script_test = nil
end)
