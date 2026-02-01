local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("ecs.lsx_ecs")
local ecs = require("ecs.ecs")
local Ang3 = require("structs.ang3")
local window = require("window")
local event = require("event")
local Button = runfile("lua/ui/elements/button.lua")
local Frame = runfile("lua/ui/elements/frame.lua")
local Text = runfile("lua/ui/elements/text.lua")
local MenuOverlay = runfile("lua/ui/menu_overlay.lua")
local MenuButton = runfile("lua/ui/elements/menu_button.lua")

local App = function()
	local visible, set_visible = lsx:UseState(false)

	lsx:UseEffect(
		function()
			return event.AddListener(
				"KeyInput",
				"menu_toggle_" .. tostring({}),
				function(key, press)
					if not press then return end
					if key == "escape" then
						set_visible(not visible)
						return false -- prevent other handlers
					end
				end
			)
		end,
		{visible}
	)

	lsx:UseEffect(
		function()
			if window.current then
				window.current:SetMouseTrapped(not visible)
			end
		end,
		{visible}
	)

	return lsx:Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			visible and MenuOverlay() or nil,
			--[[Frame(
				{
					Layout = {"CenterSimple", "SizeToChildrenHeight"},
					Resizable = true,
					Size = Vec2(350, 200),
					Padding = Rect() + 10,
					MenuButton({
						Text = "Abilities",
					}),
					MenuButton({
						Text = "Spells",
					}),
					MenuButton({
						Text = "Items",
					}),
					MenuButton({
						Text = "Limit Breaks",
					}),
				}
			),
			]]
		}
	)
end
require("ecs.ecs").Clear2DWorld()
lsx:Mount(App)
