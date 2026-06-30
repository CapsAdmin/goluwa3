local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ctx = shared.Get(love)
local ENV = ctx.ENV

function love.graphics.setColor(r, g, b, a)
	if type(r) == "table" then
		love.graphics.setColor(r[1], r[2], r[3], r[4])
		return
	end

	ctx.set_fg_color(r, g, b, a)
end

function love.graphics.getColor()
	return ctx.get_fg_color()
end

function love.graphics.setBackgroundColor(r, g, b, a)
	if type(r) == "table" then
		love.graphics.setBackgroundColor(r[1], r[2], r[3], r[4])
		return
	end

	ctx.set_bg_color(r, g, b, a)
end

function love.graphics.getBackgroundColor()
	return ctx.get_bg_color()
end

function love.graphics.clear(...)
	local args = {...}
	local count = select("#", ...)
	local depth
	local stencil
	-- LÖVE 11.0+ clearcolor variant: love.graphics.clear(false, clearstencil, cleardepth)
	-- Only clears depth/stencil without clearing the color buffer.
	local first_arg = args[1]

	if count >= 2 and first_arg == false then
		local clearstencil = args[2]
		local cleardepth = args[count]

		if clearstencil == true then
			clearstencil = 0
		elseif not tonumber(clearstencil) then
			clearstencil = nil
		end

		if cleardepth == true then
			cleardepth = 0
		elseif not tonumber(cleardepth) then
			cleardepth = nil
		end

		if not love.graphics.getCanvas() then
			render.target:Clear(nil, nil, nil, nil, cleardepth, clearstencil)
		end

		return
	end

	-- Extract depth/stencil when present (count > 4 means r,g,b,a + optional stencil/depth)
	if count > 4 then
		if count == 6 then
			depth = args[count]
			stencil = args[count - 1]
		else -- count == 5
			depth = nil
			stencil = args[count]
		end

		if depth == true then depth = 0 elseif not tonumber(depth) then depth = nil end

		if stencil == true then
			stencil = 0
		elseif stencil == false then
			-- Keep false as-is (means "don't clear stencil")
		elseif not tonumber(stencil) then
			stencil = nil
		end
	end

	local colors = {}

	for i = 1, math.min(count, 4) do
		table.insert(colors, args[i])
	end

	if type(colors[1]) == "number" then
		colors[1] = {args[1], args[2], args[3], args[4]}

		for i = #colors, 2, -1 do
			table.remove(colors, i)
		end
	end

	local canvases = {love.graphics.getCanvas()}

	if canvases[1] then
		for i, canvas in ipairs(canvases) do
			local c = colors[i]
			-- Canvas:clear expects 0-255 color values; convert from normalized if needed
			local r, g, b, a

			if ctx.love_uses_normalized_color_range() then
				-- Detect if input is already byte range (0-255) or normalized (0-1)
				if c[1] > 1 or c[2] > 1 or c[3] > 1 or c[4] > 1 then
					-- Input is byte values, pass through directly
					r, g, b, a = c[1], c[2], c[3], c[4]
				else
					-- Input is normalized, convert to byte
					r = c[1] * 255
					g = c[2] * 255
					b = c[3] * 255
					a = c[4] * 255
				end
			else
				r, g, b, a = c[1], c[2], c[3], c[4]
			end

			canvas:clear(r, g, b, a, stencil, depth)
		end
	else
		local r, g, b, a
		local c = colors[1]

		if c then r, g, b, a = ctx.get_draw_bg_color(c[1], c[2], c[3], c[4]) end

		-- Normalize for engine (Vulkan expects 0-1)
		if not ctx.love_uses_normalized_color_range() then
			r = r ~= nil and math.min(r / 255, 1) or nil
			g = g ~= nil and math.min(g / 255, 1) or nil
			b = b ~= nil and math.min(b / 255, 1) or nil
			a = a ~= nil and math.min(a / 255, 1) or nil
		end

		render.target:Clear(r, g, b, a, depth, stencil)
	end
end

return love.graphics
