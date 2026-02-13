local fonts = require("render2d.fonts")
local event = require("event")

event.AddListener("RendererReady", "test", function()
	local f = fonts.LoadGoogleFont("Roboto", "regular")
	print("Requested Roboto")
	local timer = require("timer")

	timer.Delay(2, function()
		print("Roboto Fonts:", #f:GetFonts())

		if f:GetFonts()[1] then
			print("Sub-font path:", f:GetFonts()[1]:GetPath())
			print("Sub-font Ascent:", f:GetFonts()[1]:GetAscent())
		end

		print("SDF Font Ascent:", f:GetAscent())
		local text = "Hello"
		local w, h = f:GetTextSize(text)
		print("Text size for 'Hello':", w, h)

		for i = 1, #text do
			local c = text:sub(i, i)
			local code = string.byte(c)
			local data = f.chars[code]

			if data then
				print("Char '" .. c .. "' metrics: w=" .. data.w .. " x_advance=" .. data.x_advance)
			else
				print("Char '" .. c .. "' not loaded yet")
			end
		end

		os.exit()
	end)
end)
