local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Dock = import("goluwa/render2d/ui/widgets/dock.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local LoadWindow = import("goluwa/render2d/ui/load_window.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local desktop = {}
local programs = {}
local order = {}
local menus = {}
local root = NULL
local menu_bar = NULL
local shown = false
local dimmed = false
local backdrops = {}
local backdrop_order = {}
local active_backdrop
pvars.StartGroup("Engine", "Desktop", {prefix = "desktop_"})
pvars.Setup2{
	key = "desktop_backdrop",
	default = "dim",
	help = "what the desktop shows behind its programs when it is opened with escape, a registered backdrop (dim is the dimmed scene)",
}
pvars.EndGroup()

local function default_shown(window)
	if window:IsMinimized() then return end

	window.visual:SetVisible(true)
	window:SetHud(false)
end

local function default_hidden(window)
	if window.Pinned then window:SetHud(true) else window.visual:SetVisible(false) end
end

local function noop() end

local function not_consumed() end

function desktop.RegisterProgram(program)
	if not programs[program.Name] then order[#order + 1] = program.Name end

	program.Window = NULL
	program.Opened = false
	program.OnOpen = program.OnOpen or noop
	program.OnEscape = program.OnEscape or not_consumed
	program.OnShown = program.OnShown or (program.Interactive and noop or default_shown)
	program.OnHidden = program.OnHidden or (program.Interactive and noop or default_hidden)
	programs[program.Name] = program
	event.Call("DesktopChanged")
end

function desktop.GetPrograms()
	return list.map(order, |name| -> programs[name])
end

function desktop.RegisterMenu(menu)
	menus[#menus + 1] = menu
	event.Call("DesktopChanged")
end

function desktop.RegisterBackdrop(backdrop)
	if not backdrops[backdrop.Name] then backdrop_order[#backdrop_order + 1] = backdrop.Name end

	backdrop.OnActivate = backdrop.OnActivate or noop
	backdrop.OnDeactivate = backdrop.OnDeactivate or noop
	backdrops[backdrop.Name] = backdrop
end

desktop.RegisterBackdrop{
	Name = "dim",
	OnDraw = function(root, width, height)
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.35)
		render2d.DrawRect(0, 0, width, height)
	end,
}

function desktop.GetBackdrops()
	return backdrop_order
end

function desktop.GetBackdrop()
	local name = pvars.Get("desktop_backdrop")

	return backdrops[name] and name or "dim"
end

local function update_backdrop()
	local wanted = shown and dimmed and backdrops[desktop.GetBackdrop()] or nil

	if wanted == active_backdrop then return end

	if active_backdrop then active_backdrop.OnDeactivate() end

	active_backdrop = wanted

	if wanted then wanted.OnActivate() end
end

function desktop.SetBackdrop(name)
	assert(backdrops[name], "unknown desktop backdrop " .. tostring(name))
	pvars.Set("desktop_backdrop", name)
	update_backdrop()
end

function desktop.IsBackdrop(panel)
	return panel == root
end

function desktop.IsShown()
	return shown
end

function desktop.GetProgram(name)
	return programs[name]
end

function desktop.IsOpen(name)
	local program = programs[name]
	return program.Opened and program.Window:IsValid()
end

function desktop.Open(name)
	local program = programs[name]

	if not program.Window:IsValid() then
		program.Window = program.Create()
		program.Window:SetParent(Panel.World)
		program.Window:SetPinned(program.Pinned == true)

		if program.Window.Pinnable then program.Window:RefreshPinIcon() end

		if not program.Positioned then
			local size = Panel.World.transform:GetSize()
			local window_size = program.Window.transform:GetSize()
			program.Window.transform:SetPosition((size - window_size) / 2)
		end
	end

	program.Opened = true

	if not shown and program.Window.Pinnable then
		program.Window:SetPinned(true)
		program.Window:RefreshPinIcon()
	end

	if program.Window:IsMinimized() then
		program.Window:Restore()
	else
		program.Window.visual:SetVisible(true)
	end

	program.Window:BringToFront()

	if shown then program.OnShown(program.Window) else program.OnHidden(program.Window) end

	if program.Interactive then desktop.Hide() end

	program.OnOpen()
end

function desktop.Close(name)
	local program = programs[name]
	program.Opened = false

	if program.Window:IsValid() then
		if program.Window:IsMinimized() then program.Window:Restore() end

		program.Window.visual:SetVisible(false)
	end
end

function desktop.Toggle(name)
	if desktop.IsOpen(name) then desktop.Close(name) else desktop.Open(name) end
end

local function build_menu_items()
	local menu_items = {
		{
			Text = "ENGINE",
			Items = function()
				local items = {}

				if RENDER_3D then
					items[#items + 1] = MenuItem{
						Text = "load",
						Icon = "folder",
						OnClick = function()
							desktop.Open("Load")
						end,
					}
				end

				items[#items + 1] = MenuItem{
					Text = "exit",
					Icon = "power",
					OnClick = function()
						system.ShutDown(0)
					end,
				}

				return items
			end,
		},
		{
			Text = "OPTIONS",
			Items = function()
				return {
					MenuItem{
						Text = "Theme",
						Icon = "palette",
						Items = function()
							local items = {}

							for _, label in ipairs(theme.GetAvailable()) do
								if label == theme.active:GetName() then label = label .. " (active)" end

								items[#items + 1] = MenuItem{
									Text = label,
									OnClick = function()
										if label == theme.active:GetName() then return end

										theme.LoadTheme(label)
									end,
								}
							end

							return items
						end,
					},
					MenuItem{
						Text = "Layout debugger" .. (Panel.World.ui_debug:IsLayoutDebugEnabled() and " (on)" or " (off)"),
						Icon = "layers",
						OnClick = function()
							Panel.World.ui_debug:SetLayoutDebug(not Panel.World.ui_debug:IsLayoutDebugEnabled())
						end,
					},
					MenuItem{
						Text = "Backdrop",
						Icon = "material",
						Items = function()
							local items = {}
							local active = desktop.GetBackdrop()

							for _, name in ipairs(desktop.GetBackdrops()) do
								items[#items + 1] = MenuItem{
									Text = name == active and name .. " (active)" or name,
									OnClick = function()
										desktop.SetBackdrop(name)
									end,
								}
							end

							return items
						end,
					},
				}
			end,
		},
	}

	for _, menu in ipairs(menus) do
		menu_items[#menu_items + 1] = menu
	end

	return menu_items
end

local function draw_backdrop(self)
	if not active_backdrop then return end

	local size = self.transform:GetSize()
	active_backdrop.OnDraw(self, size.x, size.y)
end

local DesktopView = react.Component(|| -> do
	local version, set_version = react.UseState(0)
	local menu_items = react.UseMemo(build_menu_items, {version})

	react.UseEvent("DesktopChanged", || -> set_version(|current| -> current + 1))

	return ui.Panel{
		Ref = |entity| -> do root = entity ?? NULL end,
		transform = true,
		layout = {Direction = "y", AlignmentX = "stretch"},
		visual = true,
		mouse_input = {RequestMouse = true},
		OnDraw = draw_backdrop,
	}{
		ui.Frame{layout = {GrowWidth = 1, FitHeight = true, AlignmentX = "stretch"}}{
			ui.MenuBar{
				Ref = |entity| -> do menu_bar = entity ?? NULL end,
				MenuKey = "DesktopMenuBarContextMenu",
				Items = menu_items,
				layout = {GrowWidth = 1},
			},
		},
		ui.Row{layout = {ChildGap = "S", Padding = "M"}}{
			list.map(
				list.filter(order, |name| -> not programs[name].NoButton),
				|name| -> ui.Button{
					Key = name,
					Text = name,
					Icon = programs[name].Icon,
					Mode = "filled",
					OnClick = || -> desktop.Open(name),
				}
			),
		},
	}
end)

function desktop.Show(is_dimmed)
	if shown then return end

	shown = true

	if not root:IsValid() then react.Mount(DesktopView{}, Panel.World) end

	dimmed = is_dimmed
	render2d.SetHudHidden("desktop", true)
	Dock.GetInstance():SetPinned(true)

	root.transform:SetSize(Panel.World.transform:GetSize())
	root.visual:SetVisible(true)
	root:SendToBack()
	update_backdrop()

	for _, name in ipairs(order) do
		if desktop.IsOpen(name) then programs[name].OnShown(programs[name].Window) end
	end
end

function desktop.Hide()
	if not shown then return end

	shown = false
	update_backdrop()
	menu_bar:CloseMenu()
	root.visual:SetVisible(false)
	render2d.SetHudHidden("desktop", false)
	Dock.GetInstance():SetPinned(false)

	for _, name in ipairs(order) do
		if desktop.IsOpen(name) then programs[name].OnHidden(programs[name].Window) end
	end
end

desktop.RegisterProgram{
	Name = "Load",
	Icon = "folder",
	NoButton = true,
	Create = function()
		return LoadWindow{
			OnLoad = function()
				desktop.Close("Load")
				desktop.Hide()
			end,
		}
	end,
}

function desktop.IsEditing()
	local focused = objects.GetFocusedObject()

	if focused and focused:IsValid() and focused.Scrollable then return false end

	while focused and focused:IsValid() do
		for _, name in ipairs(order) do
			if focused == programs[name].Window then return true end
		end

		focused = focused:GetParent()
	end

	return false
end

function desktop.Hold()
	if shown then desktop.Hide() else desktop.Show(false) end
end

function desktop.Release()
	if not desktop.IsEditing() then desktop.Hide() end
end

function desktop.ToggleShown()
	for _, name in ipairs(order) do
		if desktop.IsOpen(name) and programs[name].OnEscape(programs[name].Window) then return end
	end

	if shown then desktop.Hide() else desktop.Show(true) end
end

return desktop
