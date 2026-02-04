local T = require("test.environment")
local Panel = require("ecs.panel")

T.Test("panel keyed children basic", function()
	local parent = Panel.New({
		Name = "Parent",
	})
	local child1 = Panel.New({
		Parent = parent,
		Key = "MyKey",
		Name = "Child 1",
	})
	T(parent:GetKeyed("MyKey"))["=="](child1)
	local child2 = Panel.New({
		Parent = parent,
		Key = "MyKey",
		Name = "Child 2",
	})
	T(parent:GetKeyed("MyKey"))["=="](child2)
	T(child1:IsValid())["=="](false)
	T(child2:IsValid())["=="](true)
end)

T.Test("panel keyed children cleanup", function()
	local parent = Panel.New({
		Name = "Parent",
	})
	local child = Panel.New({
		Parent = parent,
		Key = "MyKey",
		Name = "Child",
	})
	T(parent:GetKeyed("MyKey"))["=="](child)
	child:Remove()
	-- After removal, it should be nil because GetKeyed checks for IsValid
	T(parent:GetKeyed("MyKey"))["=="](nil)
	-- And it should also be nil in the raw table if OnChildRemove worked
	T(parent.keyed_children["MyKey"])["=="](nil)
end)

T.Test("panel removal unparents", function()
	local parent = require("ecs.panel").World
	local original_count = #parent:GetChildren()
	local child = require("ecs.panel").New({
		Name = "Temporary",
	})
	T(#parent:GetChildren())["=="](original_count + 1)
	child:Remove()
	-- It should be removed from the children list immediately or very soon
	T(#parent:GetChildren())["=="](original_count)
end)

T.Test("panel Ensure reuse", function()
	local parent = Panel.New({
		Name = "Parent",
	})
	local child1 = parent:Ensure({
		Key = "MyKey",
		Name = "Child 1",
	})
	T(parent:GetKeyed("MyKey"))["=="](child1)
	local child2 = parent:Ensure(
		{
			Key = "MyKey",
			Name = "Child 2", -- This should be ignored because child1 is reused
		}
	)
	T(parent:GetKeyed("MyKey"))["=="](child1)
	T(child2)["=="](child1)
	T(child1:GetName())["=="]("Child 1")
end)

T.Test("panel Conditional", function()
	local parent = Panel.New({
		Name = "Parent",
	})
	local props = {
		Key = "MyKey",
		Name = "Child",
	}
	local child1 = parent:Conditional(true, props)
	T(parent:GetKeyed("MyKey"))["=="](child1)
	local child2 = parent:Conditional(true, props)
	T(child2)["=="](child1)
	parent:Conditional(false, props)
	T(parent:GetKeyed("MyKey"))["=="](nil)
	T(child1:IsValid())["=="](false)
end)

T.Test("panel Ensure already created", function()
	local parent = Panel.New({Name = "Parent"})
	local child1 = Panel.New({
		Parent = parent,
		Key = "MyKey",
		Name = "Child 1",
	})
	local child2 = Panel.New(
		{
			-- No parent, so it defaults to Panel.World and doesn't kill child1
			Key = "MyKey",
			Name = "Child 2",
		}
	)
	T(parent:GetKeyed("MyKey"))["=="](child1)
	T(require("ecs.panel").World:GetKeyed("MyKey"))["=="](child2)
	local result = parent:Ensure(child2)
	T(result)["=="](child1)
	T(child2:IsValid())["=="](false)
	T(parent:GetKeyed("MyKey"))["=="](child1)
end)
