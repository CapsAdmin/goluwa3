function gine.env.ColorToHSV(r, g, b)
	if g == nil and b == nil and r ~= nil and type(r) ~= "number" then
		r, g, b = r.r, r.g, r.b
	end

	if r == nil or g == nil or b == nil then
		error(
			"ColorToHSV requires 3 arguments (r, g, b) or a color table with r, g, b fields",
			2
		)
	end

	r = r / 255
	g = g / 255
	b = b / 255

	local min = math.min(r, g, b)
	local max = math.max(r, g, b)
	local v = max
	local delta = max - min

	if min == 0 and max == 0 then return 0, 0, 0 end

	if max == 0 then return -1, 0, v end

	local s = delta / max
	local h

	if r == max then
		h = (g - b) / delta
	elseif g == max then
		h = 2 + (b - r) / delta
	else
		h = 4 + (r - g) / delta
	end

	h = h / 6

	if h < 0 then h = h + 1 end

	return h, s, v
end
