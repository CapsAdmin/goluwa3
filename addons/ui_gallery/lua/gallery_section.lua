local Panel = import("goluwa/render2d/ui/panel.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local META = Panel:CreateTemplate("gallery_section")
META.Slot = "_stage"
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
	ChildGap = "S",
}
META:StartStorable()
META:GetSet("Title", "")
META:GetSet("Framed", true)
META:EndStorable()

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	Text{
		Parent = self,
		IsInternal = true,
		Text = self.Title,
		Font = "body_strong M",
		IgnoreMouseInput = true,
	}

	if self.Description ~= "" then
		Text{
			Parent = self,
			IsInternal = true,
			Text = self.Description,
			Font = "body S",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
	end

	local stage_layout = {
		Direction = "y",
		GrowWidth = 1,
		FitHeight = true,
		AlignmentX = "stretch",
		ChildGap = "M",
	}

	if self.Framed then
		self._stage = Frame{
			Parent = self,
			IsInternal = true,
			Padding = "M",
			layout = stage_layout,
		}
	else
		self._stage = Panel.New{
			Parent = self,
			IsInternal = true,
			transform = true,
			layout = stage_layout,
		}
	end
end

return META:Register()
