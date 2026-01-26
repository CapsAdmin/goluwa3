local T = require("test.environment")
local lsx = require("ecs.lsx_ecs")
local prototype = require("prototype")
local ecs = require("ecs.ecs")
local Vec2 = require("structs.vec2")
local Ang3 = require("structs.ang3")
local event = require("event")
local system = require("system")
local window = require("window")
-- Create a mock component type for testing
local META = prototype.CreateTemplate("mock_element")
META.ComponentName = "mock_element"
META:GetSet("MemoVal")
META:GetSet("Callback")
META.Component = META:Register()
local Mock = lsx:RegisterElement(function(parent)
	local ent = ecs.CreateEntity("mock_element", parent)
	ent:AddComponent(require("ecs.components.2d.transform"))
	ent:AddComponent(require("ecs.components.2d.rect"))
	ent:AddComponent(require("ecs.components.2d.layout"))
	ent:AddComponent(require("ecs.components.2d.mouse_input"))
	ent:AddComponent(require("ecs.components.2d.animations"))
	ent:AddComponent(META.Component)
	return ent
end)

local function CreateMockRoot()
	event.Call("Update")
	table.clear(lsx.pending_renders)
	table.clear(lsx.pending_effects)
	ecs.Clear2DWorld()
	return ecs.Get2DWorld()
end

-- Testing plain function support
T.Test("lsx plain function as component", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		return Mock({Name = props.name or "Default"})
	end

	-- Test passing function directly (0 props)
	local instance1 = lsx:Mount(MyComponent({}), root)
	T(instance1:GetName())["=="]("Default")
	-- Test passing {fn, props} table
	local instance2 = lsx:Mount({MyComponent, name = "Custom"}, root)
	T(instance2:GetName())["=="]("Custom")
	root:Remove()
end)

T.Test("lsx:RegisterElement and lsx:Mount", function()
	local root = CreateMockRoot()
	local element = Mock({
		Name = "TestElement",
		Size = Vec2(100, 200),
	})
	local instance = lsx:Mount(element, root)
	T(instance:GetName())["=="]("TestElement")
	T(instance:GetSize().x)["=="](100)
	T(instance:GetSize().y)["=="](200)
	T(instance:GetParent())["=="](root)
	root:Remove()
end)

