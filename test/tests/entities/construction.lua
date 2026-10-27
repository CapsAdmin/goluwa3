local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local added, removed = 0, 0
local Tracker = objects.CreateTemplate("construction_a_tracker")

function Tracker:OnAdd()
	added = added + 1
end

function Tracker:OnRemove()
	removed = removed + 1
end

Entity.RegisterComponent("construction_a_tracker", Tracker:Register())
local Failing = objects.CreateTemplate("construction_z_failing")

function Failing:Initialize()
	error("construction test failure", 0)
end

Entity.RegisterComponent("construction_z_failing", Failing:Register())

T.Test("an entity whose construction fails removes the components it already added", function()
	attest.fails(
		function()
			Entity.New{
				ComponentSet = {"transform", "construction_a_tracker", "construction_z_failing"},
			}
		end,
		"construction test failure"
	)

	T(added)["=="](1)
	T(removed)["=="](1)
end)
