local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local MarkupLabel = import("goluwa/render2d/ui/elements/markup_label.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Markup = import("goluwa/render2d/markup.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local timer = import("goluwa/timer.lua")
local utf8 = import("goluwa/string/utf8.lua")
local META = Panel:CreateTemplate("markup_tag_picker")
META.Base = IconButton
META.Icon = "code"
META.Mode = "text"
META:StartStorable()
META:GetSet("Target", nil)
META:GetSet("MenuWidth", 380)
META:GetSet("MenuHeight", 360)
META:EndStorable()

local function draw_stripe(panel)
	if not panel.Striped then return end

	local color = theme.active:GetColor("surface_alt")
	local size = panel.transform:GetSize()
	render2d.SetTexture()
	render2d.SetColor(color.r, color.g, color.b, color.a)
	render2d.DrawRect(0, 0, size.x, size.y)
end

local function on_pick(item)
	item.Picker:insert_tag(item.Entry)
end

function META:insert_tag(entry)
	local target = self.Target
	local editor = target:GetTextPanel().text.editor
	local start, stop = self._selection_start, self._selection_stop

	if start then
		editor.SelectionStart = start
		editor.Cursor = stop
	else
		editor.SelectionStart = nil
		editor.Cursor = self._cursor
	end

	if entry.void then
		editor.SelectionStart = nil
		editor.Cursor = stop or self._cursor
		editor:Insert(entry.open)
	elseif start then
		editor:Insert(entry.open .. editor.Buffer:Sub(start, stop - 1) .. entry.close)
	else
		editor:Insert(entry.open .. entry.close)
		editor.Cursor = editor.Cursor - utf8.length(entry.close)
	end

	timer.Delay(0, function()
		if target:IsValid() then target:RequestTextFocus() end
	end)
end

function META:open_menu()
	local editor = self.Target:GetTextPanel().text.editor
	self._selection_start, self._selection_stop = editor:GetSelection()
	self._cursor = editor.Cursor
	local column = Column{
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = "none",
		},
	}

	for index, entry in ipairs(Markup.GetTagList()) do
		column:AddChild(
			Panel.New{
				transform = true,
				visual = true,
				Striped = index % 2 == 0,
				layout = {
					Direction = "y",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
				},
				OnDraw = draw_stripe,
			}{
				MenuItem{
					Picker = self,
					Entry = entry,
					Text = "",
					Tooltip = entry.description,
					Padding = "XS",
					OnClick = on_pick,
					TextLayout = {GrowWidth = 0, FitWidth = true, FitHeight = true},
					layout = {ChildGap = "none"},
				}{
					MarkupLabel{Text = entry.example, ContentMinHeight = entry.height or 0, IgnoreMouseInput = true},
				},
			}
		)
	end

	local scroll = ScrollablePanel{
		ScrollX = false,
		ScrollY = true,
		ScrollbarShiftMode = "auto_shift",
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(0, self.MenuHeight),
			MaxSize = Vec2(0, self.MenuHeight),
		},
	}
	scroll:AddChild(column)
	local menu = MenuContainer{
		Name = "markup_tag_menu",
		layout = {
			MinSize = Vec2(self.MenuWidth, 0),
			MaxSize = Vec2(self.MenuWidth, 0),
		},
	}{scroll}
	Panel.OpenContextMenu({Anchor = self, AnchorPlacement = "below_left"}, menu)
end

function META:OnClick()
	self:open_menu()
end

return META:Register()
