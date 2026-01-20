local T = require("test.environment")
local lsx = require("gui.lsx")
local prototype = require("prototype")
local gui = require("gui.gui")
local Vec2 = require("structs.vec2")
local event = require("event")
-- Create a mock surface type for testing
local META = prototype.CreateTemplate("surface", "mock_element")
META.TypeBase = "base"
META:GetSet("MemoVal")
META:GetSet("Callback")
META:Register()
local Mock = lsx.RegisterElement("mock_element")

local function CreateMockRoot()
	return prototype.CreateDerivedObject("surface", "base")
end

T.Test("lsx.RegisterElement and lsx.Mount", function()
	local root = CreateMockRoot()
	local element = Mock({
		Name = "TestElement",
		Size = Vec2(100, 200),
	})
	local instance = lsx.Mount(element, root)
	T(instance:GetName())["=="]("TestElement")
	T(instance:GetSize().x)["=="](100)
	T(instance:GetSize().y)["=="](200)
	T(instance:GetParent())["=="](root)
	root:Remove()
end)

T.Test("lsx.Fragment", function()
	local root = CreateMockRoot()
	local fragment = lsx.Fragment({
		Mock({Name = "Child1"}),
		Mock({Name = "Child2"}),
	})
	local instances = lsx.Mount(fragment, root)
	T(#instances)["=="](2)
	T(instances[1]:GetName())["=="]("Child1")
	T(instances[2]:GetName())["=="]("Child2")
	T(instances[1]:GetParent())["=="](root)
	T(instances[2]:GetParent())["=="](root)
	root:Remove()
end)

T.Test("lsx.Component basic", function()
	local root = CreateMockRoot()
	local MyComponent = lsx.Component(function(props)
		return Mock({Name = props.name or "Default"})
	end)
	local instance = lsx.Mount(MyComponent({name = "Custom"}), root)
	T(instance:GetName())["=="]("Custom")
	root:Remove()
end)

T.Test("lsx.UseState", function()
	local root = CreateMockRoot()
	local setStateProxy
	local MyComponent = lsx.Component(function()
		local count, setCount = lsx.UseState(0)
		setStateProxy = setCount
		return Mock({Name = "Count:" .. count})
	end)
	local instance = lsx.Mount(MyComponent({}), root)
	T(instance:GetName())["=="]("Count:0")
	setStateProxy(1)
	-- Trigger Update event to process the re-render
	event.Call("Update")
	T(instance:GetName())["=="]("Count:1")

	setStateProxy(function(prev)
		return prev + 10
	end)

	event.Call("Update")
	T(instance:GetName())["=="]("Count:11")
	root:Remove()
end)

T.Test("lsx.UseEffect", function()
	local root = CreateMockRoot()
	local effectCount = 0
	local cleanupCount = 0
	local MyComponent = lsx.Component(function(props)
		lsx.UseEffect(
			function()
				effectCount = effectCount + 1
				return function()
					cleanupCount = cleanupCount + 1
				end
			end,
			{props.trigger}
		)

		return Mock({})
	end)
	local node = MyComponent({trigger = 1})
	local instance = lsx.Mount(node, root)
	T(effectCount)["=="](1)
	T(cleanupCount)["=="](0)
	-- Re-render with same dependency
	lsx.Build(node, root, instance)
	T(effectCount)["=="](1)
	T(cleanupCount)["=="](0)
	-- Re-render with different dependency
	node.props.trigger = 2
	lsx.Build(node, root, instance)
	lsx.RunPendingEffects()
	T(effectCount)["=="](2)
	T(cleanupCount)["=="](1)
	root:Remove()
end)

T.Test("lsx.UseMemo and lsx.UseCallback", function()
	local root = CreateMockRoot()
	local memoCalls = 0
	local MyComponent = lsx.Component(function(props)
		local memoized = lsx.UseMemo(
			function()
				memoCalls = memoCalls + 1
				return "val-" .. props.val
			end,
			{props.val}
		)
		local callback = lsx.UseCallback(function()
			return props.val
		end, {props.val})
		return Mock({MemoVal = memoized, Callback = callback})
	end)
	local node = MyComponent({val = "a"})
	local instance = lsx.Mount(node, root)
	local firstCallback = instance.Callback
	T(instance.MemoVal)["=="]("val-a")
	T(memoCalls)["=="](1)
	-- Same deps
	lsx.Build(node, root, instance)
	T(memoCalls)["=="](1)
	T(instance.Callback)["=="](firstCallback)
	-- Different deps
	node.props.val = "b"
	lsx.Build(node, root, instance)
	T(memoCalls)["=="](2)
	T(instance.MemoVal)["=="]("val-b")
	T(instance.Callback ~= firstCallback)["=="](true)
	root:Remove()
end)

T.Test("lsx.UseRef", function()
	local root = CreateMockRoot()
	local capturedRef
	local MyComponent = lsx.Component(function()
		local myRef = lsx.UseRef(nil)
		capturedRef = myRef
		return Mock({ref = myRef})
	end)
	local instance = lsx.Mount(MyComponent({}), root)
	T(capturedRef.current)["=="](instance)
	root:Remove()
end)

T.Test("lsx reconciliation - children", function()
	local root = CreateMockRoot()
	local List = lsx.Component(function(props)
		local children = {}

		for i = 1, props.count do
			children[i] = Mock({Name = "Item" .. i})
		end

		return Mock({Name = "List", unpack(children)})
	end)
	local node = List({count = 2})
	local instance = lsx.Mount(node, root)
	T(#instance:GetChildren())["=="](2)
	local firstChild = instance:GetChildren()[1]
	T(firstChild:GetName())["=="]("Item1")
	-- Update count
	node.props.count = 3
	lsx.Build(node, root, instance)
	T(#instance:GetChildren())["=="](3)
	T(instance:GetChildren()[1])["=="](firstChild) -- Should be same instance
	-- Decrease count
	node.props.count = 1
	lsx.Build(node, root, instance)
	T(#instance:GetChildren())["=="](1)
	T(instance:GetChildren()[1])["=="](firstChild)
	root:Remove()
end)
