local system = import("goluwa/system.lua")
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
		valid_components.gui_element = import("goluwa/render2d/ui/components/gui_element.lua")
		valid_components.key_input = import("goluwa/render2d/ui/components/key_input.lua")
		valid_components.layout = import("goluwa/render2d/ui/components/layout.lua")
		valid_components.mouse_input = import("goluwa/render2d/ui/components/mouse_input.lua")
		valid_components.rect = import("goluwa/render2d/ui/components/rect.lua")
		valid_components.resizable = import("goluwa/render2d/ui/components/resizable.lua")
		valid_components.style = import("goluwa/render2d/ui/components/style.lua")
		valid_components.text = import("goluwa/render2d/ui/components/text.lua")
		valid_components.transform = import("goluwa/render2d/ui/components/transform.lua")
		valid_components.draggable = import("goluwa/render2d/ui/components/draggable.lua")
	end

	return valid_components
end

local function find_tooltip_props(config, state)
	if type(config) ~= "table" then return end

	if config.Tooltip ~= nil then
		state.source = config.Tooltip
		config.Tooltip = nil
	end

	if config.TooltipOptions ~= nil then
		state.options = table.shallow_copy(config.TooltipOptions)
		config.TooltipOptions = nil
	end

	if config.TooltipMaxWidth ~= nil then
		state.options = state.options or {}
		state.options.MaxWidth = config.TooltipMaxWidth
		config.TooltipMaxWidth = nil
	end

	if config.TooltipOffset ~= nil then
		state.options = state.options or {}
		state.options.Offset = config.TooltipOffset
		config.TooltipOffset = nil
	end

	for i = 1, #config do
		find_tooltip_props(config[i], state)
	end
end

local function add_tooltip_functionality(ent, config)
	local tooltip_state = {}
	find_tooltip_props(config, tooltip_state)

	if tooltip_state.source ~= nil then
		import("goluwa/render2d/ui/tooltip.lua").Attach(ent, tooltip_state.source, tooltip_state.options)
	end
end

function Panel:OnCreate(config)
	self.World = Panel.World

	if self.ComponentSet and self.CMP then
		for i, name in ipairs(self.ComponentSet) do
			if self.CMP[name] then
				if next(self.CMP[name]) then
					config[name] = self.CMP[name]
				else
					config[name] = true
				end
			end
		end
	end

	Panel.BaseClass.OnCreate(self, config)
	add_tooltip_functionality(self, config)
end

Panel:Register()
import.loaded["goluwa/render2d/ui/panel.lua"] = Panel

do
	Panel.World = Panel.New{
		ComponentSet = {
			"transform",
			"ui_debug",
			"gui_element",
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

function Panel:CreateTemplate(name)
	local META = objects.CreateTemplate(Panel.Type .. "_" .. name)
	META.Base = import("goluwa/render2d/ui/panel.lua")
	META.Name = name
	META.ComponentSet = {}
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
		if type(c) == "function" then
			return GetSet(
				s,
				k,
				d,
				{
					init_callback = true,
					defer_callback = true,
					callback = c,
				},
				...
			)
		end

		return GetSet(s, k, d, c, ...)
	end
	return META
end

return Panel
