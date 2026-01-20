local T = require("test.environment")
local lsx = require("gui.lsx")
local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local event = require("event")
local gui = require("gui.gui")

T.Test("lsx.HoverPanel regression test", function()
	local root = gui.CreateBasePanel()
	root:SetSize(Vec2(500, 500))

	local hover_count = 0
	local IsHovered_called = 0

	-- Mock IsHovered since we don't have a real mouse/window interaction easily here
	local original_IsHovered = prototype.registered.surface_base.IsHovered
	local mock_hovered = false
	prototype.registered.surface_base.IsHovered = function(self, mouse_pos)
		IsHovered_called = IsHovered_called + 1
		return mock_hovered
	end

	local MyHover = lsx.Component(function(props)
		local is_hovered, set_hovered = lsx.UseState(false)
		local ref = lsx.UseRef(nil)

		lsx.UseEffect(function()
			if ref.current then
				set_hovered(ref.current:IsHovered(Vec2(0, 0)))
			end
		end, {props.tick})

		return lsx.Panel({
			ref = ref,
			Name = "HoverTarget",
			Size = Vec2(100, 100),
			Scale = is_hovered and Vec2(2, 2) or Vec2(1, 1)
		})
	end)

	local node = MyHover({tick = 1})
	local instance = lsx.Mount(node, root)

	T(instance:GetScale().x)["=="](1)

	-- Trigger hover
	mock_hovered = true
	node.props.tick = 2
	lsx.Build(node, root, instance)
	lsx.RunPendingEffects()

	-- A re-render should have been scheduled
	event.Call("Update")

	T(instance:GetScale().x)["=="](2)

	-- Check setter optimization safety
	local scale_calls = 0
	local original_SetScale = prototype.registered.surface_base.SetScale
	prototype.registered.surface_base.SetScale = function(self, val)
		scale_calls = scale_calls + 1
		return original_SetScale(self, val)
	end

	scale_calls = 0
	node.props.tick = 3
	lsx.Build(node, root, instance)
	T(scale_calls)["=="](0) -- Should NOT have called SetScale because Scale didn't change

	prototype.registered.surface_base.SetScale = original_SetScale

	-- Clean up
	prototype.registered.surface_base.IsHovered = original_IsHovered
	root:Remove()
end)
