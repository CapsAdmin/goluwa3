local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local COLOR_TOKENS = {
	default = "text",
	dim = "text_disabled",
	head = "neutral",
	warn = "negative",
}
local colors = {}
local META = Panel:CreateTemplate("stat_table")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Columns", 1)
META:EndStorable()

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

-- called every draw, returns rows of {label, value, detail, fraction, color} where color is a COLOR_TOKENS key
function META.OnRows(table) end

local function draw_text(font, text, x, y, color)
	render2d.PushColor(color.r, color.g, color.b)
	render2d.PushAlphaMultiplier(color.a)
	local shadow_x, shadow_y, shadow = theme.active:GetTextShadow(color)

	if shadow_x then
		render2d.PushColor(shadow.r, shadow.g, shadow.b)
		render2d.PushAlphaMultiplier(shadow.a)
		font:DrawText(text, x + shadow_x, y + shadow_y, nil, nil, "cap_center")
		render2d.PopAlphaMultiplier()
		render2d.PopColor()
	end

	font:DrawText(text, x, y, nil, nil, "cap_center")
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
end

function META:OnDraw()
	local active = theme.active
	local size = self.transform:GetSize()
	active:DrawFrame(size, 0)
	local font, font_size = active:GetFont("body", "S")
	local row_height = math.ceil(font_size * 1.2)
	local padding = active:GetPadding("M")
	local column_width = size.x / self.Columns
	local value_right = column_width * 0.71
	local detail_x = column_width * 0.73
	local bar_x = column_width * 0.86
	local bar_width = column_width * 0.12
	local per_column = math.floor((size.y - padding * 2) / row_height)

	for key, token in pairs(COLOR_TOKENS) do
		colors[key] = active:GetColor(token, {surface = "surface"})
	end

	local track = active:GetColor("track")
	local bar = active:GetColor("primary")
	local rows = self.OnRows(self)

	for i = 1, math.min(#rows, per_column * self.Columns) do
		local row = rows[i]
		local color = colors[row.color or "default"]
		local x = math.floor((i - 1) / per_column) * column_width
		local center = padding + ((i - 1) % per_column) * row_height + row_height / 2
		draw_text(font, row.label, x + padding, center, color)

		if row.value then
			draw_text(font, row.value, x + value_right - font:GetTextSize(row.value), center, color)
		end

		if row.detail then
			draw_text(font, row.detail, x + detail_x, center, colors.dim)
		end

		if row.fraction then
			render2d.SetTexture(nil)
			render2d.SetColor(track.r, track.g, track.b, track.a)
			render2d.DrawRect(x + bar_x, center - 3, bar_width, 6)
			render2d.SetColor(bar.r, bar.g, bar.b, bar.a)
			render2d.DrawRect(x + bar_x, center - 3, bar_width * row.fraction, 6)
		end
	end
end

function META:OnPostDraw()
	theme.active:DrawFramePost(self.transform:GetSize(), 0)
end

return META:Register()
