local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local use = import("goluwa/entities/use.lua")

T.Test("Script runs its module, events and removal", function()
	_G.script_test = {}
	local entity = Entity.New{
		Name = "scripted",
		script = {
			Source = [[
				function Entity:OnCreate() script_test.created = self end
				function Entity:OnUse(user, hit) script_test.used = user return true end
				function Entity:OnRemove() script_test.removed = true end
			]],
		},
	}
	T(script_test.created)["=="](entity)
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
			Source = "function Entity:OnCreate() script_test.count = script_test.count + 1 end function Entity:OnRemove() script_test.count = script_test.count + 10 end",
		},
	}
	T(script_test.count)["=="](1)
	entity.script:SetSource("function Entity:OnCreate() script_test.count = script_test.count + 100 end")
	T(script_test.count)["=="](111)
	entity.script:SetSource("this is not lua")
	T(entity.script.Error:find("script:entity:1:", 1, true) ~= nil)["=="](true)
	entity.script:SetSource("function Entity:OnUse() error('boom') end")
	T(entity.script.Error)["=="](nil)
	entity:CallLocalEvent("OnUse")
	T(entity.script.Error:find("boom", 1, true) ~= nil)["=="](true)
	entity.script:SetSource("function Entity:Update(dt) script_test.dt = dt end")
	T(entity.script.Error)["=="](nil)
	entity.script:OnUpdate(0.25)
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
							Source = [[
								function Entity:OnCreate()
									script_test.node = self:GetNode("child")
									script_test.level = self:GetPrefab().prefab:GetInput("Level")
								end
							]],
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
		script = {Source = "function Entity:OnUse() table.insert(script_test.order, 'outer') end"},
	}
	local middle = Entity.New{
		Parent = outer,
		script = {Source = "function Entity:OnUse() table.insert(script_test.order, 'middle') return true end"},
	}
	local inner = Entity.New{
		Parent = middle,
		script = {Source = "function Entity:OnUse() table.insert(script_test.order, 'inner') end"},
	}
	T(use.Fire(inner, nil, {}))["=="](middle)
	T(table.concat(script_test.order, ","))["=="]("inner,middle")
	outer:Remove()
	_G.script_test = nil
end)
