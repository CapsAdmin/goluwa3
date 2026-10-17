local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

T.Test2D("scrollable panel with default settings lets a tall child keep its height and shows the scrollbar", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{}
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(child.transform:GetHeight())["=="](1000)
	T(panel.Viewport.layout:GetDirection())["=="]("y")
	T(panel.Viewport.layout.content_size.y)["=="](1000)
	T(panel.HandleY.visual:GetVisible())["=="](true)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollable panel hides the scrollbar when everything fits", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{}
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 50), MaxSize = Vec2(0, 50)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(child.transform:GetHeight())["=="](50)
	T(panel.HandleY.visual:GetVisible())["=="](false)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollable panel with only ScrollX never shows the vertical scrollbar", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{ScrollX = true, ScrollY = false}
	local child = Panel.New{
		transform = true,
		layout = {MinSize = Vec2(1000, 50), MaxSize = Vec2(1000, 50)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.HandleX.visual:GetVisible())["=="](true)
	T(panel.HandleY.visual:GetVisible())["=="](false)
	T(panel.TrackY.visual:GetVisible())["=="](false)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollbar auto mode shifts content in big panels and floats over it in small ones", function()
	local old_world, world = create_world()
	local theme = import("goluwa/render2d/ui/theme.lua")
	local threshold = theme.active:GetScrollbarAutoShiftSize()
	local results = {}

	for name, width in pairs{big = threshold + 100, small = threshold - 100} do
		local panel = ScrollablePanel{Padding = Rect(10, 10, 10, 10)}
		panel:AddChild(
			Panel.New{
				transform = true,
				layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
			}
		)
		panel:SetParent(world)
		panel.transform:SetSize(Vec2(width, 300))

		for _ = 1, 3 do
			panel.layout:UpdateLayout()
			world.visual:DrawRecursive()
		end

		results[name] = {
			reserve = panel.Viewport.layout:GetPadding().w - 10,
			bar_visible = panel.HandleY.visual:GetVisible(),
			track_y = panel.TrackY.transform:GetPosition().y,
			track_right = width - (
					panel.TrackY.transform:GetPosition().x + panel.TrackY.transform:GetWidth()
				),
		}
		panel:Remove()
	end

	local margin = theme.active:GetScrollbarMargin()
	T(results.big.bar_visible)["=="](true)
	T(results.small.bar_visible)["=="](true)
	T(results.big.reserve)[">"](0)
	T(results.small.reserve)["=="](0)
	T(results.big.track_y)["=="](margin)
	T(results.big.track_right)["=="](margin)
	Panel.World = old_world
end)

T.Test2D("explicit shift modes ignore the panel size", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{ScrollbarShiftMode = "no_shift"}
	panel:AddChild(
		Panel.New{
			transform = true,
			layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
		}
	)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(500, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.Viewport.layout:GetPadding().w)["=="](0)
	panel:Remove()
	panel = ScrollablePanel{ScrollbarShiftMode = "always_shift"}
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(100, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.Viewport.layout:GetPadding().w)[">"](0)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollbar buttons sit at both ends of the bar and scroll a line when clicked", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{ScrollbarButtons = true}
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	local width = panel.TrackY.transform:GetWidth()
	T(panel.ButtonY1.visual:GetVisible())["=="](true)
	T(panel.ButtonY2.visual:GetVisible())["=="](true)
	T(panel.ButtonX1.visual:GetVisible())["=="](false)
	T(panel.ButtonY1.transform:GetPosition().y)["=="](panel.TrackY.transform:GetPosition().y - width)
	T(panel.ButtonY2.transform:GetPosition().y)["=="](
		panel.TrackY.transform:GetPosition().y + panel.TrackY.transform:GetHeight()
	)
	panel.ButtonY2:CallLocalEvent("OnStartClick", "button_1", true)
	panel.repeat_button = nil
	T(panel.Viewport.transform:GetScroll().y)["=="](40)
	panel.ButtonY1:CallLocalEvent("OnStartClick", "button_1", true)
	panel.repeat_button = nil
	panel.ButtonY1:CallLocalEvent("OnStartClick", "button_1", true)
	panel.repeat_button = nil
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel:SetScrollbarButtons(false)

	for _ = 1, 2 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.ButtonY1.visual:GetVisible())["=="](false)
	T(panel.TrackY.transform:GetHeight() > 0)["=="](true)
	panel:Remove()
	Panel.World = old_world
