local Panel = import("goluwa/render2d/ui/panel.lua")
local META = Panel:CreateTemplate("text")
META.CMP.transform = {}
META.CMP.layout = {FitHeight = true}
META.CMP.text = {Font = "body", FontSize = "M"}
META.CMP.style = {}
META.CMP.mouse_input = {}
META.CMP.animation = {}

function META:OnCreate(props)
	props.layout = {FitWidth = not (props.Wrap or props.Elide), props.layout}

	if props.Wrap and props.WrapToParent == nil then props.WrapToParent = true end

	META.BaseClass.OnCreate(self, props)
end

return META:Register()
