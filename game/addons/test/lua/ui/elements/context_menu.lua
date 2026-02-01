local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local lsx = require("ecs.lsx_ecs")
local Frame = runfile("lua/ui/elements/frame.lua")

return function(props)
	local render_state, set_render_state = lsx:UseState(props.Visible and "open" or "closed")
	local ref = lsx:UseRef(nil)

	lsx:UseEffect(
		function()
			if props.Visible then
				set_render_state("opening")
			elseif render_state ~= "closed" then
				set_render_state("closing")
			end
		end,
		{props.Visible}
	)

	lsx:UseAnimate(
		ref,
		{
			var = "DrawScaleOffset",
			to = (render_state == "opening" or render_state == "open") and Vec2(1, 1) or Vec2(1, 0),
			time = 0.2,
			interpolation = "outExpo",
			callback = function()
				if render_state == "closing" then
					set_render_state("closed")
				elseif render_state == "opening" then
					set_render_state("open")
				end
			end,
		},
		{render_state}
	)

	if render_state == "closed" then return nil end

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
			ref = ref,
			Pivot = Vec2(0, 0),
			DrawScaleOffset = render_state == "opening" and Vec2(1, 0) or nil,
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
