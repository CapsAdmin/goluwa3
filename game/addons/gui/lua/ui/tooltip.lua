local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")
local tooltip = library()
local state = {
	owner = NULL,
	source = nil,
	options = nil,
	pending_owner = NULL,
	pending_source = nil,
	pending_options = nil,
	pending_show_time = 0,
	panel = NULL,
	text_panel = NULL,
	last_text = nil,
}
local ensure_panel

local function resolve_text(source, owner)
	if type(source) == "function" then source = source(owner) end

	if source == nil then return "" end

	return tostring(source)
end

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
end

local function get_offset(options)
	return options and options.Offset or Vec2(16, 22)
end

local function get_max_width(options)
	return options and options.MaxWidth or 320
end

local function get_delay(options)
	return options and options.Delay or 1
end

local function get_min_width(options)
	return options and options.MinWidth or 0
end

local function clear_pending(owner)
	if owner and state.pending_owner:IsValid() and state.pending_owner ~= owner then
		return
	end

	state.pending_owner = NULL
	state.pending_source = nil
	state.pending_options = nil
	state.pending_show_time = 0
end

local function update_position()
	if not state.panel:IsValid() or not state.panel.gui_element:GetVisible() then
		return
	end

	local mouse_pos = system.GetWindow():GetMousePosition()
	local offset = get_offset(state.options)
	local world_size = Panel.World.transform:GetSize()
	local size = state.panel.transform:GetSize()
	local x = mouse_pos.x + offset.x
	local y = mouse_pos.y + offset.y

	if x + size.x > world_size.x - 4 then
		x = math.max(4, world_size.x - size.x - 4)
	end

	if y + size.y > world_size.y - 4 then
		y = mouse_pos.y - size.y - math.max(8, offset.y * 0.5)
	end

	if y < 4 then y = 4 end

	state.panel.transform:SetPosition(Vec2(x, y))
	state.panel:BringToFront()
end

local function apply_text_layout(text)
	if
		not state.text_panel or
		not state.text_panel:IsValid()
		or
		not state.text_panel.text
	then
		return
	end

	local max_width = get_max_width(state.options)
	local min_width = get_min_width(state.options)
	local measured_width = select(1, state.text_panel.text:Measure(max_width, 0))
	local content_width = math.max(min_width, math.min(max_width, measured_width))

	if state.text_panel.layout then
		state.text_panel.layout:SetGrowWidth(0)
		state.text_panel.layout:SetFitWidth(false)
		state.text_panel.layout:SetMinSize(Vec2(content_width, 0))
		state.text_panel.layout:SetMaxSize(Vec2(content_width, 0))
	end

	state.panel.layout:InvalidateLayout(true)
end

local function show_now(owner, source, options)
	if not owner or not owner.IsValid or not owner:IsValid() then return end

	state.owner = owner
	state.source = source
	state.options = options or {}
	state.last_text = nil
	clear_pending()
	ensure_panel()

	if state.panel:IsValid() and state.panel.gui_element then
		state.panel.gui_element:SetVisible(true)
		update_position()
	end
end

function ensure_panel()
	if state.panel:IsValid() then return state.panel end

	state.panel = Panel.New{
		Key = "UITooltipOverlay",
		Parent = Panel.World,
		Name = "TooltipOverlay",
		transform = {
			Position = Vec2(0, 0),
			Size = Vec2(0, 0),
		},
		layout = {
			Floating = true,
			Direction = "y",
			FitWidth = true,
			FitHeight = true,
			Padding = "XS",
		},
		gui_element = {
			Visible = false,
			OnDraw = function(self)
				theme.active:DrawFrame(theme.GetDrawContext(self, true), 0)
			end,
			OnPostDraw = function(self)
				theme.active:DrawFramePost(theme.GetDrawContext(self, true), 0)
			end,
		},
		mouse_input = {
			IgnoreMouseInput = true,
		},
		animation = true,
	}{
		Text{
			Ref = function(self)
				state.text_panel = self
			end,
			Text = "",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 1,
				MaxSize = Vec2(get_max_width(), 0),
			},
		},
	}

	event.AddListener("Update", state.panel, function()
		if not state.panel:IsValid() then return event.destroy_tag end

		if state.pending_owner:IsValid() then
			if
				not state.pending_owner.mouse_input or
				not state.pending_owner.mouse_input:GetHovered()
			then
				clear_pending(state.pending_owner)
			elseif system.GetElapsedTime() >= state.pending_show_time then
				show_now(state.pending_owner, state.pending_source, state.pending_options)
			end
		end

		if not state.owner:IsValid() then
			if state.pending_owner:IsValid() then return end

			tooltip.Hide()
			return
		end

		local text = resolve_text(state.source, state.owner)

		if text == "" then
			tooltip.Hide(state.owner)
			return
		end

		if state.text_panel and state.text_panel:IsValid() then
			if state.last_text ~= text then
				state.last_text = text
				set_text(state.text_panel, text)
				apply_text_layout(text)
			end
		end

		if not state.panel.gui_element:GetVisible() then
			state.panel.gui_element:SetVisible(true)
		end

		update_position()
	end)

	return state.panel
end

function tooltip.Show(owner, source, options)
	if not owner or not owner.IsValid or not owner:IsValid() then return end

	if state.owner:IsValid() and state.owner == owner then
		state.source = source
		state.options = options or {}
		state.last_text = nil
		return
	end

	clear_pending()
	state.pending_owner = owner
	state.pending_source = source
	state.pending_options = options or {}
	state.pending_show_time = system.GetElapsedTime() + get_delay(state.pending_options)
	ensure_panel()
end

function tooltip.Hide(owner)
	if owner and state.owner:IsValid() and state.owner ~= owner then return end

	clear_pending(owner)
	state.owner = NULL
	state.source = nil
	state.options = nil
	state.last_text = nil

	if state.panel:IsValid() and state.panel.gui_element then
		state.panel.gui_element:SetVisible(false)
	end

	if state.text_panel and state.text_panel:IsValid() then
		set_text(state.text_panel, "")
	end
end

function tooltip.Attach(panel, source, options)
	if not panel or not panel.IsValid or not panel:IsValid() then return panel end

	panel:EnsureComponent("mouse_input")

	panel:AddLocalListener("OnHover", function(_, hovered)
		if hovered then
			tooltip.Show(panel, source, options)
		else
			tooltip.Hide(panel)
		end
	end)

	panel:AddLocalListener("OnRemove", function()
		tooltip.Hide(panel)
	end)

	return panel
end

return tooltip
