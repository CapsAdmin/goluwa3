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
local host_gui = _G.gui

local function ColorBytes(r, g, b, a)
	return HostColor.FromBytes(r or 0, g or 0, b or 0, a or 255)
end

local function ColorNorm(r, g, b, a)
	return HostColor.FromBytes((r or 0) * 255, (g or 0) * 255, (b or 0) * 255, (a or 1) * 255)
end

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

if not host_gui or not host_gui.CreatePanel then
	host_gui = {focus_panel = NULL}

	local function get_size_of_children(panel)
		local max_x = 0
		local max_y = 0

		for _, child in ipairs(panel:GetChildren()) do
			if child:IsValid() and child.transform then
				local pos = child.transform:GetPosition()
				local size = child.transform:GetSize()
				max_x = math.max(max_x, pos.x + size.x)
				max_y = math.max(max_y, pos.y + size.y)
			end
		end

		return Vec2(max_x, max_y)
	end

	local function attach_panel_api(panel, class_name)
		if panel._gmod_host_gui_ready then return panel end

		local function get_text_api()
			return rawget(panel, "text") or panel._gmod_text_proxy
		end

		panel._gmod_host_gui_ready = true
		panel.vgui_type = class_name or "base"
		panel.allow_keyboard_input = false
		panel.focus_on_click = false
		panel.bring_to_front_on_click = false
		panel.content_alignment = panel.content_alignment or 5
		panel.text_internal = panel.text_internal or ""
		panel.text_inset = panel.text_inset or Vec2(0, 0)
		panel.caret_pos = panel.caret_pos or 0
		panel.multiline = false
		panel.editable = false
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

		function panel:CreatePanel(kind, name)
			return host_gui.CreatePanel(kind, self, name)
		end

		function panel:SetNoDraw() end

		function panel:SetIgnoreLayout(b)
			self.ignore_layout = not not b

			if self.layout then self.layout:SetFloating(self.ignore_layout) end
		end

		function panel:SetIgnoreMouse(b)
			if self.mouse_input then self.mouse_input:SetIgnoreMouseInput(b) end
		end

		function panel:SetMultiline(b)
			self.multiline = not not b
			local text = get_text_api()

			if text and text.SetTextWrap then text:SetTextWrap(self.multiline) end
		end

		function panel:GetMultiline()
			return self.multiline
		end

		function panel:SetEditable(b)
			self.editable = not not b
			local text = get_text_api()

			if text and text.SetEditable then text:SetEditable(self.editable) end
		end

		function panel:SetAllowKeyboardInput(b)
			self.allow_keyboard_input = not not b
		end

		function panel:GetAllowKeyboardInput()
			return self.allow_keyboard_input
		end

		function panel:SetFocusOnClick(b)
			self.focus_on_click = not not b

			if self.mouse_input then self.mouse_input:SetFocusOnClick(b) end
		end

		function panel:SetBringToFrontOnClick(b)
			self.bring_to_front_on_click = not not b

			if self.mouse_input then self.mouse_input:SetBringToFrontOnClick(b) end
		end

		function panel:SetClipping(b)
			if self.gui_element then self.gui_element:SetClipping(b) end
		end

		function panel:SetMargin(rect)
			if self.layout then self.layout:SetMargin(rect) end
		end

		function panel:GetMargin()
			return self.layout and self.layout:GetMargin() or Rect()
		end

		function panel:SetPadding(rect)
			if self.layout then self.layout:SetPadding(rect) end
		end

		function panel:GetPadding()
			return self.layout and self.layout:GetPadding() or Rect()
		end

		function panel:GetDockPadding()
			local padding = self:GetPadding()
			return padding.x or 0, padding.y or 0, padding.w or 0, padding.h or 0
		end

		function panel:ResetLayout()
			if self.layout then self.layout:InvalidateLayout() end

			if self.OnPostLayout then self:OnPostLayout() end
		end

		panel.Layout = panel.ResetLayout

		function panel:SetupLayout(mode)
			self.layout_mode = mode

			if self.layout then self.layout:SetFloating(mode == nil) end
		end

		function panel:SetPanel(child)
			self._gmod_text_proxy = child

			if child and child.IsValid and child:IsValid() then child:SetParent(self) end
		end

		function panel:SetText(text)
			self.text_internal = tostring(text or "")
			text = get_text_api()

			if text and text.SetText then text:SetText(self.text_internal) end
		end

		function panel:GetText()
			local text = get_text_api()

			if text and text.GetText then return text:GetText() end

			return self.text_internal or ""
		end

		function panel:SetParseTags() end

		function panel:SetCaretSubPosition(pos)
			self.caret_pos = math.max(0, tonumber(pos) or 0)
		end

		function panel:GetCaretSubPosition()
			return self.caret_pos or 0
		end

		function panel:SelectAll() end

		function panel:SetPosition(pos)
			self.transform:SetPosition(pos)
		end

		function panel:GetPosition()
			return self.transform:GetPosition()
		end

		function panel:SetX(x)
			self.transform:SetX(x)
		end

		function panel:SetY(y)
			self.transform:SetY(y)
		end

		function panel:GetX()
			return self.transform:GetX()
		end

		function panel:GetY()
			return self.transform:GetY()
		end

		function panel:SetSize(size)
			self.transform:SetSize(size)
		end

		function panel:GetSize()
			return self.transform:GetSize()
		end

		function panel:GetWidth()
			return self.transform:GetWidth()
		end

		function panel:GetHeight()
			return self.transform:GetHeight()
		end

		function panel:SetVisible(b)
			if self.gui_element then self.gui_element:SetVisible(b) end
		end

		function panel:IsVisible()
			return self.gui_element and self.gui_element:GetVisible() or true
		end

		function panel:GetMousePosition()
			if self.mouse_input then return self.mouse_input:GetMousePosition() end

			return Vec2()
		end

		function panel:IsMouseOver()
			return self.mouse_input and self.mouse_input:IsHoveredExclusively() or false
		end

		function panel:RequestFocus()
			prototype.SetFocusedObject(self)
			host_gui.focus_panel = self
		end

		function panel:IsFocused()
			return prototype.GetFocusedObject() == self
		end

		function panel:MakePopup()
			self:RequestFocus()
		end

		function panel:GlobalMouseCapture(b)
			self.global_mouse_capture = not not b
		end

		function panel:SetCursor(cursor)
			if self.mouse_input then self.mouse_input:SetCursor(cursor) end
		end

		function panel:LocalToWorld(pos)
			return transform_local_to_world(self.transform, pos)
		end

		function panel:LocalToGlobal(pos)
			return transform_local_to_world(self.transform, pos)
		end

		function panel:WorldToLocal(pos)
			return transform_world_to_local(self.transform, pos)
		end

		function panel:GetSizeOfChildren()
			return get_size_of_children(self)
		end

		function panel:SizeToChildren()
			self:SetSize(self:GetSizeOfChildren())
		end

		function panel:SizeToChildrenWidth()
			local size = self:GetSizeOfChildren()
			self:SetSize(Vec2(size.x, self:GetHeight()))
		end

		function panel:SizeToChildrenHeight()
			local size = self:GetSizeOfChildren()
			self:SetSize(Vec2(self:GetWidth(), size.y))
		end

		return panel
	end

	function host_gui.GetHoveringPanel()
		return NULL
	end

	function host_gui.CreatePanel(class_name, parent, name)
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

		attach_panel_api(panel, class_name)
		panel:SetIgnoreLayout(true)

		if class_name == "text_edit" or class_name == "text" then
			panel.text:SetEditable(class_name == "text_edit")
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
			panel:SetParent(parent)
		else
			panel:SetParent(Panel.World)
		end

		return panel
	end
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
				tbl[i] = ColorBytes(v.r, v.g, v.b, v.a)
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
		local pnl = host_gui and host_gui.GetHoveringPanel and host_gui.GetHoveringPanel()

		if pnl:IsValid() then return gine.WrapObject(pnl, "Panel") end
	end

	function vgui.FocusedHasParent(parent)
		if host_gui and host_gui.focus_panel and host_gui.focus_panel:IsValid() and parent then
			return parent.__obj:HasChild(host_gui.focus_panel)
		end
	end

	function vgui.GetKeyboardFocus()
		return vgui.GetHoveredPanel()
	end

	function vgui.CursorVisible()
		return get_window():GetCursor() ~= "trapped"
	end

	function vgui.GetWorldPanel()
		return gine.WrapObject(gine.gui_world, "Panel")
	end