T.Test("lsx:Fragment", function()
	local root = CreateMockRoot()
	local fragment = lsx:Fragment({
		Mock({Name = "Child1"}),
		Mock({Name = "Child2"}),
	})
	local instances = lsx:Mount(fragment, root)
	T(#instances)["=="](2)
	T(instances[1]:GetName())["=="]("Child1")
	T(instances[2]:GetName())["=="]("Child2")
	T(instances[1]:GetParent())["=="](root)
	T(instances[2]:GetParent())["=="](root)
	root:Remove()
end)

T.Test("lsx:Component basic", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		return Mock({Name = props.name or "Default"})
	end

	local instance = lsx:Mount(MyComponent({name = "Custom"}), root)
	T(instance:GetName())["=="]("Custom")
	root:Remove()
end)

T.Test("lsx:UseState", function()
	local root = CreateMockRoot()
	local setStateProxy

	local function MyComponent()
		local count, setCount = lsx:UseState(0)
		setStateProxy = setCount
		return Mock({Name = "Count:" .. count})
	end

	local instance = lsx:Mount({MyComponent}, root)
	T(instance:GetName())["=="]("Count:0")
	setStateProxy(1)
	event.Call("Update")
	T(instance:GetName())["=="]("Count:1")

	setStateProxy(function(prev)
		return prev + 10
	end)

	event.Call("Update")
	T(instance:GetName())["=="]("Count:11")
	root:Remove()
end)

T.Test("lsx:UseEffect", function()
	local root = CreateMockRoot()
	local effectCount = 0
	local cleanupCount = 0

	local function MyComponent(props)
		lsx:UseEffect(
			function()
				effectCount = effectCount + 1
				return function()
					cleanupCount = cleanupCount + 1
				end
			end,
			{props.trigger}
		)

		return Mock({})
	end

	local node = {MyComponent, trigger = 1}
	local instance = lsx:Mount(node, root)
	T(effectCount)["=="](1)
	T(cleanupCount)["=="](0)
	-- Re-render with same dependency
	lsx:Build(node, root, instance)
	T(effectCount)["=="](1)
	T(cleanupCount)["=="](0)
	-- Re-render with different dependency
	node.trigger = 2
	lsx:Build(node, root, instance)
	lsx:RunPendingEffects()
	T(effectCount)["=="](2)
	T(cleanupCount)["=="](1)
	root:Remove()
end)

T.Test("lsx:UseMemo and lsx:UseCallback", function()
	local root = CreateMockRoot()
	local memoCalls = 0

	local function MyComponent(props)
		local memoized = lsx:UseMemo(
			function()
				memoCalls = memoCalls + 1
				return "val-" .. props.val
			end,
			{props.val}
		)
		local callback = lsx:UseCallback(function()
			return props.val
		end, {props.val})
		return Mock({MemoVal = memoized, Callback = callback})
	end

	local node = {MyComponent, val = "a"}
	local instance = lsx:Mount(node, root)
	local firstCallback = instance:GetCallback()
	T(instance:GetMemoVal())["=="]("val-a")
	T(memoCalls)["=="](1)
	-- Same deps
	lsx:Build(node, root, instance)
	T(memoCalls)["=="](1)
	T(instance:GetCallback())["=="](firstCallback)
	-- Different deps
	node.val = "b"
	lsx:Build(node, root, instance)
	T(memoCalls)["=="](2)
	T(instance:GetMemoVal())["=="]("val-b")
	T(instance:GetCallback() ~= firstCallback)["=="](true)
	root:Remove()
end)

T.Test("lsx:UseRef", function()
	local root = CreateMockRoot()
	local capturedRef

	local function MyComponent()
		local myRef = lsx:UseRef(nil)
		capturedRef = myRef
		return Mock({ref = myRef})
	end

	local instance = lsx:Mount({MyComponent}, root)
	T(capturedRef.current)["=="](instance)
	root:Remove()
end)

T.Test("lsx reconciliation - children", function()
	local root = CreateMockRoot()

	local function List(props)
		local children = {}

		for i = 1, props.count do
			children[i] = Mock({Name = "Item" .. i})
		end

		return Mock({Name = "List", unpack(children)})
	end

	local node = {List, count = 2}
	local instance = lsx:Mount(node, root)
	T(#instance:GetChildren())["=="](2)
	local firstChild = instance:GetChildren()[1]
	T(firstChild:GetName())["=="]("Item1")
	-- Update count
	node.count = 3
	lsx:Build(node, root, instance)
	T(#instance:GetChildren())["=="](3)
	T(instance:GetChildren()[1])["=="](firstChild) -- Should be same instance
	-- Decrease count
	node.count = 1
	lsx:Build(node, root, instance)
	T(#instance:GetChildren())["=="](1)
	T(instance:GetChildren()[1])["=="](firstChild)
	root:Remove()
end)

T.Test("lsx component ref and layout", function()
	local ref_called = false

	local function MyComponent(props)
		return lsx:Panel({
			Name = "InternalPanel",
			Size = Vec2(100, 100),
		})
	end

	local root = CreateMockRoot()
	local instance = lsx:Mount(
		{
			MyComponent,
			ref = function(pnl)
				ref_called = true
			end,
			Layout = {"Fill"},
		},
		root
	)
	T(ref_called)["=="](true)
	T(instance:GetLayout()[1])["=="]("Fill")
	instance:Remove()
	root:Remove()
end)

T.Test("lsx layout calculation with children", function()
	local function MyComponent(props)
		return lsx:Panel(
			{
				Name = "Container",
				Size = Vec2(200, 200),
				Layout = {"Fill"},
				lsx:Panel(
					{
						Name = "Child",
						Size = Vec2(50, 50),
						Layout = {"CenterXSimple"},
					}
				),
			}
		)
	end

	local root = CreateMockRoot()
	root:SetSize(Vec2(500, 500))
	local panel = lsx:Mount(MyComponent({}), root)
	-- Trigger layout calculation
	root:CalcLayout()
	T(panel:GetSize().x)["=="](500)
	T(panel:GetSize().y)["=="](500)
	local child = panel:GetChildren()[1]
	T(child ~= nil)["=="](true)
	child:CalcLayout()
	-- CenterXSimple should put it at (500-50)/2 = 225
	T(child:GetPosition().x)["=="](225)
	panel:Remove()
	root:Remove()
end)

T.Test("lsx:Build should not be called multiple times if setState is called multiple times", function()
	table.clear(lsx.pending_renders)
	local build_count = 0

	local function MyComponent(props)
		build_count = build_count + 1
		local state, set_state = lsx:UseState(0)

		lsx:UseEffect(function()
			set_state(1)
			set_state(2)
			set_state(3)
		end, {})

		return Mock({Name = "State:" .. state})
	end

	local root = CreateMockRoot()
	local node = {MyComponent}
	local instance = lsx:Mount(node, root)
	T(build_count)["=="](1)
	-- Process the scheduled re-render
	event.Call("Update")
	-- Should only be called once more
	T(build_count)["=="](2)
	T(instance:GetName())["=="]("State:3")
	root:Remove()
end)

T.Test("lsx:UseAnimate basic linear", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawAlpha",
				to = props.targetAlpha,
				time = 1,
			},
			{props.targetAlpha}
		)
		return Mock({ref = ref, DrawAlpha = 0})
	end

	local instance = lsx:MountTopLevel(MyComponent, {targetAlpha = 1}, root)
	-- Initially DrawAlpha should be 0 (the from value)
	T(instance:GetDrawAlpha())["=="](0)
	-- Advance time by 0.5s
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](0.5)
	-- Advance another 0.5s
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](1)
	root:Remove()
end)

