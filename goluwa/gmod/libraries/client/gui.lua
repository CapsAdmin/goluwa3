local window = import("goluwa/window.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local prototype = import("goluwa/prototype.lua")
local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local HostColor = import("goluwa/structs/color.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local render = import("goluwa/render/render.lua")
local surface = gine.env.surface

local function wrap_text(font, text, max_width)
	if gfx.WrapString then return gfx.WrapString(text, max_width, font) end

	if font and font.WrapString then return font:WrapString(text, max_width) end

	return text
end

local function limit_text(font, text, max_width)
	if gfx.DotLimitText then return gfx.DotLimitText(text, max_width, font) end

	return text
end

local function get_layout_text_size(font, text)
	text = tostring(text or "")

	if text == "" then return 0, 0 end

	local line_height = font.GetLineHeight and font:GetLineHeight() or 0
	local spacing = font.GetSpacing and font:GetSpacing() or rawget(font, "Spacing") or 0
	local max_width = 0
	local line_count = 0

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local width = font:GetTextSize(line)
		max_width = math.max(max_width, width)
		line_count = line_count + 1
	end

	if line_count == 0 then return 0, 0 end

	return max_width, line_height + (line_count - 1) * (line_height + spacing)
end

local function resolve_inherited_value(tbl, key)
	while type(tbl) == "table" do
		local value = rawget(tbl, key)

		if value ~= nil then return value end

		local mt = getmetatable(tbl)
		tbl = mt and mt.__index or nil
	end
end

local function call_panel_method(panel, name, ...)
	local method = rawget(panel, name)

	if method == nil then
		method = resolve_inherited_value(rawget(panel, "BaseClass"), name)
	end

	if method == nil then return nil end

	return method(panel, ...)
end

do
	local paint_panel_stack = {}

	function gine.GetPaintPanel()
		return paint_panel_stack[#paint_panel_stack]
	end

	function gine.PushPaintPanel(panel)
		table.insert(paint_panel_stack, panel)
	end

	function gine.PopPaintPanel()
		return table.remove(paint_panel_stack)
	end
end

local function run_gmod_frame_hooks_once()
	if not gine.env or not gine.env.hook then return end

	local frame = tonumber(system.GetFrameNumber()) or 0

	if gine.last_gmod_think_frame == frame then return end

	gine.last_gmod_think_frame = frame
	gine.env.hook.Run("Tick")
	gine.env.hook.Run("Think")
end

local function transform_local_to_world(transform, pos)
	if transform then
		if transform.LocalToWorld then return transform:LocalToWorld(pos) end

		if transform.GetWorldMatrix then
			local x, y = transform:GetWorldMatrix():TransformVectorUnpacked(pos.x, pos.y, pos.z or 0)
			return Vec2(x, y)
		end
	end

	return Vec2(pos.x or 0, pos.y or 0)
end

local function transform_world_to_local(transform, pos)
	if transform then
		if transform.GlobalToLocal then return transform:GlobalToLocal(pos) end

		if transform.GetWorldMatrixInverse then
			local x, y = transform:GetWorldMatrixInverse():TransformVectorUnpacked(pos.x, pos.y, pos.z or 0)
			return Vec2(x, y)
		end
	end

	return Vec2(pos.x or 0, pos.y or 0)
end

local function unpack_point_args(x, y)
	if y ~= nil then return x, y end

	local kind = type(x)

	if (kind == "table" or kind == "cdata" or kind == "userdata") and x.x ~= nil then
		return x.x, x.y
	end

	return x, y
end

local function get_size_of_children(panel)
	local function accumulate_size(node, offset)
		local max_x = 0
		local max_y = 0

		for _, child in ipairs(node:GetChildren()) do
			if child:IsValid() and child.transform then
				if child.gmod_internal_dock then
					local child_offset = offset + child.transform:GetPosition()
					local nested_x, nested_y = accumulate_size(child, child_offset)
					max_x = math.max(max_x, nested_x)
					max_y = math.max(max_y, nested_y)
				else
					local child_offset = offset + child.transform:GetPosition()
					local size = child.transform:GetSize()
					max_x = math.max(max_x, child_offset.x + size.x)
					max_y = math.max(max_y, child_offset.y + size.y)
				end
			end
		end

		return max_x, max_y
	end

	local max_x, max_y = accumulate_size(panel, Vec2())
	return Vec2(max_x, max_y)
end

local function get_text_api(panel)
	return rawget(panel, "text") or panel._gmod_text_proxy
end

local function panel_uses_wrapper_text(panel)
	return panel and
		panel.gmod_has_wrapper_text and
		panel.vgui_type ~= "textentry" and
		panel.vgui_type ~= "richtext"
end

local function set_panel_ignore_layout(panel, b)
	panel.ignore_layout = not not b

	if panel.layout then panel.layout:SetFloating(panel.ignore_layout) end
end

local function set_panel_multiline(panel, b)
	panel.multiline = not not b
	local text = get_text_api(panel)

	if text then
		if text.SetTextWrap then
			text:SetTextWrap(panel.multiline)
		elseif text.SetWrap then
			text:SetWrap(panel.multiline)
		end
	end
end

local function get_panel_multiline(panel)
	local text = get_text_api(panel)

	if text then
		if text.GetTextWrap then return text:GetTextWrap() end

		if text.GetWrap then return text:GetWrap() end
	end

	return not not panel.multiline
end

local function set_panel_editable(panel, b)
	panel.editable = not not b
	local text = get_text_api(panel)

	if text and text.SetEditable then text:SetEditable(panel.editable) end
end

local function set_panel_allow_keyboard_input(panel, b)
	panel.allow_keyboard_input = not not b
end

local function set_panel_focus_on_click(panel, b)
	panel.focus_on_click = not not b

	if panel.mouse_input then
		panel.mouse_input:SetFocusOnClick(panel.focus_on_click)
	end
end

local function set_panel_bring_to_front_on_click(panel, b)
	panel.bring_to_front_on_click = not not b

	if panel.mouse_input then
		panel.mouse_input:SetBringToFrontOnClick(panel.bring_to_front_on_click)
	end
end

local function set_panel_clipping(panel, b)
	if panel.gui_element then panel.gui_element:SetClipping(b) end
end

local function set_panel_margin(panel, rect)
	if panel.layout then panel.layout:SetMargin(rect) end
end

local function set_panel_padding(panel, rect)
	if panel.layout then panel.layout:SetPadding(rect) end
end

local function get_panel_padding(panel)
	return panel.layout and panel.layout:GetPadding() or Rect()
end

local function reset_panel_layout(panel)
	if panel.layout then panel.layout:InvalidateLayout() end

	if panel.OnPostLayout then panel:OnPostLayout() end
end

local function wrapper_panel_is_visible(panel)
	if panel.__obj.gui_element then return panel.__obj.gui_element:GetVisible() end

	return true
end

local function update_panel_text_offset(panel)
	if not panel_uses_wrapper_text(panel) then return end

	local w, h = panel.gine_pnl:GetTextSize()

	if panel.content_alignment == 5 then
		panel.text_offset = (panel.transform:GetSize() / 2) - (Vec2(w, h) / 2)
	elseif panel.content_alignment == 4 then
		panel.text_offset.x = 0
		panel.text_offset.y = (panel.transform:GetHeight() / 2) - (h / 2)
	elseif panel.content_alignment == 6 then
		panel.text_offset.x = panel.transform:GetWidth() - w
		panel.text_offset.y = (panel.transform:GetHeight() / 2) - (h / 2)
	elseif panel.content_alignment == 2 then
		panel.text_offset.x = (panel.transform:GetWidth() / 2) - (w / 2)
		panel.text_offset.y = panel.transform:GetHeight() - h
	elseif panel.content_alignment == 8 then
		panel.text_offset.x = (panel.transform:GetWidth() / 2) - (w / 2)
		panel.text_offset.y = 0
	elseif panel.content_alignment == 7 then
		panel.text_offset.x = 0
		panel.text_offset.y = 0
	elseif panel.content_alignment == 9 then
		panel.text_offset.x = panel.transform:GetWidth() - w
		panel.text_offset.y = 0
	elseif panel.content_alignment == 1 then
		panel.text_offset.x = 0
		panel.text_offset.y = panel.transform:GetHeight() - h
	elseif panel.content_alignment == 3 then
		panel.text_offset.x = panel.transform:GetWidth() - w
		panel.text_offset.y = panel.transform:GetHeight() - h
	end

	if w > panel.transform:GetWidth() then panel.text_offset.x = 0 end

	panel.text_offset = panel.text_offset + panel.text_inset

	if
		panel.content_alignment == 5 or
		panel.content_alignment == 2 or
		panel.content_alignment == 8
	then
		panel.text_offset.x = math.ceil(panel.text_offset.x)
	else
		panel.text_offset.x = math.floor(panel.text_offset.x)
	end

	if
		panel.content_alignment == 4 or
		panel.content_alignment == 5 or
		panel.content_alignment == 6
	then
		panel.text_offset.y = math.ceil(panel.text_offset.y)
	else
		panel.text_offset.y = math.floor(panel.text_offset.y)
	end
end

local dock_modes = {
	fill = true,
	left = true,
	right = true,
	top = true,
	bottom = true,
}

local function is_internal_dock_panel(panel)
	return panel and panel.gmod_internal_dock or false
end

local function is_dock_mode(mode)
	return dock_modes[mode] or false
end

local function normalize_dock_mode(mode)
	if mode == gine.env.FILL or mode == "fill" or mode == "gmod_fill" then
		return "fill"
	end

	if mode == gine.env.LEFT or mode == "left" or mode == "gmod_left" then
		return "left"
	end

	if mode == gine.env.RIGHT or mode == "right" or mode == "gmod_right" then
		return "right"
	end

	if mode == gine.env.TOP or mode == "top" or mode == "gmod_top" then
		return "top"
	end

	if mode == gine.env.BOTTOM or mode == "bottom" or mode == "gmod_bottom" then
		return "bottom"
	end

	return "none"
end

local function configure_layout_component(layout, config)
	if not layout then return end

	layout:SetFloating(config.floating or false)
	layout:SetDirection(config.direction or "y")
	layout:SetChildGap(config.child_gap or 0)
	layout:SetGrowWidth(config.grow_width or 0)
	layout:SetGrowHeight(config.grow_height or 0)
	layout:SetShrinkWidth(config.shrink_width or 0)
	layout:SetShrinkHeight(config.shrink_height or 0)
	layout:SetFitWidth(config.fit_width or false)
	layout:SetFitHeight(config.fit_height or false)
	layout:SetAlignmentX(config.alignment_x or "stretch")
	layout:SetAlignmentY(config.alignment_y or "stretch")
	layout:SetSelfAlignmentX(config.self_alignment_x or "auto")
	layout:SetSelfAlignmentY(config.self_alignment_y or "auto")

	if config.margin then layout:SetMargin(config.margin) end

	if config.padding then layout:SetPadding(config.padding) end

	if config.dock then layout:SetDock(config.dock) end
end

local function get_panel_logical_parent(panel)
	local parent = rawget(panel, "gmod_parent_override")

	if parent and parent:IsValid() then return parent end

	parent = panel:GetParent()

	if parent and parent:IsValid() then
		panel.gmod_last_valid_parent = parent
		return parent
	end

	parent = rawget(panel, "gmod_last_valid_parent")

	if parent and parent:IsValid() then return parent end

	return panel:GetParent()
end

local function assign_panel_logical_parent(panel, parent)
	local old_parent = rawget(panel, "gmod_parent_override")

	if old_parent ~= parent and old_parent and old_parent.gmod_logical_children then
		for i, child in ipairs(old_parent.gmod_logical_children) do
			if child == panel then
				table.remove(old_parent.gmod_logical_children, i)

				break
			end
		end
	end

	if old_parent ~= parent then
		parent.gmod_logical_child_sequence = (parent.gmod_logical_child_sequence or 0) + 1
		panel.gmod_logical_child_sequence = parent.gmod_logical_child_sequence
		parent.gmod_logical_children = parent.gmod_logical_children or {}
		parent.gmod_logical_children[#parent.gmod_logical_children + 1] = panel
	elseif parent.gmod_logical_children then
		local found = false

		for _, child in ipairs(parent.gmod_logical_children) do
			if child == panel then
				found = true

				break
			end
		end

		if not found then
			parent.gmod_logical_children[#parent.gmod_logical_children + 1] = panel
		end
	end

	panel.gmod_parent_override = parent
	panel.gmod_last_valid_parent = parent
end

local function reparent_panel_silently(child, parent)
	child.gmod_silent_reparent = (child.gmod_silent_reparent or 0) + 1
	local ok = parent:AddChild(child)
	child.gmod_silent_reparent = child.gmod_silent_reparent - 1

	if child.gmod_silent_reparent == 0 then child.gmod_silent_reparent = nil end

	return ok
end

local function get_panel_logical_position(panel)
	local pos = panel.transform:GetPosition():Copy()
	local logical_parent = get_panel_logical_parent(panel)
	local current = panel:GetParent()

	while current and current:IsValid() and current ~= logical_parent do
		if current.transform then pos = pos + current.transform:GetPosition() end

		current = current:GetParent()
	end

	return pos
end

local function get_logical_children(panel)
	local out = {}
	local children = panel.gmod_logical_children or {}

	for i = 1, #children do
		local child = children[i]

		if
			child:IsValid() and
			not is_internal_dock_panel(child)
			and
			get_panel_logical_parent(child) == panel
		then
			out[#out + 1] = child
		end
	end

	return out
end

local function configure_dock_host(panel)
	if not panel.layout then return end

	panel.layout:SetDirection("y")
	panel.layout:SetChildGap(0)
	panel.layout:SetAlignmentX("stretch")
	panel.layout:SetAlignmentY("stretch")
end

local function request_panel_layout(panel)
	if not (panel and panel:IsValid()) then return end

	if panel.layout then panel.layout:InvalidateLayout() end

	local wrapped = rawget(panel, "gine_pnl")

	if wrapped and not wrapped.in_layout then wrapped.gine_layout = true end
end

local function invalidate_panel_children_now(panel)
	if not (panel and panel:IsValid()) then return end

	for _, child in ipairs(panel:GetChildren()) do
		local wrapped = rawget(child, "gine_pnl")

		if wrapped and not wrapped.in_layout then wrapped:InvalidateLayout(true) end
	end
end

local function setup_panel_layout(panel, mode)
	mode = normalize_dock_mode(mode)
	panel.layout_mode = mode
	local logical_parent = get_panel_logical_parent(panel)

	if panel.layout then
		panel.layout:SetFloating(mode == "none")
		panel.layout:SetDock(mode)
	end

	if logical_parent and logical_parent:IsValid() then
		configure_dock_host(logical_parent)
		request_panel_layout(logical_parent)
		local wrapped_parent = rawget(logical_parent, "gine_pnl")

		if wrapped_parent and not wrapped_parent.in_layout then
			wrapped_parent.gine_layout = true
		end
	end
end

local function request_panel_and_parent_layout(panel)
	request_panel_layout(panel)
	local parent = get_panel_logical_parent(panel)

	if not (parent and parent:IsValid()) then return end

	request_panel_layout(parent)
end

local function set_panel_child(panel, child)
	panel._gmod_text_proxy = child

	if child and child.IsValid and child:IsValid() then child:SetParent(panel) end
end

local function set_panel_text(panel, text)
	panel.text_internal = tostring(text or "")
	panel.gmod_has_wrapper_text = true
	text = get_text_api(panel)

	if text and text.SetText then text:SetText(panel.text_internal) end
end

local function get_panel_text(panel)
	local text = get_text_api(panel)

	if text and text.GetText then return text:GetText() end

	return panel.text_internal or ""
end

local function set_panel_caret_sub_position(panel, pos)
	panel.caret_pos = math.max(0, tonumber(pos) or 0)
end

local function get_panel_caret_sub_position(panel)
	return panel.caret_pos or 0
end

local function get_panel_mouse_position(panel)
	if panel.mouse_input then return panel.mouse_input:GetMousePosition() end

	return Vec2()
end

local function is_panel_mouse_over(panel)
	return panel.mouse_input and panel.mouse_input:IsHoveredExclusively() or false
end

local function initialize_panel(panel, class_name)
	if panel._gmod_panel_ready then return panel end

	panel._gmod_panel_ready = true
	panel.gine_enabled = panel.gine_enabled ~= false
	panel.vgui_type = class_name or panel.vgui_type or "base"
	panel.gmod_has_wrapper_text = panel.gmod_has_wrapper_text or false
	panel.allow_keyboard_input = panel.allow_keyboard_input or false
	panel.focus_on_click = panel.focus_on_click or false
	panel.bring_to_front_on_click = panel.bring_to_front_on_click or false
	panel.content_alignment = panel.content_alignment or 5
	panel.text_internal = panel.text_internal or ""
	panel.text_inset = panel.text_inset or Vec2(0, 0)
	panel.caret_pos = panel.caret_pos or 0
	panel.multiline = panel.multiline or false
	panel.editable = panel.editable or false
	panel.label = panel.label or {markup = {
		SetPreserveTabsOnEnter = function() end,
	}}
	panel._gmod_text_proxy = panel._gmod_text_proxy or
		{
			markup = {
				AddFont = function() end,
				AddString = function() end,
				AddColor = function() end,
			},
			SetTextWrap = function(_, b)
				panel.multiline = b
			end,
			GetTextWrap = function()
				return panel.multiline
			end,
		}
	return panel
end

local function create_panel(class_name, parent, name)
	local panel = Panel.New{
		Name = name or class_name,
		transform = {
			Size = Vec2(1, 1),
		},
		layout = true,
		gui_element = true,
		mouse_input = true,
		clickable = true,
		animation = true,
	}

	if class_name == "text_edit" or class_name == "text" then
		panel:EnsureComponent("text")
	end

	initialize_panel(panel, class_name)
	set_panel_ignore_layout(panel, true)

	if class_name == "text_edit" or class_name == "text" then
		set_panel_editable(panel, class_name == "text_edit")
		panel.text.markup = panel.text.markup or
			{
				AddFont = function() end,
				AddString = function() end,
				AddColor = function() end,
			}
		panel.text.SetTextWrap = panel.text.SetTextWrap or function(_, b)
			panel.multiline = b
		end
		panel.text.GetTextWrap = panel.text.GetTextWrap or function()
			return panel.multiline
		end
	end

	if parent and parent.IsValid and parent:IsValid() then
		panel.gmod_last_valid_parent = parent
		panel:SetParent(parent)
	else
		panel.gmod_last_valid_parent = Panel.World
		panel:SetParent(Panel.World)
	end

	return panel
end

local function get_hovered_panel(panel, mouse_pos)
	if not panel or not panel:IsValid() then return NULL end

	if panel.gui_element and not panel.gui_element:GetVisible() then return NULL end

	if
		panel.mouse_input and
		panel.mouse_input:GetIgnoreMouseInput() and
		not is_internal_dock_panel(panel)
	then
		return NULL
	end

	local children = panel:GetChildren()

	for i = #children, 1, -1 do
		local hovered = get_hovered_panel(children[i], mouse_pos)

		if hovered:IsValid() then return hovered end
	end

	if
		not is_internal_dock_panel(panel) and
		panel.gui_element and
		panel.gui_element:IsHovered(mouse_pos)
	then
		return panel
	end

	return NULL
end

local function get_window()
	return system.GetCurrentWindow()
end

local function get_primary_window()
	return system.GetWindow()
end

local function bring_gui_world_to_front()
	if not gine.gui_world or not gine.gui_world:IsValid() then return end

	local parent = gine.gui_world:GetParent()

	if parent and parent:IsValid() then gine.gui_world:BringToFront() end
end

local next_overlay_child_order = 1000000

local function promote_panel_overlay_order(panel)
	if not (panel and panel:IsValid()) then return end

	next_overlay_child_order = next_overlay_child_order + 1
	panel:SetChildOrder(next_overlay_child_order)
end

do -- chatbox
	local chat = gine.env.chat
	local lib = _G.chat

	function chat.AddText(...)
		local tbl = {...}

		for i, v in ipairs(tbl) do
			if gine.env.IsColor(v) then
				tbl[i] = HostColor.FromBytes(v.r or 0, v.g or 0, v.b or 0, v.a or 255)
			elseif type(v) == "table" and v.__obj then
				tbl[i] = v.__obj
			end
		end

		chathud.AddText(unpack(tbl))
	end

	function chat.Close()
		lib.Close()
		lib.GetPanel():Remove()
	end

	function chat.Open()
		lib.Open()
	end

	function chat.GetChatBoxPos()
		if lib.panel:IsValid() then return lib.panel:GetPosition():Unpack() end

		return 0, 0
	end

	function chat.GetChatBoxSize()
		if lib.panel:IsValid() then return lib.panel:GetSize():Unpack() end

		return 0, 0
	end
end

do
	local vgui = gine.env.vgui

	function vgui.GetAll()
		local out = {}

		if gine.objectsi.Panel then
			for _, data in ipairs(gine.objectsi.Panel) do
				out[#out + 1] = data.external
			end
		end

		return out
	end

	function vgui.GetHoveredPanel()
		local pnl = get_hovered_panel(Panel.World, get_primary_window():GetMousePosition())

		if pnl:IsValid() then return gine.WrapObject(pnl, "Panel") end
	end

	function vgui.FocusedHasParent(parent)
		local focused = prototype.GetFocusedObject()

		if focused and focused:IsValid() and parent and parent.__obj then
			return parent.__obj:HasChild(focused)
		end
	end

	function vgui.GetKeyboardFocus()
		local focused = prototype.GetFocusedObject()

		if focused and focused:IsValid() then
			return gine.WrapObject(focused, "Panel")
		end
	end

	function vgui.CursorVisible()
		return get_window():GetCursor() ~= "trapped"
	end

	function vgui.GetWorldPanel()
		return gine.WrapObject(gine.gui_world, "Panel")
	end
end

do
	local gui = gine.env.gui

	function gui.MousePos()
		return get_primary_window():GetMousePosition():Unpack()
	end

	function gui.MouseX()
		return get_primary_window():GetMousePosition().x
	end

	function gui.MouseY()
		return get_primary_window():GetMousePosition().y
	end

	function gui.ScreenToVector(x, y)
		return gine.env.Vector() --(math3d.ScreenToWorldDirection(Vec2(x, y)):Unpack())
	end

	function gui.IsGameUIVisible()
		return false --menu.IsVisible()
	end

	function gui.EnableScreenClicker(b)
		get_window():SetMouseTrapped(not b)
	end

	function gui.IsConsoleVisible()
		return false
	end
end

do
	gine.AddEvent("GUIPanelMouseInput", function(panel, button, press)
		if press then
			gine.env.hook.Run("VGUIMousePressed", gine.WrapObject(panel, "Panel"), gine.GetMouseCode(button))
		end
	end)

	gine.gui_world = gine.gui_world or NULL

	local function refresh_gui_world_bounds()
		if not gine.gui_world or not gine.gui_world:IsValid() then return end

		local wnd = get_window()

		if not wnd then return end

		gine.gui_world.transform:SetPosition(Vec2(0, 0))
		gine.gui_world.transform:SetSize(wnd:GetSize())
	end

	local function hook(obj, func_name, callback)
		--print(obj, func_name, callback)
		local old = obj[func_name]

		if not old then
			obj[func_name] = callback
		else
			obj[func_name] = function(z, x, c, v, b, n, m)
				local a, b, c, d = callback(z, x, c, v, b, n, m)

				if a ~= nil then return a, b, c, d end

				return old(z, x, c, v, b, n, m)
			end
		end
	end

	local function vgui_Create(class, parent, name)
		local requested_class = class
		local control = gine.env.vgui.GetControlTable(requested_class)
		local stub_model_preview = requested_class == "DModelPanel" or
			requested_class == "DAdjustableModelPanel" or
			requested_class == "ModelImage"
		name = name or requested_class

		if not gine.gui_world:IsValid() then
			gine.gui_world = create_panel("base")
			gine.gui_world.no_draw = true
			set_panel_ignore_layout(gine.gui_world, true)
			--gine.gui_world:SetIgnoreMouse(true)
			gine.gui_world.__class = "CGModBase"

			function gine.gui_world:OnLayout()
				self.transform:SetPosition(Vec2(0, 0))
				self.transform:SetSize(get_window():GetSize())
			end
		end

		bring_gui_world_to_front()
		refresh_gui_world_bounds()
		class = class:lower()
		local obj

		if class == "textentry" then
			obj = create_panel("text_edit")
			set_panel_multiline(obj, false)
			set_panel_editable(obj, false)
			obj.label.markup:SetPreserveTabsOnEnter(false)
			--local draw_func = obj.label.OnPostDraw
			obj.label.DrawTextEntryText = function() end
		--obj.label.OnPostDraw = function() end
		elseif class == "richtext" then
			obj = create_panel("scroll")
			local markup = create_panel("text", obj, "text")
			set_panel_child(obj, markup)
		else
			obj = create_panel("base")
		end

		local self = gine.WrapObject(obj, "Panel")
		obj:SetName("gmod_" .. name)
		obj.gine_pnl = self
		self.__class = requested_class
		self.ClassName = requested_class
		obj.name_prepare = name

		if control then self.BaseClass = control end

		obj.fg_color = HostColor.FromBytes(255, 255, 255, 255)
		obj.bg_color = HostColor.FromBytes(255, 255, 255, 255)
		obj.text_inset = Vec2()
		obj.text_offset = Vec2()
		obj.vgui_type = class
		obj.gmod_stub_model_preview = stub_model_preview
		obj.gine_init_complete = false
		--self:SetPaintBackgroundEnabled(true)
		obj.transform:SetSize(Vec2(64, 24))
		set_panel_margin(obj, Rect())
		set_panel_padding(obj, Rect())
		reset_panel_layout(obj)
		--		obj:SetAllowKeyboardInput(false)
		set_panel_focus_on_click(obj, false)
		set_panel_bring_to_front_on_click(obj, false)
		set_panel_clipping(obj, true)
		self:SetContentAlignment(4)
		self:SetFontInternal("default")
		self:MouseCapture(false)
		self:SetParent(parent)
		self:Prepare()

		if control and control.Init then control.Init(self) end

		obj.gine_init_complete = true
		self:InvalidateLayout(true)
		obj.OnDraw = function()
			run_gmod_frame_hooks_once()

			if self.AnimationThink then self:AnimationThink() end

			if obj.draw_manual and not obj.in_paint_manual then return end

			gine.PushPaintPanel(self)
			call_panel_method(self, "Think")
			obj.thought_1_frame = true
			local w, h = obj.transform:GetWidth(), obj.transform:GetHeight()
			local paint_bg

			if obj.gmod_stub_model_preview then
				paint_bg = nil
			else
				paint_bg = call_panel_method(self, "Paint", w, h)
			end

			if obj.paint_bg and paint_bg ~= nil then
				render2d.SetTexture()
				render2d.SetColor(obj.bg_color:Unpack())
				render2d.DrawRect(0, 0, w, h)
			end

			if panel_uses_wrapper_text(obj) then
				if obj.text_internal and obj.text_internal ~= "" then
					local text = obj.text_internal
					local font = gine.render2d_fonts[obj.font_internal:lower()]

					if obj.gmod_wrap then
						text = wrap_text(font, text, w)
					else
						text = limit_text(font, text, w)
					end

					update_panel_text_offset(obj)
					render2d.SetTexture()
					render2d.SetUV()
					--render2d.SetAlphaTestReference(0)
					render2d.SetBlendMode("alpha", true)

					if obj.expensive_shadow_dir then
						render2d.SetColor(obj.expensive_shadow_color:Unpack())
						font:DrawString(
							text,
							obj.text_offset.x + obj.expensive_shadow_dir,
							obj.text_offset.y + obj.expensive_shadow_dir
						)
					end

					render2d.SetColor(obj.fg_color:Unpack())
					font:DrawString(text, obj.text_offset.x, obj.text_offset.y)
				end
			end

			call_panel_method(self, "PaintOver", obj.transform:GetWidth(), obj.transform:GetHeight())

			if self.gine_layout then
				self:InvalidateLayout(true)
				self.gine_layout = nil
			end

			gine.PopPaintPanel()
		end

		obj:CallOnRemove(function()
			obj.marked_for_deletion = true
			call_panel_method(self, "OnDeletion")
		end)

		local function sync_wrapper_layout()
			if panel_uses_wrapper_text(obj) then update_panel_text_offset(obj) end

			if not obj.gine_prepared then
				obj.gine_prepare_layout = true
				return
			end

			if self.in_layout or self.in_sync_layout then return end

			self.in_sync_layout = true
			call_panel_method(self, "ApplySchemeSettings")
			call_panel_method(self, "PerformLayout", obj.transform:GetWidth(), obj.transform:GetHeight())
			self.in_sync_layout = false
		end

		if class == "textentry" then
			hook(obj, "OnCharInput", function(_, char)
				if self.AllowInput then return self:AllowInput(char) end
			end)

			hook(obj, "OnTextChanged", function()
				local text = self:GetText():gsub("\t", "")

				if text ~= "" then
					for _, char in ipairs(text:utf8_to_list()) do
						self.override_text = char
						self:OnTextChanged()
						self.override_text = nil
					end
				end
			end)
		end

		hook(obj, "OnFocus", function()
			call_panel_method(self, "OnGetFocus")
		end)

		hook(obj, "OnUnfocus", function()
			call_panel_method(self, "OnLoseFocus")
		end)

		hook(obj, "OnUpdate", function()
			call_panel_method(self, "Think")
			self.thought_1_frame = true
		end)

		hook(obj, "OnMouseMove", function(_, x, y)
			x, y = unpack_point_args(x, y)
			call_panel_method(self, "OnCursorMoved", x, y)
		end)

		hook(obj, "OnMouseEnter", function()
			gine.env.ChangeTooltip(self)
			call_panel_method(self, "OnCursorEntered")
		end)

		hook(obj, "OnMouseLeave", function()
			gine.env.EndTooltip(self)
			call_panel_method(self, "OnCursorExited")
		end)

		hook(obj, "OnMouseExit", function()
			gine.env.EndTooltip(self)
			call_panel_method(self, "OnCursorExited")
		end)

		hook(obj, "OnPostLayout", sync_wrapper_layout)

		obj:AddLocalListener("OnVisibilityChanged", function()
			request_panel_and_parent_layout(obj)
		end)

		hook(obj, "OnMouseInput", function(_, button, press)
			if button == "mwheel_down" then
				call_panel_method(self, "OnMouseWheeled", 1)
				return true
			elseif button == "mwheel_up" then
				call_panel_method(self, "OnMouseWheeled", -1)
				return true
			else
				if press then
					call_panel_method(self, "OnMousePressed", gine.GetMouseCode(button))
				else
					call_panel_method(self, "OnMouseReleased", gine.GetMouseCode(button))
				end

				event.Call("GUIPanelMouseInput", obj, button, press)
				return true
			end
		end)

		hook(obj, "OnKeyInput", function(_, key, press)
			if press then
				call_panel_method(self, "OnKeyCodeTyped", gine.GetKeyCode(key))
				call_panel_method(self, "OnKeyCodePressed", gine.GetKeyCode(key))
			else
				call_panel_method(self, "OnKeyCodeReleased", gine.GetKeyCode(key))
			end
		end)

		function obj:IsInsideParent()
			if self.popup then return true end

			if
				self.Position.x < self.Parent.Size.x and
				self.Position.y < self.Parent.Size.y and
				self.Position.x + self.Size.x > 0 and
				self.Position.y + self.Size.y > 0
			then
				return true
			end

			return false
		end

		return self
	end

	if gine.env.vgui.CreateX then
		gine.env.vgui.CreateX = vgui_Create
	else
		gine.env.vgui.Create = vgui_Create
	end

	local META = gine.EnsureMetaTable("Panel")

	function META:Prepare()
		if self.__obj.name_prepare ~= self.ClassName then return end

		if self.__obj.gine_prepared then return end

		local had_pending_layout = self.__obj.gine_prepare_layout
		self.__obj.gine_prepare_layout = nil
		self.__obj.gine_prepared = true

		hook(self.__obj, "OnChildAdd", function(_, child)
			if is_internal_dock_panel(child) then return end

			if child.gmod_silent_reparent then return end

			call_panel_method(self, "OnChildAdded", gine.WrapObject(child, "Panel"))
		end)

		hook(self.__obj, "OnChildRemove", function(_, child)
			if is_internal_dock_panel(child) then return end

			if child.gmod_silent_reparent then return end

			call_panel_method(self, "OnChildRemoved", gine.WrapObject(child, "Panel"))
		end)

		return had_pending_layout
	end

	function META:GetClassName()
		return self.ClassName or ""
	end

	function META:IsMarkedForDeletion()
		return self.__obj.marked_for_deletion
	end

	function META:__tostring()
		return (
			"Panel: [name:Panel][class:%s][%s,%s,%s,%s]"
		):format(self.__class, self.x, self.y, self.w, self.h)
	end

	function META:__index(key)
		if key == "x" or key == "X" then
			return get_panel_logical_position(self.__obj).x
		elseif key == "y" or key == "Y" then
			return get_panel_logical_position(self.__obj).y
		elseif key == "w" or key == "W" then
			return self.__obj.transform:GetSize().x
		elseif key == "h" or key == "H" then
			return self.__obj.transform:GetSize().y
		elseif key == "Hovered" then
			return is_panel_mouse_over(self.__obj)
		end

		local val = rawget(META, key)

		if val then return val end

		local base = rawget(self, "BaseClass")

		if base then
			local inherited = resolve_inherited_value(base, key)

			if inherited ~= nil then return inherited end
		end
	end

	function META:__newindex(k, v)
		if k == "x" or k == "X" then
			self.__obj.transform:SetX(v)
		elseif k == "y" or k == "Y" then
			self.__obj.transform:SetY(v)
		elseif k == "w" or k == "W" then
			self.__obj.transform:SetWidth(v)
		elseif k == "h" or k == "H" then
			self.__obj.transform:SetHeight(v)
		else
			rawset(self, k, v)
		end
	end

	META.__eq = nil -- no need
	function META:SelectAll() end

	function META:SetParent(panel)
		local old_parent = get_panel_logical_parent(self.__obj)
		local new_parent = gine.gui_world

		if panel and panel:IsValid() and panel.__obj and panel.__obj:IsValid() then
			new_parent = panel.__obj
		end

		assign_panel_logical_parent(self.__obj, new_parent)
		local same_raw_parent = self.__obj:GetParent() == new_parent

		if self.__obj:GetParent() ~= new_parent then self.__obj:SetParent(new_parent) end

		if old_parent and old_parent:IsValid() and old_parent ~= new_parent then
			request_panel_layout(old_parent)
		end

		local wrapped_parent = rawget(new_parent, "gine_pnl")

		if same_raw_parent and wrapped_parent and not wrapped_parent.in_layout then
			wrapped_parent:InvalidateLayout(true)
		else
			request_panel_layout(new_parent)
		end
	end

	function META:SetAutoDelete(b)
		self.__obj.remove_on_parent_remove = not not b
	end

	function META:GetChildren()
		local children = {}

		for _, v in ipairs(get_logical_children(self.__obj)) do
			list.insert(children, gine.WrapObject(v, "Panel"))
		end

		return children
	end

	function META:ChildCount()
		return #self:GetChildren()
	end

	function META:GetChild(idx)
		return self:GetChildren()[idx]
	end

	function META:SetFGColor(r, g, b, a)
		self.__obj.fg_color.r = (r or 0) / 255
		self.__obj.fg_color.g = (g or 0) / 255
		self.__obj.fg_color.b = (b or 0) / 255
		self.__obj.fg_color.a = (a or 255) / 255
	end

	function META:SetBGColor(r, g, b, a)
		self.__obj.bg_color.r = (r or 0) / 255
		self.__obj.bg_color.g = (g or 0) / 255
		self.__obj.bg_color.b = (b or 0) / 255
		self.__obj.bg_color.a = (a or 255) / 255
	end

	function META:CursorPos()
		return get_panel_mouse_position(self.__obj):Unpack()
	end

	function META:GetPos()
		return get_panel_logical_position(self.__obj):Unpack()
	end

	function META:GetBounds()
		local x, y = self:GetPos()
		local w, h = self:GetSize()
		return x, y, w, h
	end

	function META:SetName(name)
		self.__obj.name = name
	end

	function META:GetName(name)
		return self.__obj.name or ""
	end

	function META:IsVisible()
		return wrapper_panel_is_visible(self)
	end

	function META:IsModal()
		return false
	end

	function META:IsWorldClicker()
		return false
	end

	function META:GetTable()
		return self
	end

	function META:SetPos(x, y)
		x = x or 0
		y = y or 0
		self.__obj.transform:SetPosition(Vec2(x, y))
	end

	function META:HasChildren()
		return get_logical_children(self.__obj)[1] ~= nil
	end

	function META:HasParent(panel)
		return panel.__obj:HasChild(self.__obj)
	end

	function META:DockMargin(left, top, right, bottom)
		set_panel_margin(self.__obj, Rect(left, top, right, bottom))
	end

	function META:DockPadding(left, top, right, bottom)
		set_panel_padding(self.__obj, Rect(left, top, right, bottom))
	end

	function META:GetDockPadding()
		local padding = get_panel_padding(self.__obj)
		return padding.x or 0, padding.y or 0, padding.w or 0, padding.h or 0
	end

	function META:SetMouseInputEnabled(b)
		if self.__obj.mouse_input then
			self.__obj.mouse_input:SetIgnoreMouseInput(not b)
		end
	end

	function META:MouseCapture(b)
		self.__obj.global_mouse_capture = not not b
	end

	function META:SetKeyboardInputEnabled(b)
		set_panel_allow_keyboard_input(self.__obj, b)
	end

	function META:IsKeyboardInputEnabled()
		return not not self.__obj.allow_keyboard_input
	end

	function META:GetWide()
		return self.__obj.transform:GetWidth()
	end

	function META:GetTall()
		return self.__obj.transform:GetHeight()
	end

	function META:GetWidth()
		return self.__obj.transform:GetWidth()
	end

	function META:GetHeight()
		return self.__obj.transform:GetHeight()
	end

	function META:SetSize(w, h)
		w = tonumber(w)
		h = tonumber(h) or w
		local old_w = self.__obj.transform:GetWidth()
		local old_h = self.__obj.transform:GetHeight()

		if old_w == w and old_h == h then return end

		self.__obj.transform:SetSize(Vec2(w, h))
		call_panel_method(self, "OnSizeChanged", w, h)
		request_panel_and_parent_layout(self.__obj)
	end

	function META:GetSize()
		return self.__obj.transform:GetSize():Unpack()
	end

	function META:ChildrenSize()
		return get_size_of_children(self.__obj):Unpack()
	end

	function META:LocalToScreen(x, y)
		x, y = unpack_point_args(x, y)
		return transform_local_to_world(self.__obj.transform, Vec2(x or 0, y or 0)):Unpack()
	end

	function META:ScreenToLocal(x, y)
		x, y = unpack_point_args(x, y)
		return transform_world_to_local(self.__obj.transform, Vec2(x, y)):Unpack()
	end

	do
		function META:SetFontInternal(font)
			self.__obj.font_internal = font or "default"
			local font = gine.render2d_fonts[self.__obj.font_internal:lower()]

			if not font then
				--llog("font ", self.__obj.font_internal, " does not exist")
				self.__obj.font_internal = "default"
			else
				if self.__obj.vgui_type == "richtext" then
					self.__obj.text.markup:AddFont(font)
				end
			end
		end

		function META:GetFont()
			return self.__obj.font_internal or "default"
		end

		function META:SetText(text)
			if self.__obj.vgui_type == "textentry" then
				text = tostring(text):gsub("\t", "")
				set_panel_text(self.__obj, text)
			elseif self.__obj.vgui_type == "richtext" then
				set_panel_text(self.__obj, text)
			else
				self.__obj.gmod_has_wrapper_text = true
				self.__obj.text_internal = gine.translation2[text] or text
			--	self.__obj.label_settext = system.GetFrameNumber()
			end
		end
	end

	do
		local function is_stub_model_preview(self)
			return self.__obj.gmod_stub_model_preview
		end

		function META:SetModel(model, skin, body_groups)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_model_name = model
			self.__obj.gmod_model_skin = skin or 0
			self.__obj.gmod_model_body_groups = body_groups or "000000000"
		end

		function META:GetModel()
			if not is_stub_model_preview(self) then return nil end

			return self.__obj.gmod_model_name
		end

		function META:SetSpawnIcon(name)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_spawnicon_name = name
		end

		function META:RebuildSpawnIcon()
			if not is_stub_model_preview(self) then return end
		end

		function META:RebuildSpawnIconEx(data)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_spawnicon_rebuild_data = data
		end

		function META:SetBodyGroup(index, value)
			if not is_stub_model_preview(self) then return end

			local body_groups = self.__obj.gmod_model_body_groups or "000000000"
			index = math.floor(tonumber(index) or 0)
			value = math.floor(tonumber(value) or 0)

			if index < 0 or index > 8 then return end

			if value < 0 or value > 9 then return end

			self.__obj.gmod_model_body_groups = body_groups:SetChar(index + 1, value)
		end

		function META:SetCamPos(pos)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_model_cam_pos = pos
		end

		function META:SetLookAt(pos)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_model_look_at = pos
		end

		function META:SetFOV(fov)
			if not is_stub_model_preview(self) then return end

			self.__obj.gmod_model_fov = fov
		end

		function META:GetEntity()
			if not is_stub_model_preview(self) then return nil end

			return NULL
		end
	end

	function META:SetAlpha(a)
		if self.__obj.gui_element then
			self.__obj.gui_element.DrawAlpha = (a / 255) ^ 2
		end

		self.__obj.gmod_draw_alpha = a
	end

	function META:GetAlpha()
		return self.__obj.gmod_draw_alpha or 255
	end

	function META:GetParent()
		local parent = get_panel_logical_parent(self.__obj)

		if parent:IsValid() then return gine.WrapObject(parent, "Panel") end

		return nil
	end

	function META:InvalidateLayout(now)
		if self.in_layout then return end

		if
			self.__obj ~= gine.gui_world and
			not (
				self.__obj:GetParent() and
				self.__obj:GetParent():IsValid()
			)
			and
			not (
				rawget(self.__obj, "gmod_parent_override") and
				self.__obj.gmod_parent_override:IsValid()
			)
		then
			self.gine_layout = true
			return
		end

		local had_pending_layout = false

		if not self.__obj.gine_prepared then
			had_pending_layout = self:Prepare() or false
		end

		if now or had_pending_layout then
			self.in_layout = true

			if self.__obj.layout and self.__obj.layout:GetDirty() then
				self.__obj.layout:UpdateLayout()
			end

			call_panel_method(self, "ApplySchemeSettings")
			call_panel_method(
				self,
				"PerformLayout",
				self.__obj.transform:GetWidth(),
				self.__obj.transform:GetHeight()
			)

			if self.__obj.layout and self.__obj.layout:GetDirty() then
				self.__obj.layout:UpdateLayout()
			end

			invalidate_panel_children_now(self.__obj)
			self.in_layout = false
		else
			self.gine_layout = true
		end
	end

	function META:GetContentSize()
		local panel = self.__obj

		if panel_uses_wrapper_text(panel) then
			self.get_content_size = true
			local w, h = self:GetTextSize()
			self.get_content_size = false
			return w + panel.text_inset.x, h + panel.text_inset.y
		end

		return self:ChildrenSize()
	end

	function META:GetTextSize()
		local panel = self.__obj
		local logical_parent = get_panel_logical_parent(panel)
		local wrap_width = self:GetWide()

		if logical_parent and logical_parent:IsValid() and logical_parent.transform then
			wrap_width = logical_parent.transform:GetWidth()
		end

		-- in gmod the text size isn't correct until next frame
		--[[if panel.label_settext then
			if panel.label_settext == system.GetFrameNumber() then
				return 0, 0
			end
			panel.label_settext = nil
		end]]
		local font = gine.render2d_fonts[panel.font_internal:lower()]
		local text = tostring(panel.text_internal or "")

		if not self.get_content_size then
			if panel.gmod_wrap then
				text = wrap_text(font, text, wrap_width)
			elseif not text:find("\n", nil, true) then
				text = limit_text(font, text, self:GetWide())
			end
		end

		local w, h = get_layout_text_size(font, text)

		if
			panel.gmod_wrap and
			logical_parent and
			logical_parent:IsValid() and
			logical_parent.transform
		then
			w = logical_parent.transform:GetWidth()
		end

		return w, h
	end

	function META:SizeToContents()
		local panel = self.__obj
		local w, h

		if
			panel_uses_wrapper_text(panel) or
			self.__obj.vgui_type == "textentry" or
			self.__obj.vgui_type == "richtext"
		then
			w, h = self:GetContentSize()
		else
			w, h = self:ChildrenSize()
		end

		self:SetSize(w, h)
	end

	function META:GetValue()
		if self.override_text then return self.override_text end

		return self:GetText()
	end

	function META:GetExpanded()
		return self.m_bSizeExpanded
	end

	function META:GetText()
		if self.__obj.vgui_type == "textentry" or self.__obj.vgui_type == "richtext" then
			return get_panel_text(self.__obj)
		elseif panel_uses_wrapper_text(self.__obj) then
			return self.__obj.text_internal
		end

		return ""
	end

	function META:SetTextInset(x, y)
		self.__obj.text_inset.x = x
		self.__obj.text_inset.y = y
		update_panel_text_offset(self.__obj)
	end

	function META:GetTextInset()
		return self.__obj.text_inset.x, self.__obj.text_inset.y
	end

	function META:GetContentAlignment()
		return self.__obj.content_alignment or 5
	end

	function META:SizeToChildren(size_w, size_h)
		if size_w == nil then size_w = true end

		if size_h == nil then size_h = true end

		--[[

		for _, v in ipairs(self.__obj.Children) do
			v.old_size = v:GetSize()

			if not v.Children[1] and v.vgui_type == "label" then
				local w, h = v.gine_pnl:GetTextSize()

				if not size_h then h = v:GetHeight() end
				if not size_w then w = v:GetWidth() end

				v.Size = Vec2(w, h)
			end
		end
]]
		local size = get_size_of_children(self.__obj)

		if size_w and size_h then
			self:SetSize(size.x, size.y)
		elseif size_w then
			self:SetWide(size.x)
		elseif size_h then
			self:SetTall(size.y)
		end
	--[[
		for _, v in ipairs(self.__obj.Children) do
			v.Size = v.old_size
		end
]]
	end

	function META:SetVisible(b)
		if not self.__obj.gui_element then return end

		local was_visible = self.__obj.gui_element:GetVisible()

		if was_visible == b then return end

		self.__obj.gui_element:SetVisible(b)

		if b then
			refresh_gui_world_bounds()
			request_panel_and_parent_layout(self.__obj)

			if not self.in_layout then
				self:InvalidateLayout(true)
				invalidate_panel_children_now(self.__obj)
			end
		end
	end

	function META:Dock(enum)
		local mode = normalize_dock_mode(enum)
		setup_panel_layout(self.__obj, mode)
		self.__obj.vgui_dock = mode
	end

	function META:GetDock()
		local mode = normalize_dock_mode(self.__obj.vgui_dock)

		if mode == "fill" then return gine.env.FILL end

		if mode == "left" then return gine.env.LEFT end

		if mode == "right" then return gine.env.RIGHT end

		if mode == "top" then return gine.env.TOP end

		if mode == "bottom" then return gine.env.BOTTOM end

		return gine.env.NODOCK or 0
	end

	function META:SetCursor(typ)
		if self.__obj.mouse_input then self.__obj.mouse_input:SetCursor(typ) end
	end

	function META:SetContentAlignment(num)
		self.__obj.content_alignment = num
		reset_panel_layout(self.__obj)
	end

	function META:SetExpensiveShadow(dir, color)
		self.__obj.expensive_shadow_dir = dir
		self.__obj.expensive_shadow_color = HostColor.FromBytes(color.r or 0, color.g or 0, color.b or 0, color.a or 255)
	end

	function META:SetPaintBorderEnabled() end

	function META:SetPaintBackgroundEnabled(b)
		self.__obj.paint_bg = b
	end

	function META:SetDrawOnTop(b)
		self.__obj.draw_ontop = b

		if b then promote_panel_overlay_order(self.__obj) end
	end

	do -- z pos stuff
		function META:SetZPos(pos)
			pos = pos or 0
			self.__obj:SetChildOrder(pos)
			local parent = get_panel_logical_parent(self.__obj)

			if parent and parent.gmod_logical_children then
				table.sort(parent.gmod_logical_children, function(a, b)
					local order_a = a.ChildOrder or 0
					local order_b = b.ChildOrder or 0

					if order_a ~= order_b then return order_a < order_b end

					return (a.gmod_logical_child_sequence or 0) < (b.gmod_logical_child_sequence or 0)
				end)
			end
		end

		function META:MoveToBack()
			self.__obj:SendToBack()
		end

		function META:MoveToFront()
			if self.__obj.popup or self.__obj.draw_ontop then
				promote_panel_overlay_order(self.__obj)
			end

			self.__obj:BringToFront()
		end

		function META:MakePopup()
			local old_raw_parent = self.__obj:GetParent()
			local world_pos = self.__obj.transform:GetPosition():Copy()
			refresh_gui_world_bounds()

			if old_raw_parent and old_raw_parent:IsValid() and old_raw_parent.transform then
				world_pos = transform_local_to_world(old_raw_parent.transform, world_pos)
			end

			self.__obj.popup = true
			set_panel_clipping(self.__obj, false)

			if self.__obj:GetParent() ~= gine.gui_world then
				reparent_panel_silently(self.__obj, gine.gui_world)
			end

			self.__obj.transform:SetPosition(world_pos)
			bring_gui_world_to_front()
			promote_panel_overlay_order(self.__obj)
			self.__obj:BringToFront()
			self.__obj:RequestFocus()

			if gine.env and gine.env.gui and gine.env.gui.EnableScreenClicker then
				gine.env.gui.EnableScreenClicker(true)
			end

			if self.__obj.mouse_input then
				self.__obj.mouse_input:SetIgnoreMouseInput(false)
			end

			if self.__obj.vgui_type == "textentry" then
				set_panel_editable(self.__obj, true)
				set_panel_allow_keyboard_input(self.__obj, true)
				set_panel_focus_on_click(self.__obj, true)
			else
				for _, child in ipairs(self.__obj:GetChildrenList()) do
					if child.vgui_type == "textentry" then
						set_panel_editable(child, true)
						set_panel_allow_keyboard_input(child, true)
						set_panel_focus_on_click(child, true)
					end
				end

				if not self.in_layout then
					self:InvalidateLayout(true)
					invalidate_panel_children_now(self.__obj)
				end
			end
		end
	end

	function META:NoClipping(b) end

	function META:ParentToHUD() end

	function META:DrawFilledRect()
		gine.env.surface.DrawRect(0, 0, self:GetSize())
	end

	function META:DrawOutlinedRect()
		gine.env.surface.DrawOutlinedRect(0, 0, self:GetSize())
	end

	function META:SetWrap(b)
		self.__obj.gmod_wrap = b
	end

	--function META:SetWorldClicker() end
	function META:SetAllowNonAsciiCharacters() end

	do -- html
		function META:IsLoading()
			return true
		end

		function META:NewObject(obj) end

		function META:NewObjectCallback(obj, func) end

		function META:OpenURL() end

		function META:SetHTML() end
	end

	-- edit
	do
		function META:GetCaretPos()
			return get_panel_caret_sub_position(self.__obj)
		end

		function META:SetCaretPos(pos)
			if self.__obj.vgui_type == "textentry" then
				set_panel_caret_sub_position(self.__obj, pos)
			end
		end

		function META:GotoTextEnd()
			if self.__obj.vgui_type == "textentry" then
				set_panel_caret_sub_position(self.__obj, math.huge)
			elseif self.__obj.vgui_type == "richtext" then
				self.__obj:SetScrollFraction(Vec2(0, 1))
			end
		end

		function META:GotoTextStart()
			if self.__obj.vgui_type == "textentry" then
				set_panel_caret_sub_position(self.__obj, 0)
			elseif self.__obj.vgui_type == "richtext" then
				self.__obj:SetScrollFraction(Vec2(0, 0))
			end
		end

		function META:SetVerticalScrollbarEnabled(b) end

		function META:AppendText(str)
			str = gine.translation2[str] or str
			self.__obj.text.markup:AddString(str)
		end

		function META:InsertColorChange(r, g, b, a)
			self.__obj.text.markup:AddColor(HostColor.FromBytes(r or 0, g or 0, b or 0, a or 255))
		end

		function META:DrawTextEntryText(text_color, highlight_color, cursor_color)
			self.__obj.label:DrawTextEntryText()
		end

		function META:SelectAllText()
			self:SelectAll()
		end
	end

	function META:HasFocus()
		local focused = prototype.GetFocusedObject()
		return focused ~= nil and focused == self.__obj
	end

	function META:SetEnabled(b)
		self.__obj.gine_enabled = b ~= false
	end

	function META:IsEnabled()
		return self.__obj.gine_enabled ~= false
	end

	function META:HasHierarchicalFocus()
		local focused = prototype.GetFocusedObject()

		if not (focused and focused:IsValid()) then return false end

		return focused == self.__obj or self.__obj:HasChild(focused)
	end

	function META:SetPaintedManually(b)
		self.__obj.draw_manual = b
	end

	do
		local in_drawing

		function META:PaintAt(x, y, w, h)
			if in_drawing then return end

			self.__obj.in_paint_manual = true
			in_drawing = true
			render2d.PushMatrix()

			if x or y then render2d.Translate(x or 0, y or 0) end

			self.__obj:OnDraw()
			render2d.PopMatrix()
			in_drawing = false
			self.__obj.in_paint_manual = false
		end

		function META:PaintManual()
			if in_drawing then return end

			self.__obj.in_paint_manual = true
			in_drawing = true
			self.__obj:OnDraw()
			in_drawing = false
			self.__obj.in_paint_manual = false
		end
	end

	function META:SetPlayer(ply, size)
		return self:SetSteamID(ply:SteamID64(), size)
	end

	function META:SetSteamID(id, size)
		do
			return
		end

		http.Get("http://steamcommunity.com/id/" .. id .. "/?xml=1", function(data)
			local url = data.content:match("<avatarFull>(.-)</avatarFull>")
			url = url and url:match("%[(http.-)%]")

			if url then
				self:SetTexture(Texture(url))
			else
				self:SetTexture(render.GetErrorTexture())
			end
		end)
	end

	function META:RequestFocus()
		if self.__obj.vgui_type == "textentry" then
			self:SetKeyboardInputEnabled(true)
		end

		self.__obj:RequestFocus()
	end

	function META:SetMultiline(b)
		if self.__obj.vgui_type == "textentry" then
			set_panel_multiline(self.__obj, b)
		elseif self.__obj.vgui_type == "richtext" then
			set_panel_multiline(self.__obj, b)
		end
	end

	function META:IsMultiline()
		if self.__obj.vgui_type == "textentry" then
			return get_panel_multiline(self.__obj)
		elseif self.__obj.vgui_type == "richtext" then
			return get_panel_multiline(self.__obj)
		end
	end

	function META:SetFocusTopLevel() end

	function META:SetDrawLanguageIDAtLeft() end

	function META:DoModal()
		self.__obj:RequestFocus()
	end

	function META:SetWorldClicker() end

	function META:FocusNext() end
end