end

do
	local derma = gine.env.derma

	local function ensure_skin_defaults(skin)
		skin = skin or {}
		skin.Colours = skin.Colours or {}
		skin.Colours.Label = skin.Colours.Label or {}
		skin.Colours.Label.Default = skin.Colours.Label.Default or ColorNorm(1, 1, 1, 1)
		skin.Colours.Label.Bright = skin.Colours.Label.Bright or skin.Colours.Label.Default
		skin.Colours.Label.Dark = skin.Colours.Label.Dark or ColorNorm(0.25, 0.25, 0.25, 1)
		skin.Colours.Label.Highlight = skin.Colours.Label.Highlight or ColorNorm(1, 0.82, 0.22, 1)
		return skin
	end

	derma.Controls = derma.Controls or {}
	derma.SkinList = derma.SkinList or {}
	derma.DefaultSkin = ensure_skin_defaults(
		derma.DefaultSkin or
			{
				Colours = {
					Label = {
						Default = ColorNorm(1, 1, 1, 1),
						Bright = ColorNorm(1, 1, 1, 1),
						Dark = ColorNorm(0.25, 0.25, 0.25, 1),
						Highlight = ColorNorm(1, 0.82, 0.22, 1),
					},
				},
			}
	)

	function derma.DefineControl(name, description, panel, base)
		panel.Derma = {
			ClassName = name,
			Description = description,
			BaseClass = base,
		}
		gine.env.vgui.Register(name, panel, base)
		derma.Controls[name] = panel.Derma
		_G[name] = panel
		return panel
	end

	function derma.GetControlList()
		return derma.Controls
	end

	function derma.DefineSkin(name, description, skin)
		skin = ensure_skin_defaults(skin)
		skin.Name = name
		skin.Description = description
		derma.SkinList[name] = skin

		if name == "Default" or not next(derma.DefaultSkin) then
			derma.DefaultSkin = ensure_skin_defaults(skin)
		end

		return skin
	end

	function derma.GetNamedSkin(name)
		return ensure_skin_defaults(derma.SkinList[name])
	end

	function derma.GetDefaultSkin()
		return ensure_skin_defaults(derma.DefaultSkin)
	end

	function derma.SkinHook(kind, name, panel, ...)
		local skin = panel and panel.GetSkin and panel:GetSkin() or derma.GetDefaultSkin()
		local func = skin and skin[kind .. name]

		if func then return func(skin, panel, ...) end
	end

	function derma.RefreshSkins() end

	function derma.Color(_, _, default)
		return default
	end
