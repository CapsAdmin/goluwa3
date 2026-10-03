local render2d = import("goluwa/render2d/render2d.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or import("lua/love.lua")
local ctx = shared.Get(love)
local ENV = ctx.ENV
local StencilFunc = {}
StencilFunc.__index = StencilFunc

function StencilFunc:new(func)
	local obj = setmetatable({}, self)
	obj.func = func
	return obj
end

function StencilFunc:call()
	if self.func then self.func() end
end

function love.graphics.newStencil(func)
	if type(func) ~= "function" then
		error(
			"bad argument #1 to 'newStencil' (function expected, got " .. type(func) .. ")",
			2
		)
	end

	return StencilFunc:new(func)
end

function love.graphics.setStencil(stencil_func)
	if stencil_func == nil then
		ENV.graphics_stencil_func = nil
	else
		if type(stencil_func) == "function" then
			ENV.graphics_stencil_func = stencil_func
		elseif stencil_func and stencil_func.func then
			ENV.graphics_stencil_func = stencil_func
		else
			error(
				"bad argument #1 to 'setStencil' (function or stencil object expected, got " .. type(stencil_func) .. ")",
				2
			)
		end
	end
end

local love_compare_to_render2d = {
	always = "none",
	equal = "test",
	greater = "greater",
	notequal = "test_inverse",
	gequal = "greater",
}

function love.graphics.setStencilTest(mode, val)
	if mode then
		ENV.graphics_stencil_mode = mode
		ENV.graphics_stencil_val = val or 0
		local r2d_mode = love_compare_to_render2d[mode]

		if not r2d_mode then
			error("unsupported stencil test mode: " .. tostring(mode), 2)
		end

		render2d.SetStencilMode(r2d_mode, val or 0)
	else
		ENV.graphics_stencil_mode = "always"
		ENV.graphics_stencil_val = 0
		render2d.SetStencilMode("none", 0)
	end
end

function love.graphics.getStencilTest()
	return ENV.graphics_stencil_mode or "always", ENV.graphics_stencil_val or 0
end

function love.graphics.stencil(stencil_func, action, ref, keep)
	action = action or "replace"
	ref = ref or 1
	keep = keep ~= false
	local func

	if type(stencil_func) == "function" then
		func = stencil_func
	elseif stencil_func and stencil_func.func then
		func = stencil_func.func
	else
		error(
			"bad argument #1 to 'stencil' (function or stencil object expected, got " .. type(stencil_func) .. ")",
			2
		)
	end

	if not keep then  end

	local old_mode, old_val = love.graphics.getStencilTest()
	local old_r, old_g, old_b, old_a = love.graphics.getColor()
	local stencil_mode_name

	if action == "replace" then
		stencil_mode_name = "write"
	elseif action == "increment" then
		stencil_mode_name = "mask_write"
	elseif action == "decrement" then
		stencil_mode_name = "mask_decrement"
	elseif action == "invert" then
		stencil_mode_name = "write"
	elseif action == "increment_wrap" or action == "decrement_wrap" then
		if action == "increment_wrap" then
			stencil_mode_name = "mask_write"
		else
			stencil_mode_name = "mask_decrement"
		end
	else
		error("unsupported stencil action: " .. tostring(action), 2)
	end

	love.graphics.setColor(old_r, old_g, old_b, 1)
	render2d.PushBlendMode("zero", "one", "add", "zero", "one", "add")
	render2d.SetStencilMode(stencil_mode_name, ref)
	func()
	render2d.PopBlendMode()
	love.graphics.setColor(old_r, old_g, old_b, old_a)
	love.graphics.setStencilTest(old_mode, old_val)
end

function love.graphics.clearStencil(val)
	render2d.ClearStencil(val or 0)
end

function love.graphics.pushStencilMask()
	render2d.PushStencilMask()
end

function love.graphics.beginStencilTest()
	render2d.BeginStencilTest()
end

function love.graphics.popStencilMask()
	render2d.PopStencilMask()
end

return love.graphics
