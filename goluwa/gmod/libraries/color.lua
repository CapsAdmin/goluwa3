local Color = import("goluwa/structs/color.lua")

function gine.env.ColorBytes(r, g, b, a)
	return Color.FromBytes(r or 0, g or 0, b or 0, a or 255)
end

function gine.env.Color(r, g, b, a)
	if type(r) == "table" then
		local tbl = r
		r = tbl.r
		g = tbl.g
		b = tbl.b
		a = tbl.a
	end

	r = tonumber(r) or 255
	g = tonumber(g) or 255
	b = tonumber(b) or 255
	a = tonumber(a)

	if a == nil then a = 255 end
	return Color(r / 255, g / 255, b / 255, a / 255)
end

function gine.env.HSVToColor(h, s, v)
	local r, g, b, a = ColorHSV(h / 360, s, v):Unpack()
	return gine.env.Color(r * 255, g * 255, b * 255, a * 255)
end

function gine.env.ColorToHSV(r, g, b)
	if type(r) == "table" then
		local t = r
		r = t.r
		g = t.g
		b = t.b
	end

	local h, s, v = gine.env.ColorBytes(r, g, b):GetHSV()
	return h * 360, s, v
end