end

function gine.env.Derma_Hook(panel, functionname, hookname, typename)
	panel[functionname] = function(self, ...)
		return gine.env.derma.SkinHook(hookname, typename, self, ...)
	end
end

function gine.env.Derma_Install_Convar_Functions(PANEL)
	function PANEL:SetConVar(strConVar)
		self.m_strConVar = strConVar
	end

	function PANEL:ConVarChanged(strNewValue)
		if not self.m_strConVar or #self.m_strConVar < 2 then return end

		gine.env.RunConsoleCommand(self.m_strConVar, tostring(strNewValue))
	end

	function PANEL:ConVarStringThink()
		if not self.m_strConVar or #self.m_strConVar < 2 then return end

		local strValue = gine.env.GetConVarString(self.m_strConVar)

		if self.m_strConVarValue == strValue then return end

		self.m_strConVarValue = strValue

		if self.SetValue then self:SetValue(self.m_strConVarValue) end
	end

	function PANEL:ConVarNumberThink()
		if not self.m_strConVar or #self.m_strConVar < 2 then return end

		local numValue = gine.env.GetConVarNumber(self.m_strConVar)

		if numValue ~= numValue or self.m_strConVarValue == numValue then return end

		self.m_strConVarValue = numValue

		if self.SetValue then self:SetValue(self.m_strConVarValue) end
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

		gine.gui_world:SetPosition(Vec2(0, 0))
		gine.gui_world:SetSize(wnd:GetSize())
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
			gine.gui_world = host_gui.CreatePanel("base")
			gine.gui_world:SetNoDraw(true)
			gine.gui_world:SetIgnoreLayout(true)
			--gine.gui_world:SetIgnoreMouse(true)
			gine.gui_world.__class = "CGModBase"

			function gine.gui_world:OnLayout()
				self:SetPosition(Vec2(0, 0))
				self:SetSize(get_window():GetSize())
			end
		end

		refresh_gui_world_bounds()
		class = class:lower()
		local obj

		if class == "textentry" then
			obj = host_gui.CreatePanel("text_edit")
			obj:SetMultiline(false)
			obj:SetEditable(false)
			obj.label.markup:SetPreserveTabsOnEnter(false)
			--local draw_func = obj.label.OnPostDraw
			obj.label.DrawTextEntryText = function() end
		--obj.label.OnPostDraw = function() end
		elseif class == "richtext" then
			obj = host_gui.CreatePanel("scroll")
			local markup = obj:CreatePanel("text", "text")
			markup:SetParseTags(false)
			obj:SetPanel(markup)
		else
			obj = host_gui.CreatePanel("base")
		end

		local self = gine.WrapObject(obj, "Panel")
		obj:SetName("gmod_" .. name)
		obj.gine_pnl = self
		self.__class = requested_class
		self.ClassName = requested_class

		if control then self.BaseClass = control end

		obj.fg_color = ColorNorm(1, 1, 1, 1)
		obj.bg_color = ColorNorm(1, 1, 1, 1)
		obj.text_inset = Vec2()
		obj.text_offset = Vec2()
		obj.vgui_type = class
		--self:SetPaintBackgroundEnabled(true)
		obj:SetSize(Vec2(64, 24))
		obj:SetMargin(Rect())
		obj:SetPadding(Rect())
		obj:ResetLayout()
		--		obj:SetAllowKeyboardInput(false)
		obj:SetFocusOnClick(false)
		obj:SetBringToFrontOnClick(false)
		obj:SetClipping(true)
		self:SetContentAlignment(4)
		self:SetFontInternal("default")
		self:MouseCapture(false)
		self:SetParent(parent)

		if control and control.Init then control.Init(self) end

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
					panel.text_offset = (panel:GetSize() / 2) - (Vec2(w, h) / 2)
				elseif panel.content_alignment == 4 then
					panel.text_offset.x = 0
					panel.text_offset.y = (panel:GetHeight() / 2) - (h / 2)
				elseif panel.content_alignment == 6 then
					panel.text_offset.x = panel:GetWidth() - w
					panel.text_offset.y = (panel:GetHeight() / 2) - (h / 2)
				elseif panel.content_alignment == 2 then
					panel.text_offset.x = (panel:GetWidth() / 2) - (w / 2)
					panel.text_offset.y = panel:GetHeight() - h
				elseif panel.content_alignment == 8 then
					panel.text_offset.x = (panel:GetWidth() / 2) - (w / 2)
					panel.text_offset.y = 0
				elseif panel.content_alignment == 7 then
					panel.text_offset.x = 0
					panel.text_offset.y = 0
				elseif panel.content_alignment == 9 then
					panel.text_offset.x = panel:GetWidth() - w
					panel.text_offset.y = 0
				elseif panel.content_alignment == 1 then
					panel.text_offset.x = 0
					panel.text_offset.y = panel:GetHeight() - h
				elseif panel.content_alignment == 3 then
					panel.text_offset.x = panel:GetWidth() - w
					panel.text_offset.y = panel:GetHeight() - h
				end

				if w > panel:GetWidth() then panel.text_offset.x = 0 end

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

		obj.name_prepare = name
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

		self.__obj.gine_prepared = true

		if self.__obj.gine_prepare_layout then self:InvalidateLayout() end

		hook(self.__obj, "OnChildAdd", function(_, child)
			call_panel_method(self, "OnChildAdded", gine.WrapObject(child, "Panel"))
		end)

		hook(self.__obj, "OnChildRemove", function(_, child)
			call_panel_method(self, "OnChildRemoved", gine.WrapObject(child, "Panel"))
		end)
	end

	function META:GetClassName()
		return self.ClassName or ""
	end

	function META:IsMarkedForDeletion()
		return self.__obj.marked_for_deletion
	end

	function META:GetSkin()
		if type(self.Skin) == "string" then
			return gine.env.derma.GetNamedSkin(self.Skin) or gine.env.derma.GetDefaultSkin()
		end

		return self.Skin or gine.env.derma.GetDefaultSkin()
	end

	function META:SetSkin(name)
		if type(name) == "table" then
			self.Skin = name
		else
			self.Skin = gine.env.derma.GetNamedSkin(name) or gine.env.derma.GetDefaultSkin()
		end
	end

	function META:__tostring()
		return (
			"Panel: [name:Panel][class:%s][%s,%s,%s,%s]"
		):format(self.__class, self.x, self.y, self.w, self.h)
	end

	function META:__index(key)
		if key == "x" or key == "X" then
			return self.__obj:GetPosition().x
		elseif key == "y" or key == "Y" then
			return self.__obj:GetPosition().y
		elseif key == "w" or key == "W" then
			return self.__obj:GetSize().x
		elseif key == "h" or key == "H" then
			return self.__obj:GetSize().y
		elseif key == "Hovered" then
			return self.__obj:IsMouseOver()
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
			self.__obj:SetX(v)
		elseif k == "y" or k == "Y" then
			self.__obj:SetY(v)
		else
			rawset(self, k, v)
		end
	end

	META.__eq = nil -- no need
	function META:SetParent(panel)
		if panel and panel:IsValid() and panel.__obj and panel.__obj:IsValid() then
			self.__obj:SetParent(panel.__obj)
		else
			self.__obj:SetParent(gine.gui_world)
		end
	end

	function META:SetAutoDelete(b)
		self.__obj:SetRemoveOnParentRemove(b)
	end

	function META:GetChildren()
		local children = {}

		for k, v in pairs(self.__obj:GetChildren()) do
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
		self.__obj.fg_color.r = r / 255
		self.__obj.fg_color.g = g / 255
		self.__obj.fg_color.b = b / 255
		self.__obj.fg_color.a = (a or 255) / 255
	end

	function META:SetBGColor(r, g, b, a)
		self.__obj.bg_color.r = r / 255
		self.__obj.bg_color.g = g / 255
		self.__obj.bg_color.b = b / 255
		self.__obj.bg_color.a = (a or 255) / 255
	end

	function META:SetBackgroundColor(col)
		if not col then return end

		self:SetBGColor(col.r or 255, col.g or 255, col.b or 255, col.a or 255)
	end

	function META:GetBackgroundColor()
		local col = self.__obj.bg_color
		return gine.env.Color(col.r * 255, col.g * 255, col.b * 255, col.a * 255)
	end

	function META:CursorPos()
		return self.__obj:GetMousePosition():Unpack()
	end

	function META:GetPos()
		return self.__obj:GetPosition():Unpack()
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
		return self.__obj.Visible
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
		self.__obj:SetPosition(Vec2(x or 0, y or 0))
	end

	function META:HasChildren()
		return self.__obj:HasChildren()
	end

	function META:HasParent(panel)
		return panel.__obj:HasChild(self.__obj)
	end

	function META:DockMargin(left, top, right, bottom)
		self.__obj:SetMargin(Rect(right, bottom, left, top))
	end

	function META:DockPadding(left, top, right, bottom)
		self.__obj:SetPadding(Rect(left, top, right, bottom))
	end

	function META:GetDockPadding()
		local padding = self.__obj:GetPadding()
		return padding.x or 0, padding.y or 0, padding.w or 0, padding.h or 0
	end

	function META:SetMouseInputEnabled(b)
		self.__obj:SetIgnoreMouse(not b)
	end

	function META:MouseCapture(b)
		self.__obj:GlobalMouseCapture(b)
	end

	function META:SetKeyboardInputEnabled(b) --self.__obj:SetAllowKeyboardInput(b)
	end

	function META:IsKeyboardInputEnabled()
		return self.__obj:GetAllowKeyboardInput()
	end

	function META:GetWide()
		return self.__obj.transform:GetWidth()
	end

	function META:GetTall()
		return self.__obj.transform:GetHeight()
	end

	function META:SetWide(w)
		w = tonumber(w) or 0
		self.__obj.transform:SetWidth(w)
		self.__obj.LayoutSize = self.__obj.transform:GetSize():Copy()
	end

	function META:SetTall(h)
		h = tonumber(h) or 0
		self.__obj.transform:SetHeight(h)
		self.__obj.LayoutSize = self.__obj.transform:GetSize():Copy()
	end

	META.SetWidth = META.SetWide
	META.SetHeight = META.SetTall

	function META:SetSize(w, h)
		w = tonumber(w)
		h = tonumber(h) or w
		self.__obj:SetSize(Vec2(w, h))
		self.__obj.LayoutSize = Vec2(w, h)
	end

	function META:GetSize()
		return self.__obj:GetSize():Unpack()
	end

	function META:ChildrenSize()
		return self.__obj:GetSizeOfChildren():Unpack()
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
				self.__obj:SetText(text)
			elseif self.__obj.vgui_type == "richtext" then
				self.__obj:SetText(text)
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
		local parent = self.__obj:GetParent()

		if parent:IsValid() then return gine.WrapObject(parent, "Panel") end

		return nil
	end

	function META:InvalidateLayout(now)
		if self.in_layout then return end

		if now then
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

		return panel:GetSizeOfChildren():Unpack()
	end

	function META:GetTextSize()
		local panel = self.__obj
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
				text = wrap_text(font, text, panel.Parent:IsValid() and panel.Parent:GetWidth() or self:GetWide())
			elseif not text:find("\n", nil, true) then
				text = limit_text(font, text, self:GetWide())
			end
		end

		local w, h = font:GetTextSize(text)

		if panel.gmod_wrap and panel.Parent:IsValid() then
			w = panel.Parent:GetWidth()
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
			panel:SetSize(Vec2(panel.text_inset.x + w, panel.text_inset.y + h))
			panel.LayoutSize = panel:GetSize():Copy()
		end
	end

	function META:GetValue()
		if self.override_text then return self.override_text end

		return self:GetText()
	end

	function META:GetText()
		if self.__obj.vgui_type == "textentry" or self.__obj.vgui_type == "richtext" then
			return self.__obj:GetText()
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
			self.__obj:SizeToChildren()
		elseif size_w then
			self.__obj:SizeToChildrenWidth()
		elseif size_h then
			self.__obj:SizeToChildrenHeight()
		end
	--[[
		for _, v in ipairs(self.__obj.Children) do
			v.Size = v.old_size
		end

		self.__obj.LayoutSize = self.__obj.Size:Copy()]]
	end

	function META:SetVisible(b)
		self.__obj:SetVisible(b)
	end

	function META:Dock(enum)
		if enum == gine.env.FILL then
			self.__obj:SetupLayout("gmod_fill")
		elseif enum == gine.env.LEFT then
			self.__obj:SetupLayout("gmod_left")
		elseif enum == gine.env.RIGHT then
			self.__obj:SetupLayout("gmod_right")
		elseif enum == gine.env.TOP then
			self.__obj:SetupLayout("gmod_top")
		elseif enum == gine.env.BOTTOM then
			self.__obj:SetupLayout("gmod_bottom")
		elseif enum == gine.env.NODOCK then
			self.__obj:SetupLayout()
		end

		self.__obj.vgui_dock = enum
	end

	function META:GetDock()
		return self.__obj.vgui_dock or gine.env.NODOCK
	end

	function META:SetCursor(typ)
		self.__obj:SetCursor(typ)
	end

	function META:SetContentAlignment(num)
		self.__obj.content_alignment = num
		self.__obj:Layout()
	end

	function META:SetExpensiveShadow(dir, color)
		self.__obj.expensive_shadow_dir = dir
		self.__obj.expensive_shadow_color = ColorBytes(color.r, color.g, color.b, color.a)
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

		--function META:SetFocusTopLevel() end
		function META:MakePopup()
			self.__obj:BringToFront()
			self.__obj:RequestFocus()
			self.__obj:SetIgnoreMouse(false)
			self.__obj:MakePopup()

			if self.__obj.vgui_type == "textentry" then
				self.__obj:SetEditable(true)
				self.__obj:SetAllowKeyboardInput(true)
				self.__obj:SetFocusOnClick(true)
			else
				for _, child in ipairs(self.__obj:GetChildrenList()) do
					if child.vgui_type == "textentry" then
						child:SetEditable(true)
						child:SetAllowKeyboardInput(true)
						child:SetFocusOnClick(true)
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
			return self.__obj:GetCaretSubPosition()
		end

		function META:SetCaretPos(pos)
			if self.__obj.vgui_type == "textentry" then
				self.__obj:SetCaretSubPosition(pos)
			end
		end

		function META:GotoTextEnd()
			if self.__obj.vgui_type == "textentry" then
				self.__obj:SetCaretSubPosition(math.huge)
			elseif self.__obj.vgui_type == "richtext" then
				self.__obj:SetScrollFraction(Vec2(0, 1))
			end
		end

		function META:GotoTextStart()
			if self.__obj.vgui_type == "textentry" then
				self.__obj:SetCaretSubPosition(0)
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
			self.__obj.text.markup:AddColor(ColorBytes(r, g, b, a))
		end

		function META:DrawTextEntryText(text_color, highlight_color, cursor_color)
			self.__obj.label:DrawTextEntryText()
		end

		function META:SelectAllText()
			self.__obj:SelectAll()
		end
	end

	function META:HasFocus()
		return self.__obj:IsFocused()
	end

	function META:SetEnabled(b)
		self.__obj.gine_enabled = b
	end

	function META:IsEnabled()
		return not not self.__obj.gine_enabled
	end

	function META:HasHierarchicalFocus()
		for _, pnl in ipairs(self.__obj:GetChildrenList()) do
			if pnl.IsFocused and pnl:IsFocused() then return true end
		end

		return false
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
			self.__obj:SetMultiline(b)
		elseif self.__obj.vgui_type == "richtext" then
			self.__obj.text:SetTextWrap(b)
		end
	end

	function META:IsMultiline()
		if self.__obj.vgui_type == "textentry" then
			return self.__obj:GetMultiline()
		elseif self.__obj.vgui_type == "richtext" then
			return self.__obj.text:GetTextWrap()
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
