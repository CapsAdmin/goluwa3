local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")

T.Test("panel constructor 2d entities", function()
	local pnl = Panel.NewPanel({Name = "test_panel"})
	T(pnl:IsValid())["=="](true)
	T(pnl.transform)["~="](nil)
	T(pnl.rect)["~="](nil)
	T(pnl.mouse_input)["~="](nil)
	local txt = Panel.NewText({Name = "test_text", Parent = pnl})
	T(txt:IsValid())["=="](true)
	T(txt.text)["~="](nil)
	T(txt.transform)["~="](nil)
	T(txt:GetParent())["=="](pnl)
end)

T.Test("panel mouse input states", function()
	local pnl = Panel.NewPanel({Name = "mouse_test"})
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
	local parent = Panel.NewPanel({Name = "parent"})
	parent.transform:SetSize(Vec2(200, 200))
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	local child = Panel.NewPanel({Parent = parent, Name = "child"})
	child.layout:SetLayout("Fill")
	parent.layout:CalcLayout()
	T(child.transform:GetSize())["=="](Vec2(200, 200))
	parent.transform:SetSize(Vec2(300, 300))
	parent.layout:CalcLayout()
	T(child.transform:GetSize())["=="](Vec2(300, 300))
end)

T.Test("panel flex layout", function()
	local parent = Panel.NewPanel({Name = "flex_parent"})
	parent.transform:SetSize(Vec2(200, 200))
	parent.layout:SetFlex(true)
	parent.layout:SetFlexDirection("column")
	parent.layout:SetFlexGap(10)
	local child1 = Panel.NewPanel({Parent = parent})
	child1.transform:SetSize(Vec2(50, 50))
	local child2 = Panel.NewPanel({Parent = parent})
	child2.transform:SetSize(Vec2(50, 50))
	parent.layout:CalcLayout()
	-- With column flex and 10px gap:
	-- Child 1 at (0,0) (assuming no padding)
	-- Child 2 at (0, 50 + 10) = (0, 60)
	T(child1.transform:GetPosition())["=="](Vec2(0, 0))
	T(child2.transform:GetPosition())["=="](Vec2(0, 60))
end)

T.Test("panel animations basic", function()
	local pnl = Panel.NewPanel({Name = "anim_test"})
	pnl.rect:SetColor(Color(1, 0, 0, 1))
	-- Animations usually require time to pass, 
	-- but we can check if the component exists and responds to Animate.
	T(pnl.animation)["~="](nil)
	pnl.animation:Animate(
		{
			id = "color",
			base = pnl.rect:GetDrawColor(),
			get = function()
				return pnl.rect:GetDrawColor()
			end,
			set = function(v)
				pnl.rect:SetDrawColor(v)
			end,
			to = Color(0, 1, 0, 1),
			time = 0.1,
		}
	)
-- Without a system update, it might not change immediately
-- but we check it doesn't crash and initializes the animation.
end)

T.Test("panel mouse simulation and hover", function()
	local window = require("window")
	local event = require("event")
	local world = require("ecs.panel").World
	world:RemoveChildren()
	world.transform:SetSize(Vec2(2000, 2000))
	local pnl = Panel.NewPanel({Name = "sim_target", Parent = world})
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
	local pnl = Panel.NewPanel({Name = "key_test"})
	pnl:AddComponent("key_input")
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
