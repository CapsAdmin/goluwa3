local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = objects.CreateTemplate("rect")
META:StartStorable()
META:GetSet("Texture", nil)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("visual")
	self.Owner:EnsureComponent("transform")

	self.Owner:AddLocalListener("OnDraw", function()
		self:OnDraw()
	end)
end

function META:OnDraw()
	local transform = self.Owner.transform
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetTexture(self.Texture)

	if self.Texture then
		local borderRadius = self.Owner.visual:GetBorderRadius()

		if borderRadius > 0 then
			render2d.DrawRoundedRect(0, 0, s.x, s.y, borderRadius)
		else
			render2d.DrawRect(0, 0, s.x, s.y)
		end
	end

	render2d.SetColor(0, 0, 0, 1)
end

return META:Register()
