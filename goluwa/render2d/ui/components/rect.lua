local prototype = import("goluwa/prototype.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = prototype.CreateTemplate("rect")
META:StartStorable()
META:GetSet("Texture", nil)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("gui_element")
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
		local borderRadius = self.Owner.gui_element:GetBorderRadius()

		if borderRadius > 0 then
			gfx.DrawRoundedRect(0, 0, s.x, s.y, borderRadius)
		else
			render2d.DrawRect(0, 0, s.x, s.y)
		end
	end

	render2d.SetColor(0, 0, 0, 1)
end

return META:Register()
