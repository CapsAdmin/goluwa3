local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local lsx = require("ecs.lsx_ecs")
local Frame = runfile("lua/ui/elements/frame.lua")

return function(props)
	if not props.Visible then return nil end

	local children = {}
	for i = 1, #props do
		table.insert(children, props[i])
	end

	return lsx:Panel({
		Name = "ContextMenuContainer",
		Size = Vec2(render2d.GetSize()),
		Color = Color(0, 0, 0, 0), -- Invisible background to catch clicks
		OnMouseInput = function(self, button, press)
			if press and button == "button_1" then
				if props.OnClose then props.OnClose() end
				return true
			end
		end,
		Frame({
			Name = "ContextMenu",
			Position = props.Position or Vec2(100, 100),
			Size = props.Size or Vec2(200, 0),
			Layout = {"SizeToChildrenHeight"},
			Stack = true,
			StackDown = true,
			Resizable = false,
			DragEnabled = false,
			Padding = Rect(5, 5, 5, 5),
			-- Stop clicks on the menu from closing it via the background panel
			OnMouseInput = function(self, button, press)
				return true
			end,
			unpack(children)
		})
	})
end
