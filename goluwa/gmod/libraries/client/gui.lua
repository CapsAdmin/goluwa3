local window = import("goluwa/window.lua")
local system = import("goluwa/system.lua")
local Panel = import("goluwa/ecs/panel.lua")
local prototype = import("goluwa/prototype.lua")
local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local HostColor = import("goluwa/structs/color.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local render = import("goluwa/render/render.lua")

local function wrap_text(font, text, max_width)
	if gfx.WrapString then return gfx.WrapString(text, max_width, font) end

	if font and font.WrapString then return font:WrapString(text, max_width) end

	return text
end

local function limit_text(font, text, max_width)
	if gfx.DotLimitText then return gfx.DotLimitText(text, max_width, font) end

	return text
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

local function get_size_of_children(panel)
	local function accumulate_size(node, offset)
		local max_x = 0
		local max_y = 0

		for _, child in ipairs(node:GetChildren()) do
			if child:IsValid() and child.transform then
				local child_offset = offset + child.transform:GetPosition()

				if child.gmod_internal_dock then
					local nested_x, nested_y = accumulate_size(child, child_offset)
					max_x = math.max(max_x, nested_x)
					max_y = math.max(max_y, nested_y)
				else
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

local dock_modes = {
	gmod_fill = true,
	gmod_left = true,
	gmod_right = true,
	gmod_top = true,
	gmod_bottom = true,
}

local function is_internal_dock_panel(panel)
	return panel and panel.gmod_internal_dock or false
end

local function is_dock_mode(mode)
	return dock_modes[mode] or false
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
end

local function create_internal_dock_panel(parent, name)
	local panel = Panel.New{
		Name = name,
		transform = {
			Size = Vec2(1, 1),
		},
		layout = true,
		gui_element = true,
		mouse_input = true,
	}
	panel.gmod_internal_dock = true
	panel.suppress_child_add = true
	panel.mouse_input:SetIgnoreMouseInput(true)
	configure_layout_component(
		panel.layout,
		{
			floating = false,
			direction = "y",
			alignment_x = "stretch",
			alignment_y = "stretch",
			margin = Rect(),
			padding = Rect(),
		}
	)
	panel:SetParent(parent)
	panel.suppress_child_add = nil
	return panel
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
	if rawget(panel, "gmod_parent_override") ~= parent then
		parent.gmod_logical_child_sequence = (parent.gmod_logical_child_sequence or 0) + 1
		panel.gmod_logical_child_sequence = parent.gmod_logical_child_sequence
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

	for _, child in ipairs(panel:GetChildrenList()) do
		if
			child:IsValid() and
			not is_internal_dock_panel(child)
			and
			get_panel_logical_parent(child) == panel
		then
			out[#out + 1] = child
		end
	end

	table.sort(out, function(a, b)
		return (a.gmod_logical_child_sequence or 0) < (b.gmod_logical_child_sequence or 0)
	end)

	return out
end

local function configure_dock_host(panel)
	if not panel.layout then return end

	panel.layout:SetDirection("y")
	panel.layout:SetChildGap(0)
	panel.layout:SetAlignmentX("stretch")
	panel.layout:SetAlignmentY("stretch")
	panel.layout:InvalidateLayout()
end

local function ensure_dock_state(panel)
	local state = panel.gmod_dock_state

	if state and state.root and state.root:IsValid() then return state end

	configure_dock_host(panel)
	state = {
		root = create_internal_dock_panel(panel, (panel:GetName() or "panel") .. "_gmod_dock_root"),
	}
	configure_layout_component(
		state.root.layout,
		{
			floating = false,
			direction = "y",
			grow_height = 1,
			alignment_x = "stretch",
			alignment_y = "stretch",
			self_alignment_x = "stretch",
			margin = Rect(),
			padding = Rect(),
		}
	)
	panel.gmod_dock_state = state
	return state
end

local function detach_docked_children_to_parent(parent)
	for _, child in ipairs(get_logical_children(parent)) do
		if is_dock_mode(child.layout_mode) and child:GetParent() ~= parent then
			reparent_panel_silently(child, parent)
		end
	end
end

local function configure_split_container(panel, mode)
	if mode == "gmod_left" or mode == "gmod_right" then
		configure_layout_component(
			panel.layout,
			{
				floating = false,
				direction = "x",
				alignment_x = "start",
				alignment_y = "stretch",
				margin = Rect(),
				padding = Rect(),
			}
		)
	else
		configure_layout_component(
			panel.layout,
			{
				floating = false,
				direction = "y",
				alignment_x = "stretch",
				alignment_y = "start",
				margin = Rect(),
				padding = Rect(),
			}
		)
	end
end

local function configure_remainder_container(panel, mode)
	if mode == "gmod_left" or mode == "gmod_right" then
		configure_layout_component(
			panel.layout,
			{
				floating = false,
				direction = "y",
				grow_width = 1,
				alignment_x = "stretch",
				alignment_y = "stretch",
				self_alignment_y = "stretch",
				margin = Rect(),
				padding = Rect(),
			}
		)
	else
		configure_layout_component(
			panel.layout,
			{
				floating = false,
				direction = "y",
				grow_height = 1,
				alignment_x = "stretch",
				alignment_y = "stretch",
				self_alignment_x = "stretch",
				margin = Rect(),
				padding = Rect(),
			}
		)
	end

	panel.transform:SetPosition(Vec2())
	panel.transform:SetSize(Vec2(1, 1))
end

local function configure_docked_child(panel, mode)
	if not panel.layout then return end

	configure_layout_component(
		panel.layout,
		{
			floating = false,
			direction = panel.layout:GetDirection(),
			margin = panel.layout:GetMargin(),
			padding = panel.layout:GetPadding(),
		}
	)

	if mode == "gmod_fill" then
		panel.layout:SetGrowWidth(1)
		panel.layout:SetGrowHeight(1)
		panel.layout:SetSelfAlignmentX("stretch")
		panel.layout:SetSelfAlignmentY("stretch")
	elseif mode == "gmod_left" or mode == "gmod_right" then
		panel.layout:SetSelfAlignmentY("stretch")
	elseif mode == "gmod_top" or mode == "gmod_bottom" then
		panel.layout:SetSelfAlignmentX("stretch")
	end
end

local function clear_dock_state(parent)
	local state = parent.gmod_dock_state

	if not state or not state.root or not state.root:IsValid() then return end

	detach_docked_children_to_parent(parent)
	state.root:Remove()
	parent.gmod_dock_state = nil

	if parent.layout then parent.layout:InvalidateLayout() end
end

local function rebuild_panel_dock_layout(parent)
	if not parent or not parent:IsValid() then return end

	local logical_children = get_logical_children(parent)
	local has_docked_children = false

	for _, child in ipairs(logical_children) do
		if is_dock_mode(child.layout_mode) then
			has_docked_children = true

			break
		end
	end

	if not has_docked_children then
		clear_dock_state(parent)

		for _, child in ipairs(logical_children) do
			if child.layout then child.layout:SetFloating(true) end

			if child:GetParent() ~= parent then reparent_panel_silently(child, parent) end
		end

		return
	end

	local state = ensure_dock_state(parent)
	detach_docked_children_to_parent(parent)
	state.root:RemoveChildren()
	configure_layout_component(
		state.root.layout,
		{
			floating = false,
			direction = "y",
			grow_height = 1,
			alignment_x = "stretch",
			alignment_y = "stretch",
			self_alignment_x = "stretch",
			margin = Rect(),
			padding = Rect(),
		}
	)
	state.root.transform:SetPosition(Vec2())
	local remainder = state.root
	local filled = false

	for _, child in ipairs(logical_children) do
		local mode = child.layout_mode

		if not is_dock_mode(mode) then
			if child.layout then child.layout:SetFloating(true) end

			if child:GetParent() ~= parent then reparent_panel_silently(child, parent) end
		elseif not filled then
			configure_docked_child(child, mode)

			if mode == "gmod_fill" then
				configure_split_container(remainder, "gmod_top")
				reparent_panel_silently(child, remainder)
				filled = true
			else
				local next_remainder = create_internal_dock_panel(remainder, (parent:GetName() or "panel") .. "_gmod_dock_remainder")
				configure_split_container(remainder, mode)
				configure_remainder_container(next_remainder, mode)

				if mode == "gmod_right" or mode == "gmod_bottom" then
					remainder:AddChild(next_remainder)
					reparent_panel_silently(child, remainder)
				else
					reparent_panel_silently(child, remainder)
					remainder:AddChild(next_remainder)
				end

				remainder = next_remainder
			end
		else
			if child.layout then child.layout:SetFloating(true) end

			if child:GetParent() ~= parent then reparent_panel_silently(child, parent) end
		end
	end

	if parent.layout then parent.layout:InvalidateLayout() end
end

local function setup_panel_layout(panel, mode)
	panel.layout_mode = mode
	local logical_parent = get_panel_logical_parent(panel)

	if not is_dock_mode(mode) then
		if panel.layout then panel.layout:SetFloating(true) end
	else
		if panel.layout then panel.layout:SetFloating(false) end
	end

	if logical_parent and logical_parent:IsValid() then
		rebuild_panel_dock_layout(logical_parent)
	end
end

local function set_panel_child(panel, child)
	panel._gmod_text_proxy = child

	if child and child.IsValid and child:IsValid() then child:SetParent(panel) end
end

local function set_panel_text(panel, text)
	panel.text_internal = tostring(text or "")
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
	panel.vgui_type = class_name or panel.vgui_type or "base"
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
	vgui.registered = vgui.registered or {}

	function vgui.Register(name, panel, base)
		name = tostring(name)
		local stored = table.copy(panel)

		if base then
			local base_tbl = vgui.registered[base:lower()] or vgui.registered[base]

			if base_tbl then
				setmetatable(stored, {__index = base_tbl})
				stored.BaseClass = stored.BaseClass or base_tbl
			end
		end

		stored.ClassName = stored.ClassName or name
		stored.Base = stored.Base or base
		vgui.registered[name] = stored
		vgui.registered[name:lower()] = stored
		return stored
	end

	function vgui.RegisterTable(panel, base)
		local stored = table.copy(panel)

		if base then
			local base_tbl = vgui.GetControlTable(base) or base

			if type(base_tbl) == "table" then
				setmetatable(stored, {__index = base_tbl})
				stored.BaseClass = stored.BaseClass or base_tbl
			end
		end

		return stored
	end

	function vgui.GetControlTable(name)
		return vgui.registered[name] or vgui.registered[tostring(name):lower()]
	end

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
		local pnl = get_hovered_panel(Panel.World, get_window():GetMousePosition())

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

gine.env.matproxy = gine.env.matproxy or {}
gine.env.matproxy.stored = gine.env.matproxy.stored or {}
gine.env.matproxy.Add = gine.env.matproxy.Add or
	function(tbl)
		if tbl and tbl.name then gine.env.matproxy.stored[tbl.name] = tbl end

		return tbl
	end
gine.env.properties = gine.env.properties or {}
gine.env.properties.stored = gine.env.properties.stored or {}
gine.env.properties.Add = gine.env.properties.Add or
	function(name, tbl)
		if name then gine.env.properties.stored[name] = tbl end

		return tbl
	end
gine.env.properties.Get = gine.env.properties.Get or function()
	return gine.env.properties.stored
end

do
	local gui = gine.env.gui

	function gui.MousePos()
		return get_window():GetMousePosition():Unpack()
	end

	function gui.MouseX()
		return get_window():GetMousePosition().x
	end

	function gui.MouseY()
		return get_window():GetMousePosition().y
	end

	function gui.ScreenToVector(x, y)
		return gine.env.Vector(math3d.ScreenToWorldDirection(Vec2(x, y)):Unpack())
	end

	function gui.IsGameUIVisible()
		return menu.IsVisible()
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

		self:InvalidateLayout(true)
		obj.OnDraw = function()
			run_gmod_frame_hooks_once()

			if self.AnimationThink then self:AnimationThink() end

			if obj.draw_manual and not obj.in_paint_manual then return end

			if not obj.thought_1_frame then
				call_panel_method(self, "Think")
				obj.thought_1_frame = true
			end

			local w, h = obj.transform:GetWidth(), obj.transform:GetHeight()
			local paint_bg = call_panel_method(self, "Paint", w, h)

			if obj.paint_bg and paint_bg ~= nil then
				render2d.SetTexture()
				render2d.SetColor(obj.bg_color:Unpack())
				render2d.DrawRect(0, 0, w, h)
			end

			if class == "label" then
				if obj.text_internal and obj.text_internal ~= "" then
					local text = obj.text_internal
					local font = gine.render2d_fonts[obj.font_internal:lower()]

					if obj.gmod_wrap then
						text = wrap_text(font, text, w)
					else
						text = limit_text(font, text, w)
					end

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
		end

		obj:CallOnRemove(function()
			obj.marked_for_deletion = true
			call_panel_method(self, "OnDeletion")
		end)

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
			call_panel_method(self, "OnCursorMoved", x, y)
		end)

		hook(obj, "OnMouseEnter", function()
			gine.env.ChangeTooltip(self)
			call_panel_method(self, "OnCursorEntered")
		end)

		hook(obj, "OnMouseExit", function()
			gine.env.EndTooltip(self)
			call_panel_method(self, "OnCursorExited")
		end)

		hook(obj, "OnPostLayout", function()
			local panel = obj

			if panel.vgui_type == "label" then
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
			--panel.text_offset.x = panel.text_offset.x + panel:GetMargin():GetLeft()
			--panel.text_offset.y = panel.text_offset.y + panel:GetMargin():GetTop()
			end

			if not obj.gine_prepared then
				obj.gine_prepare_layout = true
			else
				self:InvalidateLayout(true)
			end
		end)

		hook(obj, "OnMouseInput", function(_, button, press)
			if button == "mwheel_down" then
				call_panel_method(self, "OnMouseWheeled", 1)
			elseif button == "mwheel_up" then
				call_panel_method(self, "OnMouseWheeled", -1)
			else
				if press then
					call_panel_method(self, "OnMousePressed", gine.GetMouseCode(button))
				else
					call_panel_method(self, "OnMouseReleased", gine.GetMouseCode(button))
				end
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

	local META = gine.GetMetaTable("Panel")

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

		local base = rawget(self, "BaseClass")

		if base then
			local inherited = resolve_inherited_value(base, key)

			if inherited ~= nil then return inherited end
		end

		local val = rawget(META, key)

		if val then return val end
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

		if self.__obj:GetParent() ~= new_parent then self.__obj:SetParent(new_parent) end

		if old_parent and old_parent:IsValid() and old_parent ~= new_parent then
			rebuild_panel_dock_layout(old_parent)
		end

		rebuild_panel_dock_layout(new_parent)
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
		return self:GetChildren()[idx - 1]
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
		return self.__obj.gui_element and self.__obj.gui_element:GetVisible() or true
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
		set_panel_margin(self.__obj, Rect(right, bottom, left, top))
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

	function META:SetSize(w, h)
		w = tonumber(w)
		h = tonumber(h) or w
		self.__obj.transform:SetSize(Vec2(w, h))
		self.__obj.LayoutSize = Vec2(w, h)
	end

	function META:GetSize()
		return self.__obj.transform:GetSize():Unpack()
	end

	function META:ChildrenSize()
		return get_size_of_children(self.__obj):Unpack()
	end

	function META:LocalToScreen(x, y)
		return transform_local_to_world(self.__obj.transform, Vec2(x or 0, y or 0)):Unpack()
	end

	function META:ScreenToLocal(x, y)
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
				self.__obj.text_internal = gine.translation2[text] or text
			--	self.__obj.label_settext = system.GetFrameNumber()
			end
		end
	end

	function META:SetAlpha(a)
		self.__obj.DrawAlpha = (a / 255) ^ 2
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
			call_panel_method(self, "ApplySchemeSettings")
			call_panel_method(
				self,
				"PerformLayout",
				self.__obj.transform:GetWidth(),
				self.__obj.transform:GetHeight()
			)
			self.in_layout = false
		else
			self.gine_layout = true
		end
	end

	function META:GetContentSize()
		local panel = self.__obj

		if panel.vgui_type == "label" then
			self.get_content_size = true
			local w, h = self:GetTextSize()
			self.get_content_size = false
			return w, h
		end

		return get_size_of_children(panel):Unpack()
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

		local w, h = font:GetTextSize(text)

		if
			panel.gmod_wrap and
			logical_parent and
			logical_parent:IsValid() and
			logical_parent.transform
		then
			w = logical_parent.transform:GetWidth()
		end

		return w + panel.text_inset.x, h + panel.text_inset.y
	end

	function META:SizeToContents()
		local panel = self.__obj

		if
			panel.vgui_type == "label" or
			self.__obj.vgui_type == "textentry" or
			self.__obj.vgui_type == "richtext"
		then
			local w, h = self:GetContentSize()
			--panel:Layout(true)
			panel.transform:SetSize(Vec2(panel.text_inset.x + w, panel.text_inset.y + h))
			panel.LayoutSize = panel.transform:GetSize():Copy()
		end
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
		elseif self.__obj.vgui_type == "label" then
			return self.__obj.text_internal
		end

		return ""
	end

	function META:SetTextInset(x, y)
		self.__obj.text_inset.x = x
		self.__obj.text_inset.y = y
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
		if size_w and size_h then
			self.__obj.transform:SetSize(get_size_of_children(self.__obj))
		elseif size_w then
			local size = get_size_of_children(self.__obj)
			self.__obj.transform:SetSize(Vec2(size.x, self.__obj.transform:GetHeight()))
		elseif size_h then
			local size = get_size_of_children(self.__obj)
			self.__obj.transform:SetSize(Vec2(self.__obj.transform:GetWidth(), size.y))
		end
	--[[
		for _, v in ipairs(self.__obj.Children) do
			v.Size = v.old_size
		end

		self.__obj.LayoutSize = self.__obj.Size:Copy()]]
	end

	function META:SetVisible(b)
		if self.__obj.gui_element then self.__obj.gui_element:SetVisible(b) end
	end

	function META:Dock(enum)
		if enum == gine.env.FILL then
			setup_panel_layout(self.__obj, "gmod_fill")
		elseif enum == gine.env.LEFT then
			setup_panel_layout(self.__obj, "gmod_left")
		elseif enum == gine.env.RIGHT then
			setup_panel_layout(self.__obj, "gmod_right")
		elseif enum == gine.env.TOP then
			setup_panel_layout(self.__obj, "gmod_top")
		elseif enum == gine.env.BOTTOM then
			setup_panel_layout(self.__obj, "gmod_bottom")
		elseif enum == gine.env.NODOCK then
			setup_panel_layout(self.__obj)
		end

		self.__obj.vgui_dock = enum
	end

	function META:GetDock()
		return self.__obj.vgui_dock or gine.env.NODOCK
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
		self.__obj:SetChildOrder(math.huge)
	end

	do -- z pos stuff
		function META:SetZPos(pos)
			pos = pos or 0
			self.__obj:SetChildOrder(-pos)
		end

		function META:MoveToBack() --self.__obj:Unfocus()
		end

		function META:MoveToFront() --self.__obj:BringToFront()
		end

		function META:MakePopup()
			self.__obj:BringToFront()
			self.__obj:RequestFocus()

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
		self.__obj.gine_enabled = b
	end

	function META:IsEnabled()
		return not not self.__obj.gine_enabled
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
