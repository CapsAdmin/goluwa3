local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local objects = import("goluwa/objects/objects.lua")
local Panel = objects.CreateTemplate("panel")
Panel.Base = import("goluwa/entities/base.lua")
local valid_components = {}

function Panel.RegisterComponent(name, meta)
	valid_components[name] = meta
end

function Panel.GetValidComponents()
	if not valid_components.animation then
		valid_components.animation = import("goluwa/render2d/ui/components/animation.lua")
		valid_components.clickable = import("goluwa/render2d/ui/components/clickable.lua")
		valid_components.ui_debug = import("goluwa/render2d/ui/components/ui_debug.lua")
		valid_components.visual = import("goluwa/render2d/ui/components/visual.lua")
		valid_components.key_input = import("goluwa/render2d/ui/components/key_input.lua")
		valid_components.layout = import("goluwa/render2d/ui/components/layout.lua")
		valid_components.mouse_input = import("goluwa/render2d/ui/components/mouse_input.lua")
		valid_components.rect = import("goluwa/render2d/ui/components/rect.lua")
		valid_components.resizable = import("goluwa/render2d/ui/components/resizable.lua")
		valid_components.style = import("goluwa/render2d/ui/components/style.lua")
		valid_components.text = import("goluwa/render2d/ui/components/text.lua")
		valid_components.transform = import("goluwa/render2d/ui/components/transform.lua")
		valid_components.draggable = import("goluwa/render2d/ui/components/draggable.lua")
		valid_components.snappable = import("goluwa/render2d/ui/components/snappable.lua")
	end

	return valid_components
end

Panel:GetSet("Tooltip", nil)
Panel:GetSet("TooltipOptions", nil)
Panel:GetSet("TooltipMaxWidth", nil)
Panel:GetSet("TooltipOffset", nil)

function Panel:OnConstruct(config)
	self.World = Panel.World
	Panel.BaseClass.OnConstruct(self, config)
end

function Panel:OnCreate()
	Panel.BaseClass.OnCreate(self)
end

function Panel:OnPostCreate()
	Panel.BaseClass.OnPostCreate(self)

	if self.Tooltip ~= nil then
		local options = self.TooltipOptions and table.shallow_copy(self.TooltipOptions)

		if self.TooltipMaxWidth ~= nil then
			options = options or {}
			options.MaxWidth = self.TooltipMaxWidth
		end

		if self.TooltipOffset ~= nil then
			options = options or {}
			options.Offset = self.TooltipOffset
		end

		import("goluwa/render2d/ui/tooltip.lua").Attach(self, self.Tooltip, options)
	end
end

function Panel:RemoveExternalChildren()
	local children = self:GetChildren()

	for i = #children, 1, -1 do
		if not children[i].IsInternal then children[i]:Remove() end
	end
end

Panel:Register()
import.loaded["goluwa/render2d/ui/panel.lua"] = Panel

do
	Panel.World = Panel.New{
		ComponentSet = {
			"transform",
			"ui_debug",
			"visual",
		},
	}
	Panel.World:SetName("WorldPanel")
	local window = system.GetWindow()
	Panel.World.transform:SetSize(Vec2(window and window:GetSize() or Vec2()))
	Panel.World:AddGlobalEvent("WindowFramebufferResized")

	function Panel.World:OnWindowFramebufferResized(window, size)
		self.transform:SetSize(size)
	end
end

do
	local panels = {}

	function Panel.RefreshTheme()
		table.clear(panels)
		panels[1] = Panel.World

		for i, child in ipairs(Panel.World:GetChildrenList()) do
			panels[i + 1] = child
		end

		for i = 1, #panels do
			panels[i]:ReresolveProperties()
		end

		for i = 1, #panels do
			if panels[i].OnThemeChanged then panels[i]:OnThemeChanged() end
		end

		table.clear(panels)
	end

	event.AddListener("ThemeChanged", "ui_panel_refresh", Panel.RefreshTheme)
end

do
	function Panel.CloseContextMenu()
		for _, child in ipairs(Panel.World:GetChildren()) do
			if child.is_context_menu then
				if child.RequestClose then
					child:RequestClose()
				else
					child:Remove()
				end
			end
		end
	end

	function Panel.OpenContextMenu(props, ...)
		Panel.CloseContextMenu()

		if not props.Position then
			props.Position = system.GetWindow():GetMousePosition():Copy()
		end

		if not props.Key then props.Key = "ContextMenu" end

		local ContextMenu = import("goluwa/render2d/ui/elements/context_menu.lua")
		local menu = ContextMenu(props)(...)
		menu.is_context_menu = true
		return Panel.World:Ensure(menu)
	end
end

function Panel:CreateTemplate(name)
	local META = objects.CreateTemplate(Panel.Type .. "_" .. name)
	META.Base = import("goluwa/render2d/ui/panel.lua")
	META.Name = name
	META.ComponentSet = {}
	setmetatable(META, {
		__call = function(_, ...)
			return META.New(...)
		end,
	})
	META.CMP = setmetatable(
		{},
		{
			__newindex = function(s, k, v)
				if not list.has_value(META.ComponentSet, k) then
					list.insert(META.ComponentSet, k)
				end

				rawset(s, k, v)
			end,
			__index = function(s, k)
				local t = {}
				rawset(s, k, t)

				if not list.has_value(META.ComponentSet, k) then
					list.insert(META.ComponentSet, k)
				end

				return t
			end,
		}
	)
	local GetSet = META.GetSet
	META.GetSet = function(s, k, d, c, ...)
		if type(c) == "function" then return GetSet(s, k, d, {callback = c}, ...) end

		return GetSet(s, k, d, c, ...)
	end
	return META
end

return Panel
