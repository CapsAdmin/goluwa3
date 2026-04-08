local line = import("goluwa/love/line.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local love = ... or _G.love
local ENV = love._line_env
love.window = love.window or {}
local window_state = {
	title = "",
	width = 0,
	height = 0,
	fullscreen = false,
	fullscreentype = "desktop",
	vsync = 1,
	msaa = 0,
	fsaa = 0,
	stencil = true,
	depth = 0,
	resizable = false,
	borderless = false,
	centered = true,
	display = 1,
	highdpi = false,
	usedpiscale = true,
	minwidth = 1,
	minheight = 1,
	maxwidth = 100000,
	maxheight = 100000,
	refreshrate = 0,
	x = nil,
	y = nil,
}

local function copy_table(tbl)
	local out = {}

	for key, value in pairs(tbl or {}) do
		out[key] = value
	end

	return out
end

local function normalize_window_flags(flags, keep_existing)
	local normalized = keep_existing and copy_table(window_state) or copy_table(window_state)

	if not keep_existing then
		normalized.fullscreen = false
		normalized.fullscreentype = "desktop"
		normalized.vsync = 1
		normalized.resizable = false
		normalized.borderless = false
		normalized.centered = true
		normalized.display = 1
		normalized.highdpi = false
		normalized.usedpiscale = true
		normalized.refreshrate = 0
		normalized.x = nil
		normalized.y = nil
	end

	for key, value in pairs(flags or {}) do
		normalized[key] = value
	end

	if normalized.fullscreen == nil then normalized.fullscreen = false end

	if normalized.fullscreentype == nil then
		normalized.fullscreentype = "desktop"
	end

	if normalized.vsync == nil then normalized.vsync = 1 end

	if normalized.resizable == nil then normalized.resizable = false end

	if normalized.borderless == nil then normalized.borderless = false end

	if normalized.centered == nil then normalized.centered = true end

	if normalized.display == nil or normalized.display < 1 then
		normalized.display = 1
	end

	if normalized.highdpi == nil then normalized.highdpi = false end

	if normalized.usedpiscale == nil then normalized.usedpiscale = true end

	if normalized.refreshrate == nil then normalized.refreshrate = 0 end

	if normalized.fullscreentype == "desktop" then
		normalized.borderless = true
	end

	return normalized
end

local function get_window_size()
	if window_state.width > 0 and window_state.height > 0 then
		return window_state.width, window_state.height
	end

	local size = system.GetWindow():GetSize()

	if size and size.x and size.y and size.x > 0 and size.y > 0 then
		return size.x, size.y
	end

	return 0, 0
end

local function sync_window_globals(width, height)
	line.SyncWindowGlobals(love, width, height)
end

local DEFAULT_FULLSCREEN_MODE = {width = 1280, height = 720}
local FULLSCREEN_MODES = {
	{width = 1280, height = 720},
	{width = 1366, height = 768},
	{width = 1600, height = 900},
	{width = 1920, height = 1080},
	{width = 1920, height = 1200},
	{width = 1680, height = 1050},
	{width = 1440, height = 900},
	{width = 1440, height = 960},
	{width = 1400, height = 1050},
	{width = 1365, height = 768},
	{width = 1280, height = 1024},
	{width = 1280, height = 960},
	{width = 1280, height = 854},
	{width = 1280, height = 800},
	{width = 1280, height = 768},
	{width = 1152, height = 864},
	{width = 1152, height = 768},
	{width = 1024, height = 768},
	{width = 852, height = 480},
	{width = 800, height = 600},
	{width = 800, height = 480},
	{width = 720, height = 480},
}

local function get_default_fullscreen_mode()
	return DEFAULT_FULLSCREEN_MODE.width, DEFAULT_FULLSCREEN_MODE.height
end

local function apply_window_mode(width, height, flags, keep_existing)
	local mode_flags = normalize_window_flags(flags, keep_existing)

	if
		(
			not width or
			width <= 1 or
			not height or
			height <= 1
		)
		and
		mode_flags.fullscreen and
		mode_flags.fullscreentype == "desktop"
	then
		width, height = get_default_fullscreen_mode()
	end

	local window = system.GetWindow()
	local current_size = window:GetSize()
	width = math.max(1, math.floor((width or current_size.x or 1) + 0.5))
	height = math.max(1, math.floor((height or current_size.y or 1) + 0.5))
	window_state = mode_flags
	window_state.width = width
	window_state.height = height
	window:SetSize(Vec2(width, height))
	sync_window_globals(width, height)
	return true
end

function love.window.setTitle(title)
	window_state.title = title or ""
	system.GetWindow():SetTitle(title)
end

function love.window.getTitle()
	return system.GetWindow():GetTitle() or window_state.title or ""
end

function love.window.setCaption(title)
	system.GetWindow():SetTitle(title)
end

function love.window.getWidth()
	local width = get_window_size()
	return width
end

function love.window.getHeight()
	local _, height = get_window_size()
	return height
end

function love.window.getDimensions()
	return get_window_size()
end

function love.window.isCreated()
	return true
end

function love.window.isOpen()
	local width, height = get_window_size()
	return width > 0 and height > 0
end

local function get_window_pixel_scale()
	local width, height = get_window_size()
	local framebuffer_size = system.GetWindow():GetFramebufferSize()

	if not framebuffer_size then return 1 end

	if width <= 0 or height <= 0 then return 1 end

	if not framebuffer_size.x or not framebuffer_size.y then return 1 end

	local width_scale = framebuffer_size.x / width
	local height_scale = framebuffer_size.y / height
	local scale = math.max(width_scale, height_scale)

	if scale <= 0 then return 1 end

	return scale
end

function love.window.getPixelScale()
	return get_window_pixel_scale()
end

function love.window.getDPIScale()
	return love.window.getPixelScale()
end

function love.window.setFullscreen() end

function love.window.setMode(x, y, flags)
	return apply_window_mode(x, y, flags, false)
end

function love.window.updateMode(x, y, flags)
	return apply_window_mode(x, y, flags, true)
end

function love.window.getMode()
	local w, h = get_window_size()
	local position = system.GetWindow():GetPosition()
	local pos_x = position and position.x or window_state.x or 0
	local pos_y = position and position.y or window_state.y or 0
	return w,
	h,
	setmetatable(
		{
			x = pos_x,
			y = pos_y,
		},
		{
			__index = function(_, key)
				return window_state[key]
			end,
		}
	)
end

function love.window.getDesktopDimensions()
	local width, height = get_window_size()

	if width <= 1 or height <= 1 then return get_default_fullscreen_mode() end

	return width, height
end

function love.window.getDisplayCount()
	return 1
end

function love.window.getDisplayName(index)
	if index ~= nil and index ~= 1 then return nil end

	return "Primary Display"
end

function love.window.toPixels(value)
	return value * love.window.getPixelScale()
end

function love.window.fromPixels(value)
	return value / love.window.getPixelScale()
end

function love.window.showMessageBox(_, _, buttons)
	if type(buttons) == "table" and #buttons > 0 then return 1 end

	return true
end

function love.window.setIcon() end

function love.window.getIcon() end

function love.window.getFullscreenModes()
	return table.copy(FULLSCREEN_MODES)
end

event.AddListener("WindowFramebufferResized", "line_window_sync_" .. tostring(love), function(_, size)
	if line.current_game and line.current_game ~= love then return end

	sync_window_globals(size.x, size.y)
end)