T.Test("lsx:UseAnimate segmented with functions (pausing)", function()
	local root = CreateMockRoot()
	local is_hovered = false

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawAlpha",
				to = {
					1,
					function(self)
						return is_hovered
					end,
					0,
				},
				time = 1,
			},
			{is_hovered}
		)
		return Mock({ref = ref, DrawAlpha = 0})
	end

	local node = {MyComponent}
	local instance = lsx:Mount(node, root)
	T(instance:GetDrawAlpha())["=="](0)
	-- Trigger animation by setting is_hovered = true (re-rendering is not strictly necessary for the pause function but common)
	is_hovered = true
	lsx:Build(node, root, instance)
	lsx:RunPendingEffects()
	-- 1s duration, segmented: from(0) -> 1 -> 0. (total 2 segments)
	-- Pause is at segment index 1 (value 1.0, alpha 0.5)
	system.SetFrameTime(0.25)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](0.5)
	-- Reach the pause point
	system.SetFrameTime(0.25)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](1)
	-- Advance time, should stay paused
	system.SetFrameTime(1.0)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](1)
	-- Stop hovering, animation should continue from 0.5 alpha
	is_hovered = false
	system.SetFrameTime(0.25)
	instance:CalcAnimations()
	-- total_alpha = 0.75 * 2 = 1.5. segment [1->0]. alpha in segment = 0.5. lerp(0.5, 1, 0) = 0.5
	T(instance:GetDrawAlpha())["=="](0.5)
	system.SetFrameTime(0.25)
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())["=="](0)
	root:Remove()
end)

T.Test("lsx:UseAnimate with lsx:Value", function()
	local root = CreateMockRoot()
	local window = require("window")
	local mousePos = Vec2(0, 0)
	local oldGetMousePosition = window.GetMousePosition
	window.GetMousePosition = function()
		return mousePos
	end

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawPositionOffset",
				to = lsx:Value(function(self)
					return window.GetMousePosition()
				end),
				time = 1,
			},
			{}
		)
		return Mock({ref = ref, DrawPositionOffset = Vec2(0, 0)})
	end

	local node = {MyComponent}
	local instance = lsx:Mount(node, root)
	mousePos = Vec2(100, 100)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawPositionOffset().x)["=="](50)
	T(instance:GetDrawPositionOffset().y)["=="](50)
	-- Update mouse pos during animation
	mousePos = Vec2(200, 200)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawPositionOffset().x)["=="](200)
	T(instance:GetDrawPositionOffset().y)["=="](200)
	window.GetMousePosition = oldGetMousePosition
	root:Remove()
end)

T.Test("lsx:UseAnimate with spring interpolation", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawAlpha",
				to = 1,
				interpolation = {
					type = "spring",
					bounce = 0,
					duration = 1000,
					epsilon = 0.0001,
				},
			},
			{props.trigger}
		)
		return Mock({ref = ref, DrawAlpha = 0})
	end

	local node = {MyComponent, trigger = 1}
	local instance = lsx:Mount(node, root)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	local val = instance:GetDrawAlpha()
	T(val > 0)["=="](true)
	T(val < 1)["=="](true)
	-- Spring (with 0 bounce) at 0.5s of 1.0s should be quite far along
	T(val > 0.5)["=="](true)
	system.SetFrameTime(10) -- settle
	instance:CalcAnimations()
	T(instance:GetDrawAlpha())[">"](0.99)
	root:Remove()
end)

T.Test("lsx:UseAnimate with operator and absolute values", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawScaleOffset",
				to = Vec2(2, 2),
				operator = "=",
				time = 1,
			},
			{props.trigger}
		)
		return Mock({ref = ref, DrawScaleOffset = Vec2(1, 1)})
	end

	local node = {MyComponent, trigger = 1}
	local instance = lsx:Mount(node, root)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawScaleOffset().x)["=="](1.5)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	T(instance:GetDrawScaleOffset().x)["=="](2)
	root:Remove()
