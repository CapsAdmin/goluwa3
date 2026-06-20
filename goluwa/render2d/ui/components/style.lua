local prototype = import("goluwa/prototype.lua")
local META = prototype.CreateTemplate("style")
META:StartStorable()
META:GetSet("ForegroundColor", nil)
META:GetSet("BackgroundColor", nil)
META:EndStorable()

local function get_style_value(style, key)
	local getter = style["Get" .. key]

	if getter then return getter(style) end

	return style[key]
end

local function resolve_inherited_value(style, key)
	local value = get_style_value(style, key)

	if value ~= nil then return value end

	local parent = style.Owner and style.Owner:GetParent()

	while parent and parent.IsValid and parent:IsValid() do
		local parent_style = parent.style

		if parent_style then
			value = get_style_value(parent_style, key)

			if value ~= nil then return value end
		end

		parent = parent:GetParent()
	end
end

function META:GetResolvedForegroundColor()
	return resolve_inherited_value(self, "ForegroundColor")
end

function META:GetResolvedBackgroundColor()
	return resolve_inherited_value(self, "BackgroundColor")
end

return META:Register()
