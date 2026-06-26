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
	local count = select("#", ...)
	local depth
	local stencil
	-- LÖVE 11.0+ clearcolor variant: love.graphics.clear(false, clearstencil, cleardepth)
	-- Only clears depth/stencil without clearing the color buffer.
	local first_arg = select(1, ...)

	if count >= 2 and first_arg == false then
		local clearstencil = select(2, ...)
		local cleardepth = select(count, ...)

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
			depth = select(-1, ...)
			stencil = select(count - 1, ...)
		else -- count == 5
			depth = nil
			stencil = select(-1, ...)
		end

		if depth == true then depth = 0 elseif not tonumber(depth) then depth = nil end

		if stencil == true then
			stencil = 0
		elseif not tonumber(stencil) then
			stencil = nil
		end
	end

	local colors = {select(1, ...)}

	if type(colors[1]) == "number" then
		colors[1] = {select(1, ...), select(2, ...), select(3, ...), (select(4, ...))}
	end

	-- Remove depth/stencil arguments that leaked into the colors table
	if count > 4 then
		for i = #colors, 2, -1 do
			table.remove(colors, i)
		end
	end

	local canvases = {love.graphics.getCanvas()}

	if canvases[1] then
		for i, canvas in ipairs(canvases) do
			local c = colors[i]
			canvas:clear(c[1], c[2], c[3], c[4], stencil, depth)
		end
	else
		local r, g, b, a
		local c = colors[1]

		if c then r, g, b, a = ctx.get_draw_bg_color(c[1], c[2], c[3], c[4]) end

		render.target:Clear(r, g, b, a, depth, stencil)
	end
end

return love.graphics
