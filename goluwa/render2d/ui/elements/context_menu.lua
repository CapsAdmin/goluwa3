local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local MenuContainer = import("goluwa/render2d/ui/elements/menu_container.lua")

local META = Panel:CreateTemplate("context_menu")
META.Name = "ContextMenu"
META.CMP.transform = {
	Size = Vec2(render2d.GetSize()),
}
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
META.CMP.clickable = {}

local function resolve_children(source)
	if type(source) == "function" then source = source() end
	return source or {}
end

local function get_menu_size(menu)
	if not menu or not menu.transform then return Vec2() end
	return menu.transform:GetSize()
end

local function get_world_size(container)
	if container and container.IsValid and container:IsValid() and container.transform then
		return container.transform:GetSize()
	end
	if Panel.World and Panel.World.transform then
		return Panel.World.transform:GetSize()
	end
	return Vec2(render2d.GetSize())
end

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

	if x < 0 then x = 0 end
	if y < 0 then y = 0 end

	return Vec2(x, y)
end

local function resolve_anchor_position(anchor, placement, menu_size, world_size)
	if
		not anchor or
		not anchor.IsValid or
		not anchor:IsValid()
		or
		not anchor.transform or
		not anchor.transform.GetWorldMatrix or
		not anchor.transform.GetSize
	then
		return nil
	end
	return get_anchor_position(anchor, placement, menu_size, world_size)
end

function META:OnCreate(props)
	self.BaseClass.OnCreate(self, props)

	self.IsContextMenuContainer = true
	self.contextMenuChain = {}
	self.contextMenuRoot = nil
	self.contextMenuIsClosing = false
	self.contextMenuIsRelaying = false
	self.contextMenuPendingChildren = {}
	self.contextMenuAnchor = props.Anchor
	self.contextMenuAnchorPlacement = props.AnchorPlacement or "below_left"
	self.contextMenuPosition = props.Position or Vec2(100, 100)
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
		if not self:IsValid() then return end

		for index = 1, #self.contextMenuChain do
			local menu = self.contextMenuChain[index]
			if menu and menu:IsValid() then self:updateMenuPosition(menu) end
		end
	end)

	self:AddChild(self:createMenuFrame(1, self.contextMenuAnchor, self.contextMenuAnchorPlacement, self.contextMenuSize))
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	if self.contextMenuRoot and self.contextMenuRoot:IsValid() then
		self.contextMenuRoot:AddChild(child)
	else
		table.insert(self.contextMenuPendingChildren, child)
	end

	return false
end

function META:PreRemoveChildren()
	if self.contextMenuRoot and self.contextMenuRoot:IsValid() then
		self.contextMenuRoot:RemoveChildren()
	end
	self.contextMenuPendingChildren = {}
	return false
end

function META:rootMenuIsValid()
	return self.contextMenuRoot and self.contextMenuRoot.IsValid and self.contextMenuRoot:IsValid()
end

function META:createMenuFrame(level, anchor, placement, size)
	return MenuContainer{
		IsInternal = true,
		Name = "ContextMenu",
		transform = {
			Pivot = Vec2(0, 0),
			Position = self.contextMenuPosition,
			Size = size or self.contextMenuSize or "M",
		},
		layout = {
			Floating = true,
			FitWidth = true,
		},
		OnMouseInput = function()
			return true
		end,
		Ref = function(menu)
			menu.ContextMenuLevel = level
			menu.ContextMenuAnchor = anchor
			menu.ContextMenuPlacement = placement
			self.contextMenuChain[level] = menu

			if level == 1 then
				menu:RequestFocus()
				self.contextMenuRoot = menu
				self.contextMenuIsClosing = false

				for _, child in ipairs(self.contextMenuPendingChildren) do
					if child and child:IsValid() then menu:AddChild(child) end
				end

				self.contextMenuPendingChildren = {}
				self:updateMenuPosition(menu)
				self:updateAnimations()
			else
				self:updateMenuPosition(menu)
			end
		end,
		Events = {
			OnKeyInput = function(_, key, press)
				if press and key == "escape" then return self:RequestClose(nil, true) end
			end,
		},
	}
end

