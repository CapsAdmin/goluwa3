local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local timer = import("goluwa/timer.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("dropdown")
META.Base = Button
META.Mode = "outline"
META.Text = "Select..."
META.CMP.layout = {
	Direction = "x",
	FitWidth = false,
	FitHeight = true,
	AlignmentY = "center",
	GrowWidth = 1,
}
META:StartStorable()
META:GetSet("Options", nil)
META:GetSet("Value", nil)
META:GetSet("Searchable", false)
META:GetSet("SearchThreshold", 300)
META:GetSet("ScrollThreshold", nil)
META:GetSet("SearchHint", "Search")
META:GetSet("EmptySearchText", "No matches")
META:GetSet("ItemPadding", nil)
META:EndStorable()

function META.OnSelect(value, text, index, dropdown) end

local function get_option_text(option)
	if type(option) == "table" then
		return tostring(option.Text or option.Label or option.Value)
	end

	return tostring(option)
end

local function get_option_value(option)
	if type(option) == "table" then return option.Value end

	return option
end

local function find_option_text(options, value)
	if value == nil then return nil end

	for _, option in ipairs(options) do
		if get_option_value(option) == value then return get_option_text(option) end
	end
end

local function on_option_click(item)
	item.Dropdown:select_option(item.OptionIndex)
end

local function on_search_changed(text_edit, text)
	text_edit.Dropdown:rebuild_results(text:lower())
end

local function get_indicator_fraction(dropdown)
	return dropdown._indicator_fraction
end

local function set_indicator_fraction(fraction, dropdown)
	dropdown:set_indicator(fraction)
end

local function on_menu_closing(context_menu)
	local dropdown = context_menu.SourceDropdown

	if dropdown:IsValid() then dropdown:animate_indicator(0) end
end

local function on_menu_close(context_menu)
	local dropdown = context_menu.SourceDropdown

	if dropdown:IsValid() then dropdown:set_indicator(0) end

	context_menu:Remove()
end

function META.PropDefaults(_, props)
	return {
		Options = {},
		AlignX = 0,
		TextLayout = {GrowWidth = 1, FitHeight = true},
	}
end

function META:OnCreate()
	self.Text = find_option_text(self.Options, self.Value) or self.Text
	META.BaseClass.OnCreate(self)
	self._indicator_fraction = 0
	self._suppress_next_open = false
	self._indicator = Icon{
		Parent = self,
		IsInternal = true,
		Name = "dropdown_indicator",
		Icon = "disclosure",
		Size = Vec2() + theme.active:ResolveFontSize(self.FontSize),
	}
end

function META:OnThemeChanged()
	self._indicator.transform:SetSize(Vec2() + theme.active:ResolveFontSize(self.FontSize))
end

function META:SetValue(value)
	self.Value = value

	if not self.label then return self end

	local text = find_option_text(self.Options, value)

	if text then self:SetText(text) end

	return self
end

function META:SetOptions(options)
	self.Options = options
	self:SetValue(self.Value)
	return self
end

function META:set_indicator(fraction)
	self._indicator_fraction = fraction
	self._indicator:SetOpenFraction(fraction)
end

function META:animate_indicator(fraction)
	self.animation:Animate{
		id = "dropdown_indicator_open",
		get = get_indicator_fraction,
		set = set_indicator_fraction,
		to = fraction,
		time = 0.2,
		interpolation = "outExpo",
	}
end

function META:select_option(index)
	local option = self.Options[index]
	local text = get_option_text(option)
	local value = get_option_value(option)
	self._suppress_next_open = true

	timer.Delay(0, function()
		self._suppress_next_open = false
	end)

	Panel.CloseContextMenu()
	self:SetValue(value)
	self.OnSelect(value, text, index, self)
end

function META:create_option_item(index)
	local option = self.Options[index]
	return MenuItem{
		Dropdown = self,
		OptionIndex = index,
		Text = get_option_text(option),
		Padding = self.ItemPadding,
		Selected = self.Value == get_option_value(option),
		Font = self.Font,
		OnClick = on_option_click,
	}
end

function META:rebuild_results(query)
	local column = self._results_column
	column:RemoveChildren()
	local has_matches = false

	for index, option in ipairs(self.Options) do
		if query == "" or get_option_text(option):lower():find(query, 1, true) then
			column:AddChild(self:create_option_item(index))
			has_matches = true
		end
	end

	if self._search_edit and not has_matches then
		Text{
			Parent = column,
			Text = self.EmptySearchText,
			Color = "text_disabled",
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				Padding = Rect(
					theme.active:GetPadding("M"),
					theme.active:GetPadding("S"),
					theme.active:GetPadding("M"),
					theme.active:GetPadding("S")
				),
			},
		}
	end

	self._results_panel:GetViewport().layout:UpdateLayout()
