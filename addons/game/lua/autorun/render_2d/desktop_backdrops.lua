local desktop = import("goluwa/render2d/ui/desktop.lua")
local zsnes = import("addons/game/lua/zsnes_screensavers.lua")

for i, name in ipairs(zsnes.EFFECTS) do
	desktop.RegisterBackdrop{
		Name = "zsnes " .. name,
		OnActivate = function()
			zsnes.Start(i)
		end,
		OnDeactivate = zsnes.Stop,
		OnDraw = function(root, width, height)
			zsnes.Draw(0, 0, width, height)
		end,
	}
end
