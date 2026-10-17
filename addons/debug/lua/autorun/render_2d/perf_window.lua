local input = import("goluwa/input.lua")
local commands = import("goluwa/cli/commands.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Tabs = import("goluwa/render2d/ui/widgets/tabs.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local perf = import("lua/perf.lua")
local WIDTH, HEIGHT = 700, 580
local tabs

desktop.RegisterProgram{
	Name = "Perf",
	Icon = "layout",
	Pinned = true,
	Create = function()
		local pages = {}

		for i, tab in ipairs(perf.GetTabs()) do
			pages[i] = Column{Tab = tab.name, layout = {GrowWidth = 1, AlignmentX = "center"}}{tab.create()}
		end

		return Window{
			Title = "PERF",
			Pinnable = true,
			Minimizable = false,
			Maximizable = false,
			Size = Vec2(WIDTH, HEIGHT),
			MinSize = Vec2(WIDTH, HEIGHT),
			OnHudChanged = function(_, hud)
				tabs:SetBarHidden(hud)
			end,
		}{
			Tabs{
				Ref = function(self)
					tabs = self
				end,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}(pages),
		}
	end,
}

commands.Add("perf=string|nil", function(tab)
	if not tab then
		desktop.Toggle("Perf")
		return
	end

	desktop.Open("Perf")
	tabs:SetValue(tab:upper())
end)

input.Bind("h", "perf")
