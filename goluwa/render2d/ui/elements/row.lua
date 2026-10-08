local Panel = import("goluwa/render2d/ui/panel.lua")
local META = Panel:CreateTemplate("row")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentY = "center",
	ChildGap = "M",
}
return META:Register()
