local event = require("event")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local gui = library()
package.loaded["gui.gui"] = gui
local BaseSurface = require("gui.base_surface")
require("gui.elements.text")

function gui.CreateBasePanel()
	return BaseSurface:CreateObject()
end

do
	local function check(panel, mouse_pos)
		if not panel.Visible then return nil end

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
	gui.Root = gui.CreateBasePanel()
	gui.Root:SetName("Root")
	local w, h = render2d.GetSize()

	if w then gui.Root:SetSize(Vec2(w, h)) end

	event.AddListener("WindowFramebufferResized", "gui_root", function(wnd, size)
		if gui.Root and gui.Root:IsValid() then
			gui.Root:SetSize(Vec2(size.w, size.h))
		end
	end)

	event.AddListener("Draw2D", "gui_draw", function()
		if gui.DraggingObject and gui.DraggingObject:IsValid() then
			local pos = window.GetMousePosition()
			local delta = pos - gui.DragMouseStart
			gui.DraggingObject:SetPosition(gui.DragObjectStart + delta)
		end

		if gui.Root and gui.Root:IsValid() then gui.Root:Draw() end
	end)

	event.AddListener("MouseInput", "gui_mouse", function(button, press)
		local pos = window.GetMousePosition()

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

		local hovered = gui.GetHoveredObject(pos)

		while hovered and hovered:IsValid() do
			local local_pos = hovered:GlobalToLocal(pos)

			if hovered:OnMouseInput(button, press, local_pos) then break end

			hovered = hovered:GetParent()
		end
	end)
end

function gui.Create(class_name, parent)
	parent = parent or gui.Root
	local obj = prototype.CreateDerivedObject("surface", class_name)
	parent:AddChild(obj)
	return obj
end

return gui