end)

local function tall_panel(props)
	local old_world, world = create_world()
	local panel = ScrollablePanel(props or {})
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	return panel, old_world
end

T.Test2D("clicking the track outside the handle scrolls a page towards the click", function()
	local panel, old_world = tall_panel()
	local view = panel:get_view_length("y")
	local handle_top = panel.HandleY.transform:GetPosition().y - panel.TrackY.transform:GetPosition().y
	local handle_bottom = handle_top + panel.HandleY.transform:GetHeight()
	panel.TrackY:CallLocalEvent("OnStartClick", "button_1", true, Vec2(2, handle_bottom + 5))
	panel.repeat_button = nil
	T(panel.Viewport.transform:GetScroll().y)["=="](view - 40)
	panel.TrackY:CallLocalEvent("OnStartClick", "button_1", true, Vec2(2, 0))
	panel.repeat_button = nil
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel.TrackY:CallLocalEvent("OnStartClick", "button_1", true, Vec2(2, handle_top + 2))
	panel.repeat_button = nil
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("key scrolling is on by default and uses the arrow keys, page up, page down, home and end", function()
	local panel, old_world = tall_panel()
	T(panel.Viewport.mouse_input:GetFocusOnClick())["=="](true)
	T(panel.TrackY.mouse_input:GetFocusOnClick())["=="](true)
	panel:SetKeyScrolling(false)
	T(panel.Viewport.mouse_input:GetFocusOnClick())["=="](false)
	T(panel:handle_scroll_key("down"))["=="](nil)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel:SetKeyScrolling(true)
	local view = panel:get_view_length("y")
	panel.Viewport:CallLocalEvent("OnKeyInput", "down", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](40)
	panel.Viewport:CallLocalEvent("OnKeyInput", "up", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel.Viewport:CallLocalEvent("OnKeyInput", "pagedown", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](view - 40)
	panel.Viewport:CallLocalEvent("OnKeyInputRepeat", "pagedown")
	T(panel.Viewport.transform:GetScroll().y)["=="]((view - 40) * 2)
	panel.Viewport:CallLocalEvent("OnKeyInput", "pageup", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](view - 40)
	panel.Viewport:CallLocalEvent("OnKeyInput", "end", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](1000 - view)
	panel.Viewport:CallLocalEvent("OnKeyInput", "home", true)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	T(panel:handle_scroll_key("left"))["=="](nil)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("a hidden scroll view ignores scroll keys", function()
	local panel, old_world = tall_panel()
	panel.visual:SetVisible(false)
	T(panel:handle_scroll_key("down"))["=="](nil)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel.visual:SetVisible(true)
	T(panel:handle_scroll_key("down"))["=="](true)
	T(panel.Viewport.transform:GetScroll().y)["=="](40)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("holding the middle button autoscrolls faster the further the mouse is from the press point", function()
	local panel, old_world = tall_panel()
	T(panel.AutoscrollMarker.visual:GetVisible())["=="](false)
	T(panel.Viewport:CallLocalEvent("OnMouseInput", "button_3", true, Vec2(1, 1)))["=="](true)
	T(panel.AutoscrollMarker.visual:GetVisible())["=="](true)
	panel:end_autoscroll()
	T(panel.AutoscrollMarker.visual:GetVisible())["=="](false)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(100, 105), 1)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel:update_autoscroll(Vec2(100, 120), 1)
	local near = panel.Viewport.transform:GetScroll().y
	T(near > 0)["=="](true)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(100, 160), 1)
	T(panel.Viewport.transform:GetScroll().y > near * 2)["=="](true)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(100, 20), 1)
	T(panel.Viewport.transform:GetScroll().y)["=="](0)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(100, 100000), 1)
	T(panel.Viewport.transform:GetScroll().y)["=="](1000 - panel:get_view_length("y"))
	T(panel.Viewport.transform:GetScroll().x)["=="](0)
	panel:end_autoscroll()
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("a middle click without moving keeps autoscrolling until the next click or escape", function()
	local panel, old_world = tall_panel()
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(104, 103), 1)
	panel:release_autoscroll()
	T(panel.autoscroll_sticky)["=="](true)
	T(panel.AutoscrollMarker.visual:GetVisible())["=="](true)
	panel:update_autoscroll(Vec2(100, 160), 1)
	T(panel.Viewport.transform:GetScroll().y > 0)["=="](true)
	T(panel:OnGlobalMouseInput("mwheel_up", true))["=="](nil)
	T(panel.autoscroll_sticky)["=="](true)
	T(panel:OnGlobalMouseInput("button_1", false))["=="](nil)
	T(panel:OnGlobalMouseInput("button_1", true))["=="](true)
	T(panel.autoscroll_origin)["=="](nil)
	T(panel.AutoscrollMarker.visual:GetVisible())["=="](false)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:release_autoscroll()
	T(panel.autoscroll_sticky)["=="](true)
	T(panel:OnAutoscrollKeyInput("a", true))["=="](nil)
	T(panel:OnAutoscrollKeyInput("escape", true))["=="](true)
	T(panel.autoscroll_origin)["=="](nil)
	panel:begin_autoscroll(Vec2(100, 100))
	panel:update_autoscroll(Vec2(100, 150), 0.1)
	panel:release_autoscroll()
	T(panel.autoscroll_origin)["=="](nil)
	T(panel.autoscroll_sticky)["=="](false)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("clicking a child that takes no focus focuses the scroll view, a panel outside it clears focus", function()
	local objects = import("goluwa/objects/objects.lua")
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local old_world, world = create_world()
	local panel = ScrollablePanel{}
	local child = Panel.New{
		transform = true,
		visual = true,
		mouse_input = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))
	local outside = Panel.New{
		Parent = world,
		transform = true,
		visual = true,
		mouse_input = true,
		Position = Vec2(300, 0),
	}
	outside.transform:SetPosition(Vec2(300, 0))
	outside.transform:SetSize(Vec2(100, 100))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end
	objects.SetFocusedObject(NULL)
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	T(objects.GetFocusedObject() == panel.Viewport)["=="](true)
	window.GetMousePosition = function()
		return Vec2(350, 50)
	end
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	T(objects.GetFocusedObject():IsValid())["=="](false)
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	panel:Remove()
	outside:Remove()
	Panel.World = old_world
end)

