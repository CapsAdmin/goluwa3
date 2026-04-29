local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Column = import("lua/ui/elements/column.lua")
local Text = import("lua/ui/elements/text.lua")
local TextEdit = import("lua/ui/elements/text_edit.lua")
local ScrollablePanel = import("lua/ui/elements/scrollable_panel.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local MenuItem = import("lua/ui/elements/context_menu_item.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local options = props.Options or {}
	local on_select = props.OnSelect
	local label_ent
	local dropdown
	local suppress_next_open = false
	local selected_text = props.Text or "Select..."
	local search_enabled = props.Searchable == true or props.EnableSearch == true
	local search_threshold = props.SearchThreshold or 300
	local search_input_height = props.SearchInputHeight or 34
	local search_gap = props.SearchGap or theme.GetPadding("XS")
	local scroll_threshold = props.ScrollThreshold or search_threshold
	local search_body_height = math.max(80, search_threshold - search_input_height - search_gap)
	local estimated_item_height = theme.GetFontSize(props.FontSize) + theme.GetPadding("M") * 2

	for _, opt in ipairs(options) do
		local text = type(opt) == "table" and opt.Text or tostring(opt)
		local val = type(opt) == "table" and opt.Value or opt

		if props.Value ~= nil and val == props.Value then
			selected_text = text

			break
		end
	end

	local function select_option(text, val, index)
		suppress_next_open = true

		timer.Delay(0, function()
			suppress_next_open = false
		end)

		local world_panel = Panel.World
		local active = world_panel:GetKeyed("ActiveContextMenu")

		if active and active:IsValid() then active:Remove() end

		selected_text = text

		if label_ent and label_ent:IsValid() and not props.GetText then
			label_ent.text:SetText(selected_text)
		end

		if on_select then on_select(val, text, index) end
	end

	local function create_option_item(text, val, index, menu_props)
		menu_props = menu_props or {}
		return MenuItem{
			Text = text,
			Size = menu_props.Size,
			layout = menu_props.layout,
			Clipping = menu_props.Clipping,
			DisableTextCulling = menu_props.DisableTextCulling,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			OnClick = function()
				select_option(text, val, index)
			end,
		}
	end

	local function create_empty_results_item()
		return Panel.New{
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
				Padding = "M",
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
			gui_element = true,
		}{
			Text{
				Text = props.EmptySearchText or "No matches",
				IgnoreMouseInput = true,
				Color = "text_disabled",
				layout = {
					GrowWidth = 1,
					FitHeight = true,
				},
			},
		}
	end

	local function matches_search(text, query)
		if query == "" then return true end

		return tostring(text or ""):lower():find(query, 1, true) ~= nil
	end

	local function open_menu(self)
		local world_panel = Panel.World

		if suppress_next_open then
			suppress_next_open = false
			return
		end

		local active = world_panel:GetKeyed("ActiveContextMenu")

		if active and active:IsValid() then
			if active.SourceDropdown == dropdown then
				active:Remove()
				return
			end

			active:Remove()
		end

		local menu_items = {}
		local custom_children = {}
		local search_edit

		for _, child in ipairs(self:GetChildren()) do
			if not child.IsInternal then table.insert(custom_children, child) end
		end

		local estimated_content_height = (#options + #custom_children) * estimated_item_height
		local use_scroll = estimated_content_height > scroll_threshold
		local use_search = use_scroll and search_enabled

		for i, opt in ipairs(options) do
			local text = type(opt) == "table" and opt.Text or tostring(opt)
			local val = type(opt) == "table" and opt.Value or opt

			if not use_scroll then
				table.insert(menu_items, create_option_item(text, val, i))
			end
		end

		if use_scroll then
			local search_query = ""
			local results_panel
			local results_column
			local body_height = use_search and search_body_height or scroll_threshold
			local composite_children = {}
			local dropdown_width = dropdown and dropdown.transform and dropdown.transform:GetSize().x or 0

			if dropdown_width <= 0 then dropdown_width = 220 end

			local function rebuild_results()
				if not results_column or not results_column:IsValid() then return end

				results_column:RemoveChildren()
				local has_matches = false

				for i, opt in ipairs(options) do
					local text = type(opt) == "table" and opt.Text or tostring(opt)
					local val = type(opt) == "table" and opt.Value or opt

					if not use_search or matches_search(text, search_query) then
						results_column:AddChild(
							create_option_item(
								text,
								val,
								i,
								{
									Size = Vec2(dropdown_width, estimated_item_height),
									layout = {
										MinSize = Vec2(dropdown_width, estimated_item_height),
										MaxSize = Vec2(dropdown_width, estimated_item_height),
									},
									Clipping = false,
									DisableTextCulling = true,
								}
							)
						)
						has_matches = true
					end
				end

				for _, child in ipairs(custom_children) do
					results_column:AddChild(child)
				end

				if use_search and not has_matches then
					results_column:AddChild(create_empty_results_item())
				end

				if results_panel and results_panel:IsValid() then
					local viewport = results_panel:GetViewport()

					if viewport and viewport:IsValid() and viewport.layout then
						viewport.layout:UpdateLayout()
					end
				end
			end

			if use_search then
				composite_children[#composite_children + 1] = TextEdit{
					Ref = function(ent)
						search_edit = ent
					end,
					Tooltip = props.SearchTooltip or "Search",
					Text = "",
					Editable = true,
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					ScrollBarVisible = false,
					PanelColor = props.SearchPanelColor or "surface_alt",
					BackgroundColor = props.SearchBackgroundColor or "surface",
					TextColor = props.TextColor or "text",
					SelectionColor = props.SelectionColor or theme.GetColor("text_selection"),
					Font = props.Font,
					FontName = props.FontName,
					FontSize = props.FontSize,
					Size = Vec2(0, search_input_height),
					MinSize = Vec2(0, search_input_height),
					MaxSize = Vec2(0, search_input_height),
					OnTextChanged = function(text)
						search_query = tostring(text or ""):lower()
						rebuild_results()
					end,
					layout = {
						GrowWidth = 1,
					},
				}
			end

			composite_children[#composite_children + 1] = ScrollablePanel{
				Ref = function(ent)
					results_panel = ent
				end,
				Color = "invisible",
				CaptureWheelAtExtents = true,
				ScrollX = false,
				ScrollY = true,
				ScrollBarVisible = true,
				ScrollBarAutoHide = true,
				ScrollBarContentShiftMode = "auto_shift",
				ScrollBarColor = props.ScrollBarColor or "scrollbar",
				ScrollBarTrackColor = props.ScrollBarTrackColor or "scrollbar_track",
				Padding = Rect(0, 0, 0, 0),
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, body_height),
					MaxSize = Vec2(0, body_height),
				},
			}{
				Column{
					Ref = function(ent)
						results_column = ent
					end,
					layout = {
						Direction = "y",
						GrowWidth = 1,
						FitHeight = true,
						AlignmentX = "stretch",
					},
				},
			}
			menu_items[1] = Panel.New{
				Name = use_search and "DropdownSearchMenu" or "DropdownScrollMenu",
				OnSetProperty = theme.OnSetProperty,
				layout = {
					Direction = "y",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = search_gap,
				},
				mouse_input = true,
				gui_element = true,
			}(unpack(composite_children))
			rebuild_results()
		else
			for _, child in ipairs(custom_children) do
				table.insert(menu_items, child)
			end
		end

		local context_menu = ContextMenu{
			Key = "ActiveContextMenu",
			SourceDropdown = dropdown,
			OnClose = function(ent)
				ent:Remove()
			end,
		}(menu_items)
		local real_ctx = context_menu:GetChildren()[1]

		event.AddListener("Update", dropdown, function()
			if not dropdown:IsValid() or not real_ctx:IsValid() then
				return event.destroy_tag
			end

			local w = dropdown.transform:GetSize().x
			real_ctx.layout:SetMinSize(Vec2(w, 0))
			real_ctx.layout:SetMaxSize(Vec2(w, 0))
			local x, y = dropdown.transform:GetWorldMatrix():GetTranslation()
			y = y + dropdown.transform:GetHeight()
			real_ctx.transform:SetPosition(Vec2(x, y))

			if use_scroll and results_panel and results_panel:IsValid() then
				local viewport = results_panel:GetViewport()

				if viewport and viewport:IsValid() and viewport.layout then
					viewport.layout:UpdateLayout()
				end
			end
		end)

		world_panel:Ensure(context_menu)

		if use_search then
			timer.Delay(0, function()
				if results_panel and results_panel:IsValid() then rebuild_results() end

				if search_edit and search_edit:IsValid() then search_edit:RequestTextFocus() end
			end)
		end
	end

	dropdown = Clickable{
		layout = {Direction = "x", FitHeight = true, AlignmentY = "center"},
		OnClick = open_menu,
		Padding = props.Padding or "M",
	}{
		Text{
			IsInternal = true,
			Text = selected_text,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			Ref = function(self)
				label_ent = self
			end,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1, FitHeight = true},
			Color = props.Disabled and "text_disabled" or "text",
		},
		Panel.New{
			IsInternal = true,
			Name = "DropdownIndicator",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2() + theme.GetFontSize(props.FontSize),
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:DrawIcon(
						"dropdown_indicator",
						self.Owner.transform:GetSize(),
						{
							thickness = 2,
							color = theme.GetColor(props.Disabled and "text_disabled" or "text"),
						}
					)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		},
	}

	function dropdown:PreChildAdd(child)
		if child.IsInternal then return true end

		child.Visible = false
		child.ignore_layout = true
		return true -- we allow adding it as a child, but hidden
	end

	function dropdown:PreRemoveChildren()
		local children = self:GetChildren()

		for i = #children, 1, -1 do
			local child = children[i]

			if not child.IsInternal then
				child:UnParent()
				child:Remove()
			end
		end

		return false
	end

	if props.GetText then
		dropdown:AddLocalListener("OnDraw", function()
			if label_ent and label_ent:IsValid() then
				local txt = props.GetText()

				if label_ent.text:GetText() ~= txt then label_ent.text:SetText(txt) end
			end
		end)
	end

	function dropdown:SetValue(value)
		props.Value = value

		for _, opt in ipairs(options) do
			local text = type(opt) == "table" and opt.Text or tostring(opt)
			local val = type(opt) == "table" and opt.Value or opt

			if val == value then
				selected_text = text

				break
			end
		end

		if label_ent and label_ent:IsValid() and not props.GetText then
			label_ent.text:SetText(selected_text)
		end

		return self
	end

	function dropdown:GetValue()
		return props.Value
	end

	return dropdown
end
