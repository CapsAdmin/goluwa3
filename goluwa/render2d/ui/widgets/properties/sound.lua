local Panel = import("goluwa/render2d/ui/panel.lua")
local Asset = import("goluwa/render2d/ui/widgets/properties/asset.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local preview = import("goluwa/audio/preview.lua")
local META = Panel:CreateTemplate("property_sound")
META.Base = Asset
META.AssetCategory = "sounds"

function META.OnPlay(path, field)
	preview.Play(path)
end

local function on_play_click(button)
	local field = button.Field
	field.OnPlay(field:GetValue(), field)
	return true
end

function META:CreateRightElements()
	local elements = META.BaseClass.CreateRightElements(self)
	table.insert(
		elements,
		1,
		IconButton{
			Field = self,
			Icon = "play",
			Tooltip = "Play",
			Mode = "outline",
			OnClick = on_play_click,
		}
	)
	return elements
end

return META:Register()
