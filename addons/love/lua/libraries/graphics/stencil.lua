local render2d = import("goluwa/render2d/render2d.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or import("lua/love.lua")
local ctx = shared.Get(love)
local ENV = ctx.ENV
-- LÖVE stencil function object: a callable wrapper around a user function.
-- Used with love.graphics.newStencil() and love.graphics.setStencil().
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

-- Creates a stencil function object that can be reused with setStencil().
-- In render2d, stencil functions are applied inline via love.graphics.stencil(),
-- so this mainly provides API compatibility with LÖVE.
function love.graphics.newStencil(func)
	if type(func) ~= "function" then
		error(
			"bad argument #1 to 'newStencil' (function expected, got " .. type(func) .. ")",
			2
		)
	end

	return StencilFunc:new(func)
end

-- Sets the global stencil function. When called with no arguments, clears it.
-- In render2d, stencil is applied via love.graphics.stencil(), so this is
-- mainly for API compatibility.
function love.graphics.setStencil(stencil_func)
	if stencil_func == nil then
		ENV.graphics_stencil_func = nil
	else
		if type(stencil_func) == "function" then
			ENV.graphics_stencil_func = stencil_func
		elseif stencil_func and stencil_func.func then
			-- Accept StencilFunc objects created by newStencil()
			ENV.graphics_stencil_func = stencil_func
		else
			error(
				"bad argument #1 to 'setStencil' (function or stencil object expected, got " .. type(stencil_func) .. ")",
				2
			)
		end
	end
end

-- LÖVE compare mode → render2d stencil mode mapping.
-- "always" in LÖVE means "always pass the test" which maps to "none" (no test).
local love_compare_to_render2d = {
	always = "none",
	equal = "test",
	greater = "greater",
	notequal = "test_inverse",
	gequal = "greater", -- approximate: greater-or-equal → greater
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

-- LÖVE stencil action → render2d stencil mode mapping.
-- The stencil() function temporarily configures the stencil buffer for writing,
-- runs the user function, then restores the previous test state.
--
-- Signature: stencil(func, action="replace", ref=1, keep=true)
--   func    - function to call while stencil is active
--   action  - stencil operation: "replace", "increment", "decrement",
--             "invert", "increment_wrap", "decrement_wrap"
--   ref     - reference value written to stencil buffer (defaults to 1)
--   keep    - whether to keep stencil value on depth test fail (default true)
--
-- Supported actions:
--   "replace"      → write mode (always pass, replace with ref value)
--   "increment"    → mask_write mode (increment if matches ref, clamp at 255)
--   "decrement"    → mask_decrement mode (decrement if matches ref, clamp at 0)
--   "invert"       → not directly supported by render2d; falls back to replace
--   "increment_wrap" / "decrement_wrap" → not supported; falls back to increment/decrement
function love.graphics.stencil(stencil_func, action, ref, keep)
	action = action or "replace"
	ref = ref or 1
	keep = keep ~= false -- default true
	-- Resolve the stencil function: accept both raw functions and StencilFunc objects
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

	-- Handle keep parameter: if false, clear the stencil target
	if not keep then --clear_love_stencil_target(0)
	end

	local old_mode, old_val = love.graphics.getStencilTest()
	local old_r, old_g, old_b, old_a = love.graphics.getColor()
	-- Set stencil mode based on action
	local stencil_mode_name

	if action == "replace" then
		stencil_mode_name = "write"
	elseif action == "increment" then
		stencil_mode_name = "mask_write"
	elseif action == "decrement" then
		stencil_mode_name = "mask_decrement"
	elseif action == "invert" then
		-- Invert is not directly supported by render2d. Fall back to replace.
		stencil_mode_name = "write"
	elseif action == "increment_wrap" or action == "decrement_wrap" then
		-- Wrap-around is not supported. Fall back to plain increment/decrement.
		if action == "increment_wrap" then
			stencil_mode_name = "mask_write"
		else
			stencil_mode_name = "mask_decrement"
		end
	else
		error("unsupported stencil action: " .. tostring(action), 2)
	end

	-- Set color alpha to 1 to avoid fragment discard in render2d shader, while blend factors keep it invisible
	love.graphics.setColor(old_r, old_g, old_b, 1)
	render2d.PushBlendMode("zero", "one", "add", "zero", "one", "add")
	render2d.SetStencilMode(stencil_mode_name, ref)
	func()
	render2d.PopBlendMode()
	love.graphics.setColor(old_r, old_g, old_b, old_a)
	love.graphics.setStencilTest(old_mode, old_val)
end

-- Clears the stencil buffer to a given value.
function love.graphics.clearStencil(val)
	render2d.ClearStencil(val or 0)
end

-- Push/pop stencil mask for nested stencil regions (used internally by render2d
-- for clipping). These map directly to render2d's push/pop stencil mask functions.
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
