local Panel = import("goluwa/render2d/ui/panel.lua")
local META = Panel:CreateTemplate("column")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "center",
	ChildGap = "M",
}
return META:Register()
