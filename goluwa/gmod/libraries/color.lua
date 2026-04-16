function gine.env.ColorToHSV(r, g, b)
	local orig = r

	if type(r) == "table" then
		local t = r
		r = t.r
		g = t.g
		b = t.b
	end

	if not r or not g or not b then
		debug.trace()
		print(orig, type(orig))
		error(
			"ColorToHSV requires 3 arguments (r, g, b) or a color table with r, g, b fields",
			2
		)
	end

	local h, s, v = gine.env.Color(r, g, b):ToHSV()
	return h, s, v
end
