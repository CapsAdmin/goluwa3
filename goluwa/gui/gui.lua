local event = require("event")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local gui = library()
gui.focus_panel = NULL
package.loaded["gui.gui"] = gui
gui.PressedObjects = {}

do
	local function check(panel, mouse_pos)
		if not panel.Visible then return nil end

		if panel.IgnoreMouseInput then return nil end

		-- If clipping is enabled and the mouse is outside the panel,
		-- then neither this panel nor any of its descendants are visible here.
		if panel:GetClipping() and not panel:IsHovered(mouse_pos) then return nil end

		-- Check children in reverse render order (top-most first)
		local children = panel:GetChildren()

		for i = #children, 1, -1 do
			local found = check(children[i], mouse_pos)

			if found then return found end
		end

		if panel:IsHovered(mouse_pos) then return panel end

		return nil
	end

	function gui.GetHoveredObject(mouse_pos)
		return check(gui.Root, mouse_pos)
	end
end

function gui.Initialize()
	gui.Root = gui.Create("base")
	gui.Root:SetName("Root")
	gui.Root.OnDraw = function()
		render2d.ClearStencil()
	end
	local w, h = render2d.GetSize()

	if w then gui.Root:SetSize(Vec2(w, h)) end

	event.AddListener("WindowFramebufferResized", "gui_root", function(wnd, size)
		if gui.Root and gui.Root:IsValid() then
			gui.Root:SetSize(Vec2(size.w, size.h))
		end
	end)

	event.AddListener("Draw2D", "gui_draw", function()
		local pos = window.GetMousePosition()
		gui.mouse_pos = pos

		if gui.DraggingObject and gui.DraggingObject:IsValid() then
			local delta = pos - gui.DragMouseStart
			gui.DraggingObject:SetPosition(gui.DragObjectStart + delta)
		end

		local hovered = gui.GetHoveredObject(pos)

		if hovered and hovered:IsValid() then
			local cursor = hovered:GetCursor()

			if hovered.GreyedOut then cursor = "no" end

			if gui.active_cursor ~= cursor then
				window.SetCursor(cursor)
				gui.active_cursor = cursor
			end
		end

		if gui.Root and gui.Root:IsValid() then gui.Root:Draw() end
	end)

	event.AddListener("KeyInput", "gui", function(key, press)
		local panel = gui.focus_panel

		if panel:IsValid() then
			panel:KeyInput(key, press)
			return true
		end
	end)

	event.AddListener("CharInput", "gui", function(char)
		local panel = gui.focus_panel

		if panel:IsValid() then
			panel:CharInput(char)
			return true
		end
	end)

	event.AddListener("MouseInput", "gui_mouse", function(button, press)
		local pos = window.GetMousePosition()
		gui.mouse_pos = pos

		if button == "button_1" then
			if press then
				local hovered = gui.GetHoveredObject(pos)

				if hovered and hovered:GetDragEnabled() then
					gui.DraggingObject = hovered
					gui.DragMouseStart = pos:Copy()
					gui.DragObjectStart = hovered:GetPosition():Copy()
				end
			else
				gui.DraggingObject = nil
			end
		end

		local target

		if press then
			target = gui.GetHoveredObject(pos)
			gui.PressedObjects[button] = target
		else
			target = gui.PressedObjects[button]
			gui.PressedObjects[button] = nil

			if not (target and target:IsValid()) then
				target = gui.GetHoveredObject(pos)
			end
		end

		while target and target:IsValid() do
			local local_pos = target:GlobalToLocal(pos)

			if target:MouseInput(button, press, local_pos) then break end

			target = target:GetParent()
		end
	end)
end

do
	local BasePanel = require("gui.elements.base")
	require("gui.elements.text")
	require("gui.elements.text2")
	require("gui.elements.frame")

	function gui.Create(class_name, parent)
		if class_name == "base" then
			local surf = BasePanel:CreateObject()
			surf:Initialize()

			if parent then parent:AddChild(surf) end

			return surf
		end

		parent = parent or gui.Root
		local type = class_name

		if not type:find("^panel_") then type = "panel_" .. type end

		local surf = prototype.CreateObject(type)
		surf:Initialize()
		parent:AddChild(surf)
		return surf
	end
end

return gui
