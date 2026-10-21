local input = import("goluwa/input.lua")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local perf = import("lua/perf.lua")
local WIDTH, HEIGHT = 700, 580
local PerfView = react.Component(
	|props|-> do
		local tabs = react.UseMemo(perf.GetTabs, {})
		local hud, set_hud = react.UseState(false)
		local shown, set_shown = react.UseState(true)
		local active, set_active = react.UseState(||->tabs[1].name)
		react.UseEvent("PerfTab", set_active)
		return ui.Window{
			Title = "PERF",
			Pinnable = true,
			Minimizable = false,
			Maximizable = false,
			Size = Vec2(WIDTH, HEIGHT),
			MinSize = Vec2(WIDTH, HEIGHT),
			OnHudChanged = |_,value|->set_hud(value),
			OnVisibilityChanged = |_,visible|->set_shown(visible),
		}{
			ui.Tabs{
				Value = active,
				OnChange = set_active,
				BarHidden = hud,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				list.map(
					tabs,
					|tab|->ui.Column{Key = tab.name, Tab = tab.name, layout = {GrowWidth = 1, AlignmentX = "center"}}{
						shown and
						active == tab.name and
						tab.view{},
					}
				),
			},
		}
	end
)
desktop.RegisterProgram{
	Name = "Perf",
	Icon = "layout",
	Pinned = true,
	Create = function()
		return react.Mount(PerfView{}, Panel.World):GetEntity()
	end,
}

commands.Add("perf=string|nil", function(tab)
	if not tab then
		desktop.Toggle("Perf")
		return
	end

	desktop.Open("Perf")
	event.Call("PerfTab", tab:upper())
end)

input.Bind("h", "perf")
