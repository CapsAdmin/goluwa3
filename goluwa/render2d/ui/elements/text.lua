local Panel = import("goluwa/render2d/ui/panel.lua")
local META = Panel:CreateTemplate("text")
META.CMP.transform = {}
META.CMP.layout = {FitHeight = true}
META.CMP.text = {Font = "body", FontSize = "M"}
META.CMP.style = {}
META.CMP.mouse_input = {}
META.CMP.animation = {}

function META.PropDefaults(_, props)
	return {
		layout = {FitWidth = not (props.Wrap or props.Elide)},
		WrapToParent = props.Wrap and true or nil,
	}
end

return META:Register()
