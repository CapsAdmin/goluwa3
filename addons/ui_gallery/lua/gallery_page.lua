local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local META = Panel:CreateTemplate("gallery_page")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
	ChildGap = "L",
	Padding = "M",
}
META:StartStorable()
META:GetSet("Title", "")
META:EndStorable()

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local header = Panel.New{
		Parent = self,
		IsInternal = true,
		transform = true,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = "XS",
		},
	}
	Text{
		Parent = header,
		Text = self.Title,
		Font = "heading XL",
		IgnoreMouseInput = true,
	}

	if self.Description ~= "" then
		Text{
			Parent = header,
			Text = self.Description,
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
	end
end

function META:PreRemoveChildren()
	self:RemoveExternalChildren()
	return false
end

return META:Register()
