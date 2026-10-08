local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")
local META = Panel:CreateTemplate("context_menu")
META.CMP.transform = {}
META.CMP.layout = {Floating = true}
META.CMP.mouse_input = {BringToFrontOnClick = true}
META.CMP.visual = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Anchor", nil)
META:GetSet("AnchorPlacement", "below_left", {enums = {"below_left", "right_top"}})
META:GetSet("SourceDropdown", nil)
META:GetSet("SourceMenuBar", nil)
META:EndStorable()

local function consume_mouse_input()
	return true
end

local function on_root_key_input(root, key, press)
	if press and key == "escape" then return root:GetParent():RequestClose() end
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self.IsContextMenuContainer = true
	self._closing = false
	self._relaying = false
	local root = MenuContainer{
		IsInternal = true,
		Name = "context_menu_root",
		transform = {
			Pivot = Vec2(0, 0),
			Position = props.Position or Vec2(100, 100),
			Size = props.Size or "M",
		},
		layout = {
			Floating = true,
			FitWidth = true,
		},
		OnMouseInput = consume_mouse_input,
		OnKeyInput = on_root_key_input,
	}
	root.ContextMenuLevel = 1
	root.ContextMenuAnchor = self.Anchor
	root.ContextMenuPlacement = self.AnchorPlacement
	self._root = root
	self.transform:SetSize(Vec2(render2d.GetSize()))
	self.transform:SetPosition(Vec2(0, 0))
	root:RequestFocus()
	self:AddChild(root)
	self:update_menu_position(root)
	self:update_animations()
end

function META:OnClose()
	self:Remove()
end

function META:OnClosing() end

function META:OnVisibilityChanged(visible)
	self._closing = not visible
	self:update_animations()
end

function META:OnMouseInput(button, press)
	if not press then return end

	if button == "button_1" then return self:RequestClose() end

	if button == "button_2" then return self:RequestClose(button) end
end

function META:OnDraw()
	local w, h = render2d.GetSize()
	local size = self.transform:GetSize()

	if size.x ~= w or size.y ~= h then self.transform:SetSize(Vec2(w, h)) end

	for _, menu in ipairs(self:GetChildren()) do
		self:update_menu_position(menu)
	end
end

function META:GetRootMenu()
	return self._root
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self._root:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self._root:RemoveChildren()
	return false
end

function META:get_submenus()
	local submenus = {}

	for _, menu in ipairs(self:GetChildren()) do
		if menu.ContextMenuLevel and menu.ContextMenuLevel > 1 then
			table.insert(submenus, menu)
		end
	end

	return submenus
end

do
	local function get_anchor_position(anchor, placement, menu_size, world_size)
		local ax, ay = anchor.transform:GetWorldMatrix():GetTranslation()
		local anchor_size = anchor.transform:GetSize()
		local x = ax
		local y = ay

		if placement == "right_top" then
			x = ax + anchor_size.x
			y = ay

			if x + menu_size.x > world_size.x then x = ax - menu_size.x end

			if y + menu_size.y > world_size.y then
				y = math.max(0, world_size.y - menu_size.y)
			end
		else
			x = ax
			y = ay + anchor_size.y

			if x + menu_size.x > world_size.x then
				x = math.max(0, world_size.x - menu_size.x)
			end

			if y + menu_size.y > world_size.y and ay > world_size.y - y then
				y = ay - menu_size.y
			end
		end

		return Vec2(math.max(0, x), math.max(0, y))
	end

	function META:update_menu_position(menu)
		local world_size = self.transform:GetSize()
		local menu_size = menu.transform:GetSize()
		local position = menu.transform:GetPosition() or Vec2(100, 100)

		if menu.ContextMenuAnchor and menu.ContextMenuAnchor:IsValid() then
			position = get_anchor_position(
				menu.ContextMenuAnchor,
				menu.ContextMenuPlacement or "below_left",
				menu_size,
				world_size
			)
		end

		menu.transform:SetPosition(
			Vec2(
				math.max(0, math.min(position.x, world_size.x - menu_size.x)),
				math.max(0, math.min(position.y, world_size.y - menu_size.y))
			)
		)
	end
end

function META:update_animations()
	local root = self._root

	if self._closing then
		root.transform:SetDrawScaleOffset(Vec2(1, 1))
	else
		root.transform:SetDrawScaleOffset(Vec2(1, 0))
	end

	root.animation:Animate{
		id = "menu_open_close",
		get = function()
			return root.transform:GetDrawScaleOffset()
		end,
		set = function(value)
			root.transform:SetDrawScaleOffset(Vec2(1, value.y))
		end,
		to = self._closing and Vec2(1, 0) or Vec2(1, 1),
		time = 0.2,
		interpolation = "outExpo",
		callback = function()
			if self._closing then self:close_immediately() end
		end,
	}
	root.animation:Animate{
		id = "menu_open_close_fade",
		get = function()
			return root.visual:GetDrawAlpha()
		end,
		set = function(value)
			root.visual:SetDrawAlpha(value)
		end,
		to = self._closing and 0 or 1,
		time = 1,
		interpolation = "outExpo",
	}
end

do
	local function clear_pressed(menu)
		for _, child in ipairs(menu:GetChildren()) do
			child:SetState("pressed", false)
		end
	end

	function META:close_immediately()
		clear_pressed(self._root)
		return self:OnClose()
	end

	function META:CloseFromLevel(level)
		for _, menu in ipairs(self:get_submenus()) do
			if menu.ContextMenuLevel >= level then
				menu.ContextMenuSourceItem:SetSubmenuOpen(false)
				clear_pressed(menu)
				menu:Remove()
			end
		end
	end
end

function META:RequestClose(relay_button)
	if self._closing then return true end

	self._closing = true
	self:CloseFromLevel(2)
	self:OnClosing()
	self.mouse_input:SetIgnoreMouseInput(true)
	self:update_animations()

	if relay_button and not self._relaying then
		self._relaying = true

		timer.Delay(0, function()
			self._relaying = false
			event.Call("MouseInput", relay_button, true)
		end)
	end

	return true
end

local function resolve_children(source)
	if type(source) == "function" then source = source() end

	return source or {}
end

function META:OpenSubmenu(item, submenu_props)
	if self._closing then return end

	local parent_menu = item:GetParent()

	if not parent_menu:IsValid() then return end

	local level = (parent_menu.ContextMenuLevel or 1) + 1
	local items = resolve_children(submenu_props.Items)
	self:CloseFromLevel(level)

	if #items == 0 then return end

	local submenu = MenuContainer{
		IsInternal = true,
		Name = "context_menu_submenu",
		transform = {
			Pivot = Vec2(0, 0),
			Position = item.transform:GetPosition(),
		},
		layout = {
			Floating = true,
			FitWidth = true,
		},
		OnMouseInput = consume_mouse_input,
	}
	submenu.ContextMenuLevel = level
	submenu.ContextMenuAnchor = item
	submenu.ContextMenuPlacement = submenu_props.Placement or "right_top"
	submenu.ContextMenuSourceItem = item

	for _, child in ipairs(items) do
		submenu:AddChild(child)
	end

	item:SetSubmenuOpen(true)
	self:AddChild(submenu)
	self:update_menu_position(submenu)
end

return META:Register()
