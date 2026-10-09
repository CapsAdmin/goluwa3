local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local SVG = import("goluwa/render2d/svg.lua")
local META = Panel:CreateTemplate("svg")
META.CMP.transform = {Size = 96}
META.CMP.layout = {}
META.CMP.visual = {}
META.CMP.style = {}
META.CMP.mouse_input = {}
META:StartStorable()
META:GetSet("Source", nil)
META:GetSet("Color", nil)
META:EndStorable()

function META:SetSource(source)
	self.Source = source

	if not self._ready then return self end

	self._svg = SVG.New(source, {TextureSize = 64})

	if self._svg:GetStatus() == "loaded" then
		self.OnLoad(self, self._svg.decoded)
	elseif self._svg:GetStatus() == "error" then
		self.OnError(self, self._svg:GetError())
	end

	return self
end

function META:GetStatus()
	if not self._svg then return "idle" end

	return self._svg:GetStatus(), self._svg:GetError()
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._ready = true

	if self.Source then self:SetSource(self.Source) end
end

function META.OnLoad(panel, decoded) end

function META.OnError(panel, reason) end

function META:OnDraw()
	local size = self.transform:GetSize()
	local background = self.style:GetBackgroundColor()

	if background ~= nil then
		theme.active:DrawSurface(self.transform:GetTotalSize(), background, 0)
	end

	local padding = self.layout:GetPadding()
	local available_w = math.max(0, size.x - padding.x - padding.w)
	local available_h = math.max(0, size.y - padding.y - padding.h)

	if available_w <= 0 or available_h <= 0 then return end

	local svg = self._svg

	if not svg then return end

	if svg:GetStatus() == "loaded" then
		local color = self.Color or theme.active:GetColor("text")
		render2d.SetColor(color.r, color.g, color.b, color.a)
		render2d.PushMatrixf(padding.x, padding.y, available_w, available_h)
		svg:Draw()
		render2d.PopMatrix()
	elseif svg:GetStatus() == "error" then
		local draw_size = math.min(available_w, available_h)
		self._fallback_texture = self._fallback_texture or Texture.GetFallback()
		render2d.SetTexture(self._fallback_texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(
			padding.x + (available_w - draw_size) / 2,
			padding.y + (available_h - draw_size) / 2,
			draw_size,
			draw_size
		)
	end
end

return META:Register()