T.Test2D("a focused scroll view does not count as the desktop being edited", function()
	local objects = import("goluwa/objects/objects.lua")
	local desktop = import("goluwa/render2d/ui/desktop.lua")
	local old_world, world = create_world()
	local window = Panel.New{Parent = world, transform = true, visual = true}
	window.transform:SetSize(Vec2(200, 300))
	local scroll = ScrollablePanel{}
	window:AddChild(scroll)
	desktop.RegisterProgram{Name = "scroll_test_program", Create = function() return window end}
	desktop.GetProgram("scroll_test_program").Window = window
	objects.SetFocusedObject(window)
	T(desktop.IsEditing())["=="](true)
	objects.SetFocusedObject(scroll.Viewport)
	T(desktop.IsEditing())["=="](false)
	objects.SetFocusedObject(scroll.TrackY)
	T(desktop.IsEditing())["=="](false)
	objects.SetFocusedObject(NULL)
	window:Remove()
	Panel.World = old_world
end)

T.Test2D("scrolling with the wheel does not change focus", function()
	local objects = import("goluwa/objects/objects.lua")
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local old_world, world = create_world()
	local panel = ScrollablePanel{KeyScrolling = false}
	local field = Panel.New{
		transform = true,
		visual = true,
		mouse_input = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	field.mouse_input:SetFocusOnClick(true)
	panel:AddChild(field)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end
	field:RequestFocus()
	event.Call("MouseInput", "mwheel_up", true)
	event.Call("MouseInput", "mwheel_up", false)
	T(objects.GetFocusedObject() == field)["=="](true)
	T(panel.Viewport.transform:GetScroll().y)["=="](40)
	-- over something that takes no focus the wheel must not clear it either
	window.GetMousePosition = function()
		return Vec2(600, 600)
	end
	event.Call("MouseInput", "mwheel_up", true)
	event.Call("MouseInput", "mwheel_up", false)
	T(objects.GetFocusedObject() == field)["=="](true)
	-- a click still does
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	T(objects.GetFocusedObject():IsValid())["=="](false)
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	panel:Remove()
	Panel.World = old_world
end)

local function nested_scroll(inner_height)
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local old_world, world = create_world()
	local outer = ScrollablePanel{}
	local inner = ScrollablePanel{layout = {GrowWidth = 1, MinSize = Vec2(0, 200), MaxSize = Vec2(0, 200)}}
	inner:AddChild(
		Panel.New{
			transform = true,
			layout = {GrowWidth = 1, MinSize = Vec2(0, inner_height), MaxSize = Vec2(0, inner_height)},
		}
	)
	local spacer = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	outer:AddChild(inner)
	outer:AddChild(spacer)
	outer:SetParent(world)
	outer.transform:SetSize(Vec2(300, 300))

	for _ = 1, 4 do
		outer.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end

	local function wheel()
		event.Call("MouseInput", "mwheel_up", true)
		event.Call("MouseInput", "mwheel_up", false)
	end

	local function finish()
		window.GetMousePosition = old_get_mouse_pos
		window.GetSize = old_get_size
		outer:Remove()
		Panel.World = old_world
	end

	return outer, inner, wheel, finish
end

T.Test2D("a scroll view with nothing to scroll passes the wheel on to the view around it", function()
	local outer, inner, wheel, finish = nested_scroll(100)
	wheel()
	T(inner.Viewport.transform:GetScroll().y)["=="](0)
	T(outer.Viewport.transform:GetScroll().y)["=="](40)
	finish()
end)

T.Test2D("a nested scroll view scrolls to its end and then the wheel continues in the view around it", function()
	local outer, inner, wheel, finish = nested_scroll(600)
	wheel()
	T(inner.Viewport.transform:GetScroll().y)["=="](40)
	T(outer.Viewport.transform:GetScroll().y)["=="](0)

	for _ = 1, 9 do
		wheel()
	end

	T(inner.Viewport.transform:GetScroll().y)["=="](400)
	T(outer.Viewport.transform:GetScroll().y)["=="](0)
	wheel()
	T(inner.Viewport.transform:GetScroll().y)["=="](400)
	T(outer.Viewport.transform:GetScroll().y)["=="](40)
	finish()
end)

T.Test2D("the click that stops a toggled autoscroll is consumed by the real mouse path", function()
	local objects = import("goluwa/objects/objects.lua")
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local panel, old_world = tall_panel()
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end
	panel:begin_autoscroll(Vec2(50, 50))
	panel:release_autoscroll()
	objects.SetFocusedObject(NULL)
	T(panel.autoscroll_sticky)["=="](true)
	event.Call("MouseInput", "button_1", true)
	T(panel.autoscroll_origin)["=="](nil)
	-- the press was consumed, so it did not focus the view
	T(objects.GetFocusedObject():IsValid())["=="](false)
	event.Call("MouseInput", "button_1", false)
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	T(objects.GetFocusedObject() == panel.Viewport)["=="](true)
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollbars grow while hovered without changing the layout", function()
	local theme = import("goluwa/render2d/ui/theme.lua")
	local panel, old_world = tall_panel()
	local collapsed = theme.active:GetScrollbarCollapsedWidth()
	local full = theme.active:GetScrollbarWidth()
	T(collapsed < full)["=="](true)
	T(panel.TrackY.Expand)["=="](0)
	T(panel.HandleY.Expand)["=="](0)
	T(panel:get_scrollbar_reserve())["=="](collapsed + theme.active:GetScrollbarMargin())
	local padding = panel.Viewport.layout:GetPadding().w
	local size = panel.TrackY.transform:GetSize():Copy()
	panel.HandleY.mouse_input:SetHovered(true)
	panel:update_expand()
	T(panel.TrackY.Expand)["=="](1)
	T(panel.HandleY.Expand)["=="](1)
	T(panel.TrackX.Expand)["=="](0)
	panel.HandleY.mouse_input:SetHovered(false)
	panel:update_expand()
	T(panel.TrackY.Expand)["=="](0)

	for _ = 1, 2 do
		panel.layout:UpdateLayout()
	end

	T(panel.Viewport.layout:GetPadding().w)["=="](padding)
	T(panel.TrackY.transform:GetWidth())["=="](size.x)
	panel:SetScrollbarButtons(true)
	panel:update_expand()
	T(panel.TrackY.Expand)["=="](1)
	T(panel:get_scrollbar_reserve())["=="](full + theme.active:GetScrollbarMargin())
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("the wheel scrolls while the mouse is over the scrollbar track, handle and buttons", function()
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local panel, old_world = tall_panel({ScrollbarButtons = true})
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	local last = 0

	for _, part in ipairs({panel.HandleY, panel.TrackY, panel.ButtonY1, panel.ButtonY2}) do
		local position = part.transform:GetPosition()
		local size = part.transform:GetSize()
		window.GetMousePosition = function()
			return position + size / 2
		end
		event.Call("MouseInput", "mwheel_up", true)
		event.Call("MouseInput", "mwheel_up", false)
		T(panel.Viewport.transform:GetScroll().y)["=="](last + 40)
		last = last + 40
	end

	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("the resize border of a panel is outside it, so a scrollbar at its edge keeps the mouse", function()
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local old_world, world = create_world()
	local window_panel = Panel.New{
		Parent = world,
		transform = true,
		visual = true,
		mouse_input = true,
		resizable = true,
	}
	window_panel.transform:SetPosition(Vec2(20, 20))
	window_panel.transform:SetSize(Vec2(300, 300))
	local scroll = ScrollablePanel{}
	scroll:AddChild(
		Panel.New{
			transform = true,
			layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
		}
	)
	window_panel:AddChild(scroll)
	scroll.transform:SetSize(Vec2(300, 300))

	for _ = 1, 3 do
		scroll.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	local handle = scroll.HandleY
	local handle_position = handle.transform:GetPosition()
	local handle_size = handle.transform:GetSize()
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	local over_handle = Vec2(20 + handle_position.x + handle_size.x / 2, 20 + handle_position.y + handle_size.y / 2)
	T(over_handle.x > 20 + 300 - 8)["=="](true)
	window.GetMousePosition = function()
		return over_handle
	end
	event.Call("MouseMove", over_handle)
	T(window_panel.mouse_input:GetCursor())["~="]("horizontal_resize")
	T(window_panel.resizable:GetResizeLocation(Vec2(299, 100)))["=="](nil)
	event.Call("MouseInput", "button_1", true)
	T(window_panel.resizable:IsResizing())["=="](false)
	event.Call("MouseInput", "button_1", false)
	T(window_panel.resizable:GetResizeLocation(Vec2(304, 100)))["=="]("right")
	window.GetMousePosition = function()
		return Vec2(20 + 300 + 4, 120)
	end
	event.Call("MouseInput", "button_1", true)
	T(window_panel.resizable:IsResizing())["=="](true)
	event.Call("MouseInput", "button_1", false)
	window_panel.resizable:StopResizing()
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	window_panel:Remove()
	Panel.World = old_world
end)