end)

T.Test("lsx:UseAnimate with Ang3", function()
	local root = CreateMockRoot()

	local function MyComponent(props)
		local ref = lsx:UseRef(nil)
		lsx:UseAnimate(
			ref,
			{
				var = "DrawAngleOffset",
				to = Ang3(0.1, 0.2, 0.3),
				time = 1,
			},
			{}
		)
		return Mock({ref = ref, DrawAngleOffset = Ang3(0, 0, 0)})
	end

	local node = {MyComponent}
	local instance = lsx:Mount(node, root)
	system.SetFrameTime(0.5)
	instance:CalcAnimations()
	local ang = instance:GetDrawAngleOffset()
	T(ang.p)["~"](0.05)
	T(ang.y)["~"](0.1)
	T(ang.r)["~"](0.15)
	root:Remove()
end)

T.Test("lsx component ref and layout", function()
	local ref_called = false

	local function MyComponent(props)
		return lsx:Panel({
			Name = "InternalPanel",
			Size = Vec2(100, 100),
		})
	end

	local root = CreateMockRoot()
	local instance = lsx:Mount(
		{
			MyComponent,
			ref = function(pnl)
				ref_called = true
			end,
			Layout = {"Fill"},
		},
		root
	)
	T(ref_called)["=="](true)
	T(instance:GetLayout()[1])["=="]("Fill")
	instance:Remove()
	root:Remove()
end)

T.Test("lsx layout calculation with children", function()
	local function MyComponent(props)
		return lsx:Panel(
			{
				Name = "Container",
				Size = Vec2(200, 200),
				Layout = {"Fill"}, -- This layout might depend on children if it was something else, but let's test a simple Case
				lsx:Panel(
					{
						Name = "Child",
						Size = Vec2(50, 50),
						Layout = {"CenterXSimple"},
					}
				),
			}
		)
	end

	local root = CreateMockRoot()
	root:SetSize(Vec2(500, 500))
	local panel = lsx:Mount(MyComponent({}), root)
	-- Trigger layout calculation
	root:CalcLayout()
	T(panel:GetSize().x)["=="](500)
	T(panel:GetSize().y)["=="](500)
	local child = panel:GetChildren()[1]
	T(child ~= nil)["=="](true)
	child:CalcLayout()
	-- CenterXSimple should put it at (500-50)/2 = 225
	T(child:GetPosition().x)["=="](225)
	panel:Remove()
	root:Remove()
end)

T.Test("lsx:HoverPanel regression test", function()
	local root = CreateMockRoot()
	root:SetSize(Vec2(500, 500))
	local hover_count = 0
	local IsHovered_called = 0
	-- Mock IsHovered since we don't have a real mouse/window interaction easily here
	local original_IsHovered = prototype.registered.gui_element_2d.IsHovered
	local mock_hovered = false
	prototype.registered.gui_element_2d.IsHovered = function(self, mouse_pos)
		IsHovered_called = IsHovered_called + 1
		return mock_hovered
	end

	local function MyHover(props)
		local is_hovered, set_hovered = lsx:UseState(false)
		local ref = lsx:UseRef(nil)

		lsx:UseEffect(
			function()
				if ref.current then
					local gui = ref.current:GetComponent("gui_element_2d")

					if gui then set_hovered(gui:IsHovered(Vec2(0, 0))) end
				end
			end,
			{props.tick}
		)

		return lsx:Panel(
			{
				ref = ref,
				Name = "HoverTarget",
				Size = Vec2(100, 100),
				Scale = is_hovered and Vec2(2, 2) or Vec2(1, 1),
			}
		)
	end

	local node = {MyHover, tick = 1}
	local instance = lsx:Mount(node, root)
	T(instance:GetScale().x)["=="](1)
	-- Trigger hover
	mock_hovered = true
	node.tick = 2
	lsx:Build(node, root, instance)
	lsx:RunPendingEffects()
	-- A re-render should have been scheduled
	event.Call("Update")
	T(instance:GetScale().x)["=="](2)
	-- Check setter optimization safety
	local scale_calls = 0
	local original_SetScale = prototype.registered.transform_2d.SetScale
	prototype.registered.transform_2d.SetScale = function(self, val)
		scale_calls = scale_calls + 1
		return original_SetScale(self, val)
	end
	scale_calls = 0
	node.tick = 3
	lsx:Build(node, root, instance)
	T(scale_calls)["=="](0) -- Should NOT have called SetScale because Scale didn't change
	prototype.registered.transform_2d.SetScale = original_SetScale
	-- Clean up
	prototype.registered.gui_element_2d.IsHovered = original_IsHovered
	root:Remove()
end)
