local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")
local META = Panel:CreateTemplate("context_menu")
META.Name = "ContextMenu"
META.CMP.transform = {}
META.CMP.layout = {
	Floating = true,
}
META.CMP.mouse_input = {
	BringToFrontOnClick = true,
	OnMouseInput = function(self, button, press)
		if not press then return end

		if button == "button_1" then return self.Owner:RequestClose() end

		if button == "button_2" then return self.Owner:RequestClose(button) end
	end,
}
META.CMP.gui_element = {}
META.CMP.animation = {}

function META:OnCreate(props)
	self.BaseClass.OnCreate(self, props)
	self.IsContextMenuContainer = true
	self.contextMenuRoot = nil
	self.contextMenuIsClosing = false
	self.contextMenuIsRelaying = false
	self.contextMenuAnchor = props.Anchor
	self.contextMenuAnchorPlacement = props.AnchorPlacement or "below_left"
	self.contextMenuSize = props.Size
	self.contextMenuOnClose = props.OnClose
	self.contextMenuOnClosing = props.OnClosing
	self.SourceDropdown = props.SourceDropdown
	self.SourceMenuBar = props.SourceMenuBar

	self:AddLocalListener("OnVisibilityChanged", function(self, visible)
		self.contextMenuIsClosing = not visible
		self:updateAnimations()
	end)

	self:AddLocalListener("OnKeyInput", function(self, key, press)
		if press and key == "escape" then return self:RequestClose() end
	end)

	self:AddLocalListener("OnDraw", function(self)
		for _, menu in ipairs(self:GetChildren()) do
			self:updateMenuPosition(menu)
		end
	end)

	local root = MenuContainer{
		IsInternal = true,
		Name = "ContextMenu",
		transform = {
			Pivot = Vec2(0, 0),
			Position = props.Position or Vec2(100, 100),
			Size = props.Size or "M",
		},
		layout = {
			Floating = true,
			FitWidth = true,
		},
		OnMouseInput = function()
			return true
		end,
	}
	root.ContextMenuLevel = 1
	root.ContextMenuAnchor = self.contextMenuAnchor
	root.ContextMenuPlacement = self.contextMenuAnchorPlacement
	self.contextMenuRoot = root
	self.transform:SetSize(Vec2(render2d.GetSize()))
	root:RequestFocus()
	self:AddChild(root)
	self:updateMenuPosition(root)
	self:updateAnimations()
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self.contextMenuRoot:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self.contextMenuRoot:RemoveChildren()
	return false
end

function META:getSubmenus()
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

			if y + menu_size.y > world_size.y then y = math.max(0, ay - menu_size.y) end
		end

		return Vec2(math.max(0, x), math.max(0, y))
	end

	function META:updateMenuPosition(menu)
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

		menu.transform:SetPosition(position)
	end
end

function META:updateAnimations()
	local root = self.contextMenuRoot

	if self.contextMenuIsClosing then
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
		to = self.contextMenuIsClosing and Vec2(1, 0) or Vec2(1, 1),
		time = 0.2,
		interpolation = "outExpo",
		callback = function()
			if self.contextMenuIsClosing then self:closeImmediately() end
		end,
	}
	root.animation:Animate{
		id = "menu_open_close_fade",
		get = function()
			return root.gui_element:GetDrawAlpha()
		end,
		set = function(value)
			root.gui_element:SetDrawAlpha(value)
		end,
		to = self.contextMenuIsClosing and 0 or 1,
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

	function META:closeImmediately()
		clear_pressed(self.contextMenuRoot)

		if self.contextMenuOnClose then return self.contextMenuOnClose(self) end

		self:Remove()
	end

	function META:CloseFromLevel(level)
		for _, menu in ipairs(self:getSubmenus()) do
			if menu.ContextMenuLevel >= level then
				menu.ContextMenuSourceItem:SetSubmenuOpen(false)
				clear_pressed(menu)
				menu:Remove()
			end
		end
	end
end

function META:RequestClose(relay_button)
	if self.contextMenuIsClosing then return true end

	self.contextMenuIsClosing = true
	self:CloseFromLevel(2)

	if self.contextMenuOnClosing then self.contextMenuOnClosing(self) end

	self.mouse_input:SetIgnoreMouseInput(true)
	self:updateAnimations()

	if relay_button and not self.contextMenuIsRelaying then
		self.contextMenuIsRelaying = true

		timer.Delay(0, function()
			self.contextMenuIsRelaying = false
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
	if self.contextMenuIsClosing then return end

	local parent_menu = item:GetParent()

	if not parent_menu:IsValid() then return end

	local level = (parent_menu.ContextMenuLevel or 1) + 1
	local items = resolve_children(submenu_props.Items or submenu_props.Submenu or submenu_props.Menu)
	self:CloseFromLevel(level)

	if #items == 0 then return end

	local submenu = MenuContainer{
		IsInternal = true,
		Name = "ContextMenu",
		transform = {
			Pivot = Vec2(0, 0),
			Position = item.transform:GetPosition() or Vec2(100, 100),
		},
		layout = {
			Floating = true,
			FitWidth = true,
		},
		OnMouseInput = function()
			return true
		end,
	}
	submenu.ContextMenuLevel = level
	submenu.ContextMenuAnchor = item
	submenu.ContextMenuPlacement = submenu_props.Placement or "right_top"
	submenu.ContextMenuSourceItem = item

	for _, child in ipairs(items) do
		submenu:AddChild(child)
	end

	if item.SetSubmenuOpen then item:SetSubmenuOpen(true) end

	-- Defer adding submenu so the current mouse release event completes first
	timer.Delay(0, function()
		if not self:IsValid() or not submenu:IsValid() then return end

		self:AddChild(submenu)
		self:updateMenuPosition(submenu)
	end)
end

META:Register()
return META.New
