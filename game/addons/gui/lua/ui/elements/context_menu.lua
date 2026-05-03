local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local MenuContainer = import("lua/ui/elements/menu_container.lua")
local theme = import("lua/ui/theme.lua")

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

return function(props)
	props = props or {}
	local container = NULL
	local root_menu = NULL
	local pending_root_children = {}
	local menu_chain = {}
	local is_closing = false
	local is_relaying = false
	local update_animations

	local function root_menu_is_valid()
		return root_menu and root_menu.IsValid and root_menu:IsValid()
	end

	local function close_immediately()
		if props.OnClose and container:IsValid() then
			return props.OnClose(container)
		end

		if container:IsValid() then container:Remove() end
	end

	local function close_from_level(level)
		for index = #menu_chain, level, -1 do
			local menu = menu_chain[index]

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

			menu_chain[index] = nil
		end
	end

	local function update_menu_position(menu)
		if not menu:IsValid() or not menu.transform then return end

		local world_size = get_world_size(container)
		local menu_size = get_menu_size(menu)
		local position = menu.transform.GetPosition and
			menu.transform:GetPosition() or
			props.Position or
			Vec2(100, 100)

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

	local function request_close(relay_button)
		if is_closing then return true end

		is_closing = true
		close_from_level(2)

		if press and key == "escape" then return request_close() end

		if container.mouse_input then container.mouse_input:SetIgnoreMouseInput(true) end

		if root_menu_is_valid() then
			update_animations(container)
		else
			close_immediately()
		end

		if relay_button and not is_relaying then
			is_relaying = true

			timer.Delay(0, function()
				is_relaying = false
				event.Call("MouseInput", relay_button, true)
			end)
		end

		return true
	end

	function update_animations(ent)
		if not root_menu_is_valid() then return end

		if is_closing then
			root_menu.transform:SetDrawScaleOffset(Vec2(1, 1))
		else
			root_menu.transform:SetDrawScaleOffset(Vec2(1, 0))
		end

		root_menu.animation:Animate{
			id = "menu_open_close",
			get = function()
				return root_menu.transform:GetDrawScaleOffset()
			end,
			set = function(value)
				root_menu.transform:SetDrawScaleOffset(Vec2(1, value.y))
			end,
			to = is_closing and Vec2(1, 0) or Vec2(1, 1),
			time = 0.2,
			interpolation = "outExpo",
			callback = function()
				if is_closing and ent:IsValid() then close_immediately() end
			end,
		}
		root_menu.animation:Animate{
			id = "menu_open_close_fade",
			get = function()
				return root_menu.gui_element:GetDrawAlpha()
			end,
			set = function(value)
				root_menu.gui_element:SetDrawAlpha(value)
			end,
			to = is_closing and 0 or 1,
			time = 1,
			interpolation = "outExpo",
		}
	end

	local function create_menu_frame(level, anchor, placement, size)
		return MenuContainer{
			IsInternal = true,
			Name = "ContextMenu",
			transform = {
				Pivot = Vec2(0, 0),
				Position = props.Position or Vec2(100, 100),
				Size = size or props.Size or "M",
			},
			layout = {
				Floating = true,
				FitWidth = true,
			},
			OnMouseInput = function()
				return true
			end,
			Ref = function(self)
				self.ContextMenuLevel = level
				self.ContextMenuAnchor = anchor
				self.ContextMenuPlacement = placement
				menu_chain[level] = self

				if level == 1 then
					self:RequestFocus()
					root_menu = self
					is_closing = false

					for _, child in ipairs(pending_root_children) do
						if child and child:IsValid() then self:AddChild(child) end
					end

					pending_root_children = {}
					update_menu_position(self)
					update_animations(container)
				else
					update_menu_position(self)
				end
			end,
			Events = {
				OnKeyInput = function(self, key, press)
					if press and key == "escape" then return request_close(nil, true) end
				end,
			},
		}
	end

	container = Panel.New{
		{
			Key = props.Key,
			SourceDropdown = props.SourceDropdown,
			SourceMenuBar = props.SourceMenuBar,
			Name = "ContextMenuContainer",
			PreChildAdd = function(self, child)
				if child.IsInternal then return end

				if root_menu_is_valid() then
					root_menu:AddChild(child)
				else
					table.insert(pending_root_children, child)
				end

				return false
			end,
			PreRemoveChildren = function()
				if root_menu_is_valid() then root_menu:RemoveChildren() end

				pending_root_children = {}
				return false
			end,
			transform = {
				Size = Vec2(render2d.GetSize()),
			},
			mouse_input = {
				BringToFrontOnClick = true,
				OnMouseInput = function(self, button, press)
					if not press then return end

					if button == "button_1" then return request_close() end

					if button == "button_2" then return request_close(button) end
				end,
			},
			OnVisibilityChanged = function(self, visible)
				if visible then is_closing = false else is_closing = true end

				update_animations(self)
			end,
			Events = {
				OnKeyInput = function(self, key, press)
					if press and key == "escape" then return request_close() end
				end,
			},
			gui_element = true,
			animation = true,
			clickable = true,
			layout = {
				Floating = true,
			},
		},
	}{
		create_menu_frame(1, props.Anchor, props.AnchorPlacement or "below_left", props.Size),
	}
	container.IsContextMenuContainer = true

	function container:CloseFromLevel(level)
		close_from_level(level)
	end

	function container:IsSubmenuOpenFor(item)
		if not item or not item:IsValid() then return false end

		for index = 2, #menu_chain do
			local menu = menu_chain[index]

			if menu and menu:IsValid() and menu.ContextMenuSourceItem == item then
				return true
			end
		end

		return false
	end

	function container:OpenSubmenu(item, submenu_props)
		if is_closing or not item or not item:IsValid() then return end

		local parent_menu = item:GetParent()

		if not parent_menu or not parent_menu:IsValid() then return end

		local level = (parent_menu.ContextMenuLevel or 1) + 1
		local items = resolve_children(submenu_props.Items or submenu_props.Submenu or submenu_props.Menu)
		close_from_level(level)

		if #items == 0 then return end

		local submenu = create_menu_frame(level, item, submenu_props.Placement or "right_top")
		submenu.ContextMenuSourceItem = item

		for _, child in ipairs(items) do
			submenu:AddChild(child)
		end

		self:AddChild(submenu)

		if item.SetSubmenuOpen then item:SetSubmenuOpen(true) end
	end

	container:AddLocalListener("OnDraw", function()
		if not container:IsValid() then return end

		for index = 1, #menu_chain do
			local menu = menu_chain[index]

			if menu and menu:IsValid() then update_menu_position(menu) end
		end
	end)

	return container
end
