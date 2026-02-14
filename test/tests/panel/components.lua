local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")

T.Test("panel constructor 2d entities", function()
	local pnl = Panel.New(
		{
			Name = "test_panel",
			transform = true,
			rect = true,
			mouse_input = true,
		}
	)
	T(pnl:IsValid())["=="](true)
	T(pnl.transform)["~="](nil)
	T(pnl.rect)["~="](nil)
	T(pnl.mouse_input)["~="](nil)
	local txt = Panel.New({
		Name = "test_text",
		Parent = pnl,
		text = true,
		transform = true,
	})
	T(txt:IsValid())["=="](true)
	T(txt.text)["~="](nil)
	T(txt.transform)["~="](nil)
	T(txt:GetParent())["=="](pnl)
end)

T.Test("panel mouse input states", function()
	local pnl = Panel.New({
		Name = "mouse_test",
		transform = true,
		mouse_input = true,
	})
	pnl.transform:SetSize(Vec2(100, 100))
	pnl.mouse_input:SetFocusOnClick(true)
	T(pnl.mouse_input:GetFocusOnClick())["=="](true)
	T(pnl.mouse_input:GetHovered())["=="](false)
	-- Note: Simulating actual mouse events usually requires more setup 
	-- in the GUI system, but we can check the component state.
	pnl.mouse_input:SetCursor("hand")
	T(pnl.mouse_input:GetCursor())["=="]("hand")
end)

T.Test("panel resize layout invalidation", function()
	local parent = Panel.New(
		{
			Name = "parent",
			transform = true,
			layout = {
				Padding = Rect(0, 0, 0, 0),
				AlignmentX = "stretch",
				AlignmentY = "stretch",
			},
		}
	)
	parent.transform:SetSize(Vec2(200, 200))
	local child = Panel.New(
		{
			Parent = parent,
			Name = "child",
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
			},
		}
	)
	parent.layout:UpdateLayout()
	T(child.transform:GetSize())["=="](Vec2(200, 200))
	parent.transform:SetSize(Vec2(300, 300))
	parent.layout:UpdateLayout()
	T(child.transform:GetSize())["=="](Vec2(300, 300))
end)

T.Test("panel flex layout", function()
	local parent = Panel.New(
		{
			Name = "flex_parent",
			transform = true,
			layout = {
				Direction = "y",
				ChildGap = 10,
				AlignmentX = "start",
				AlignmentY = "start",
			},
		}
	)
	parent.transform:SetSize(Vec2(200, 200))
	local child1 = Panel.New({Parent = parent, transform = true})
	child1.transform:SetSize(Vec2(50, 50))
	local child2 = Panel.New({Parent = parent, transform = true})
	child2.transform:SetSize(Vec2(50, 50))
	parent.layout:UpdateLayout()
	-- With column flex and 10px gap:
	-- Child 1 at (0,0) (assuming no padding)
	-- Child 2 at (0, 50 + 10) = (0, 60)
	T(child1.transform:GetPosition())["=="](Vec2(0, 0))
	T(child2.transform:GetPosition())["=="](Vec2(0, 60))
end)

T.Test("panel animations basic", function()
	local pnl = Panel.New({
		Name = "anim_test",
		transform = true,
		rect = true,
		animation = true,
	})
	pnl.gui_element:SetColor(Color(1, 0, 0, 1))
	-- Animations usually require time to pass, 
	-- but we can check if the component exists and responds to Animate.
	T(pnl.animation)["~="](nil)
	pnl.animation:Animate(
		{
			id = "color",
			base = pnl.gui_element:GetDrawColor(),
			get = function()
				return pnl.gui_element:GetDrawColor()
			end,
			set = function(v)
				pnl.gui_element:SetDrawColor(v)
			end,
			to = Color(0, 1, 0, 1),
			time = 0.1,
		}
	)
-- Without a system update, it might not change immediately
-- but we check it doesn't crash and initializes the animation.
end)

T.Pending("panel mouse simulation and hover", function()
	local window = require("window")
	local event = require("event")
	local world = require("ecs.panel").World
	world:RemoveChildren()
	world.transform:SetSize(Vec2(2000, 2000))
	local pnl = Panel.New({
		Name = "mouse_test",
		transform = true,
		mouse_input = true,
	})
	pnl.transform:SetPosition(Vec2(100, 100))
	pnl.transform:SetSize(Vec2(50, 50))
	local clicked = false
	local entered = false
	local left = false

	function pnl:OnMouseInput(button, press)
		if button == "button_1" and press then clicked = true end
	end

	function pnl:OnMouseEnter()
		entered = true
	end

	function pnl:OnMouseLeave()
		left = true
	end

	local old_GetMousePosition = window.GetMousePosition
	-- 1. Enter
	window.GetMousePosition = function()
		return Vec2(125, 125)
	end
	event.Call("Update")
	T(entered)["=="](true)
	T(pnl.mouse_input:GetHovered())["=="](true)
	-- 2. Click
	event.Call("MouseInput", "button_1", true)
	T(clicked)["=="](true)
	-- 3. Leave
	window.GetMousePosition = function()
		return Vec2(0, 0)
	end
	event.Call("Update")
	T(left)["=="](true)
	T(pnl.mouse_input:GetHovered())["=="](false)
	window.GetMousePosition = old_GetMousePosition
	pnl:Remove()
end)

T.Test("panel key simulation", function()
	local prototype = require("prototype")
	local event = require("event")
	local pnl = Panel.New(
		{
			Name = "key_test",
			transform = true,
			key_input = true,
			mouse_input = true,
		}
	)
	pnl.mouse_input:SetFocusOnClick(true)
	local key_received = false

	function pnl:OnKeyInput(key, press)
		if key == "a" and press then key_received = true end
	end

	pnl:RequestFocus()
	T(prototype.GetFocusedObject())["=="](pnl)
	event.Call("KeyInput", "a", true)
	T(key_received)["=="](true)
end)
