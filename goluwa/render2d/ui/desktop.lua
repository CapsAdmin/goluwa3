local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Dock = import("goluwa/render2d/ui/widgets/dock.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local system = import("goluwa/system.lua")
local desktop = {}
local programs = {}
local order = {}
local menus = {}
local root_dirty = false
local root = NULL
local menu_bar = NULL
local shown = false

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

-- a program is centered unless it sets Positioned. An Interactive program (the editor) works with the world while it is open, so it asks for the mouse itself, opening it hides the desktop and it ignores the desktop showing or hiding. OnShown and OnHidden of a program get its window when the desktop shows or hides while the program is open
function desktop.RegisterProgram(program)
	if not programs[program.Name] then order[#order + 1] = program.Name end

	program.Window = NULL
	program.Opened = false
	program.OnOpen = program.OnOpen or noop
	program.OnEscape = program.OnEscape or not_consumed
	program.OnShown = program.OnShown or (program.Interactive and noop or default_shown)
	program.OnHidden = program.OnHidden or (program.Interactive and noop or default_hidden)
	programs[program.Name] = program
	root_dirty = true
end

-- adds a menu to the menu bar, {Text, Items = a function returning MenuItems}
function desktop.RegisterMenu(menu)
	menus[#menus + 1] = menu
	root_dirty = true
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

local function build_root()
	root_dirty = false
	local buttons = {}

	for i, name in ipairs(order) do
		buttons[i] = Button{
			Text = name,
			Icon = programs[name].Icon,
			Mode = "filled",
			OnClick = function()
				desktop.Open(name)
			end,
		}
	end

	local menu_items = {
				{
					Text = "ENGINE",
					Items = function()
						return {
							MenuItem{
								Text = "exit",
								Icon = "power",
								OnClick = function()
									system.ShutDown(0)
								end,
							},
						}
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
						}
					end,
				},
			
	}

	for _, menu in ipairs(menus) do
		menu_items[#menu_items + 1] = menu
	end

	root = Panel.New{
		Parent = Panel.World,
		transform = true,
		layout = {Direction = "y", AlignmentX = "stretch"},
		visual = true,
		mouse_input = {RequestMouse = true},
		OnDraw = function(self)
			if not self.dimmed then return end

			local size = self.transform:GetSize()
			render2d.SetTexture(nil)
			render2d.SetColor(0, 0, 0, 0.35)
			render2d.DrawRect(0, 0, size.x, size.y)
		end,
	}{
		Frame{layout = {GrowWidth = 1, FitHeight = true, AlignmentX = "stretch"}}{MenuBar{
			Ref = function(self)
				menu_bar = self
			end,
			MenuKey = "DesktopMenuBarContextMenu",
			Items = menu_items,
			layout = {GrowWidth = 1},
		}},
		Row{layout = {ChildGap = "S", Padding = "M"}}(buttons),
	}
end

function desktop.Show(dimmed)
	if shown then return end

	shown = true

	if root:IsValid() and root_dirty then root:Remove() end

	if not root:IsValid() then build_root() end

	root.dimmed = dimmed
	render2d.SetHudHidden("desktop", true)
	Dock.GetInstance():SetPinned(true)

	root.transform:SetSize(Panel.World.transform:GetSize())
	root.visual:SetVisible(true)
	root:SendToBack()

	for _, name in ipairs(order) do
		if desktop.IsOpen(name) then programs[name].OnShown(programs[name].Window) end
	end
end

function desktop.Hide()
	if not shown then return end

	shown = false
	menu_bar:CloseMenu()
	root.visual:SetVisible(false)
	render2d.SetHudHidden("desktop", false)
	Dock.GetInstance():SetPinned(false)

	for _, name in ipairs(order) do
		if desktop.IsOpen(name) then programs[name].OnHidden(programs[name].Window) end
	end
end

function desktop.IsEditing()
	local focused = objects.GetFocusedObject()

	while focused and focused:IsValid() do
		for _, name in ipairs(order) do
			if focused == programs[name].Window then return true end
		end

		focused = focused:GetParent()
	end

	return false
end

-- the c key: held shows the program buttons, a press while the desktop is up hides it, release hides it unless a program has focus
function desktop.Hold()
	if shown then desktop.Hide() else desktop.Show(false) end
end

function desktop.Release()
	if not desktop.IsEditing() then desktop.Hide() end
end

-- the escape key: toggles the desktop with its dimmed backdrop
function desktop.ToggleShown()
	for _, name in ipairs(order) do
		if desktop.IsOpen(name) and programs[name].OnEscape(programs[name].Window) then return end
	end

	if shown then desktop.Hide() else desktop.Show(true) end
end

return desktop
