local Panel = import("goluwa/render2d/ui/panel.lua")
local Value = import("goluwa/render2d/ui/widgets/properties/value.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local event = import("goluwa/event.lua")
local META = Panel:CreateTemplate("property_asset")
META.Base = Value
META:StartStorable()
META:GetSet("AssetCategory", nil)
META:EndStorable()

local function on_browse_click(button)
	local field = button.Field

	event.Call(
		"PickObject",
		"asset",
		function(path)
			field:SetValue(path, true)
		end,
		{category = field.AssetCategory, path = field:GetValue()}
	)

	return true
end

function META:OnCreate()
	self.RightElements = {
		IconButton{
			Field = self,
			Icon = "folder_open",
			IconSize = "M",
			Padding = "none",
			Mode = "outline",
			OnClick = on_browse_click,
		},
	}
	META.BaseClass.OnCreate(self)
end

return META:Register()