end

function META:build_scroll_menu(use_search, scroll_threshold)
	local search_height = theme.active:GetInputHeight(self.FontSize)
	local search_gap = theme.active:GetPadding("M")
	local _, dropdown_y = self.transform:GetWorldMatrix():GetTranslation()
	local world_height = Panel.World.transform:GetHeight()
	local available_below = math.max(dropdown_y, world_height - (dropdown_y + self.transform:GetHeight()))
	local body_height = scroll_threshold

	if use_search then
		search_height = math.min(search_height, math.max(0, available_below - 1))
		search_gap = math.min(search_gap, math.max(0, available_below - search_height - 1))
		body_height = math.max(80, self.SearchThreshold - search_height - search_gap)
	else
		search_height = 0
		search_gap = 0
	end

	body_height = math.max(
		1,
		math.min(body_height, math.max(1, available_below - search_height - search_gap))
	)
	local children = {}

	if use_search then
		self._search_edit = TextEdit{
			Dropdown = self,
			Tooltip = self.SearchHint,
			Text = "",
			Wrap = false,
			ScrollX = false,
			ScrollY = false,
			ScrollbarVisible = false,
			Font = self.Font,
			Size = Vec2(0, search_height),
			MinSize = Vec2(0, search_height),
			MaxSize = Vec2(0, search_height),
			OnTextChanged = on_search_changed,
		}
		children[#children + 1] = self._search_edit
	else
		self._search_edit = nil
	end

	self._results_panel = ScrollablePanel{
		ScrollX = false,
		ScrollY = true,
		ScrollbarShiftMode = "auto_shift",
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(0, body_height),
			MaxSize = Vec2(0, body_height),
		},
	}
	self._results_column = Column{
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = "none",
		},
	}
	self._results_panel:AddChild(self._results_column)
	children[#children + 1] = self._results_panel
	local menu = MenuContainer{
		Name = use_search and "dropdown_search_menu" or "dropdown_scroll_menu",
		layout = {ChildGap = search_gap},
	}(children)
	self:rebuild_results("")
	return menu
end

function META:open_menu()
	if self._suppress_next_open then
		self._suppress_next_open = false
		return
	end

	local options = self.Options
	local item_height = theme.active:ResolveFontSize(self.FontSize) + theme.active:GetPadding("M") * 2
	local scroll_threshold = self.ScrollThreshold or self.SearchThreshold
	local use_scroll = #options * item_height > scroll_threshold
	local use_search = use_scroll and self.Searchable
	local menu_items = {}

	if use_scroll then
		menu_items[1] = self:build_scroll_menu(use_search, scroll_threshold)
	else
		for index = 1, #options do
			menu_items[index] = self:create_option_item(index)
		end
	end

	self._menu = Panel.OpenContextMenu(
		{
			Anchor = self,
			AnchorPlacement = "below_left",
			SourceDropdown = self,
			OnClosing = on_menu_closing,
			OnClose = on_menu_close,
		},
		unpack(menu_items)
	)
	self:AddGlobalEvent("Update")
	self:animate_indicator(1)

	if use_search then
		timer.Delay(0, function()
			if self._search_edit and self._search_edit:IsValid() then
				self._search_edit:RequestTextFocus()
			end
		end)
	end
end

function META:OnUpdate()
	if not self._menu or not self._menu:IsValid() then
		self._menu = nil
		self:RemoveEvent("Update")
		return
	end

	local width = self.transform:GetWidth()
	local root = self._menu:GetRootMenu()
	root.layout:SetMinSize(Vec2(width, 0))
	root.layout:SetMaxSize(Vec2(width, 0))

	if self._results_panel and self._results_panel:IsValid() then
		self._results_panel:GetViewport().layout:UpdateLayout()
	end
end

function META:OnClick()
	self:open_menu()
end

return META:Register()