function META:updateMenuPosition(menu)
	if not menu:IsValid() or not menu.transform then return end

	local world_size = get_world_size(self)
	local menu_size = get_menu_size(menu)
	local position = menu.transform.GetPosition and
		menu.transform:GetPosition() or
		self.contextMenuPosition

	if menu.ContextMenuAnchor then
		position = resolve_anchor_position(
				menu.ContextMenuAnchor,
				menu.ContextMenuPlacement or "below_left",
				menu_size,
				world_size
			) or
			position
	end

	do
		local max_x = math.max(0, world_size.x - menu_size.x)
		local max_y = math.max(0, world_size.y - menu_size.y)
		position = Vec2(
			math.max(0, math.min(position.x, max_x)),
			math.max(0, math.min(position.y, max_y))
		)
	end

	menu.transform:SetPosition(position)
end

function META:updateAnimations()
	if not self.contextMenuRoot then return end
	if not self:rootMenuIsValid() then return end

	if self.contextMenuIsClosing then
		self.contextMenuRoot.transform:SetDrawScaleOffset(Vec2(1, 1))
	else
		self.contextMenuRoot.transform:SetDrawScaleOffset(Vec2(1, 0))
	end

	self.contextMenuRoot.animation:Animate{
		id = "menu_open_close",
		get = function()
			if not self.contextMenuRoot then return Vec2(1, 1) end
			return self.contextMenuRoot.transform:GetDrawScaleOffset()
		end,
		set = function(value)
			if not self.contextMenuRoot then return end
			self.contextMenuRoot.transform:SetDrawScaleOffset(Vec2(1, value.y))
		end,
		to = self.contextMenuIsClosing and Vec2(1, 0) or Vec2(1, 1),
		time = 0.2,
		interpolation = "outExpo",
		callback = function()
			if self.contextMenuIsClosing and self:IsValid() then self:closeImmediately() end
		end,
	}
	self.contextMenuRoot.animation:Animate{
		id = "menu_open_close_fade",
		get = function()
			if not self.contextMenuRoot then return 1 end
			return self.contextMenuRoot.gui_element:GetDrawAlpha()
		end,
		set = function(value)
			if not self.contextMenuRoot then return end
			self.contextMenuRoot.gui_element:SetDrawAlpha(value)
		end,
		to = self.contextMenuIsClosing and 0 or 1,
		time = 1,
		interpolation = "outExpo",
	}
end

function META:closeImmediately()
	if self.contextMenuOnClose and self:IsValid() then
		return self.contextMenuOnClose(self)
	end
	if self:IsValid() then self:Remove() end
end

function META:CloseFromLevel(level)
	for index = #self.contextMenuChain, level, -1 do
		local menu = self.contextMenuChain[index]

		if menu and menu:IsValid() then
			local source_item = menu.ContextMenuSourceItem

			if
				source_item and
				source_item.IsValid and
				source_item:IsValid() and
				source_item.SetSubmenuOpen
			then
				source_item:SetSubmenuOpen(false)
			end

			menu:Remove()
		end

		self.contextMenuChain[index] = nil
	end
end

function META:RequestClose(relay_button)
	if self.contextMenuIsClosing then return true end

	self.contextMenuIsClosing = true
	self:CloseFromLevel(2)

	if self.contextMenuOnClosing and self:IsValid() then self.contextMenuOnClosing(self) end

	if self.mouse_input then self.mouse_input:SetIgnoreMouseInput(true) end

	if self:rootMenuIsValid() then
		self:updateAnimations()
	else
		self:closeImmediately()
	end

	if relay_button and not self.contextMenuIsRelaying then
		self.contextMenuIsRelaying = true

		timer.Delay(0, function()
			self.contextMenuIsRelaying = false
			event.Call("MouseInput", relay_button, true)
		end)
	end

	return true
end

function META:IsSubmenuOpenFor(item)
	if not item or not item:IsValid() then return false end

	for index = 2, #self.contextMenuChain do
		local menu = self.contextMenuChain[index]

		if menu and menu:IsValid() and menu.ContextMenuSourceItem == item then
			return true
		end
	end

	return false
end

function META:OpenSubmenu(item, submenu_props)
	if self.contextMenuIsClosing or not item or not item:IsValid() then return end

	local parent_menu = item:GetParent()
	if not parent_menu or not parent_menu:IsValid() then return end

	local level = (parent_menu.ContextMenuLevel or 1) + 1
	local items = resolve_children(submenu_props.Items or submenu_props.Submenu or submenu_props.Menu)
	self:CloseFromLevel(level)

	if #items == 0 then return end

	local submenu = self:createMenuFrame(level, item, submenu_props.Placement or "right_top")
	submenu.ContextMenuSourceItem = item

	for _, child in ipairs(items) do
		submenu:AddChild(child)
	end

	self:AddChild(submenu)

	if item.SetSubmenuOpen then item:SetSubmenuOpen(true) end
end

META:Register()
return META.New