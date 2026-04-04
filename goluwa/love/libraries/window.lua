local line = import("goluwa/love/line.lua")
local window = import("goluwa/window.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local love = ... or _G.love
local ENV = love._line_env
love.window = love.window or {}

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

function love.window.setTitle(title)
	window.SetTitle(title)
end

function love.window.setCaption(title)
	window.SetTitle(title)
end

function love.window.getWidth()
	return window.GetSize().x
end

function love.window.getHeight()
	return window.GetSize().y
end

function love.window.getDimensions()
	return window.GetSize():Unpack()
end

function love.window.isCreated()
	return true
end

local function get_window_pixel_scale()
	local size = window.GetSize and window.GetSize() or nil
	local framebuffer_size = window.GetFramebufferSize and window.GetFramebufferSize() or nil

	if not size or not framebuffer_size then return 1 end

	if not size.x or not size.y or size.x <= 0 or size.y <= 0 then return 1 end

	if not framebuffer_size.x or not framebuffer_size.y then return 1 end

	local width_scale = framebuffer_size.x / size.x
	local height_scale = framebuffer_size.y / size.y
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
	if
		(
			not x or
			x <= 1 or
			not y or
			y <= 1
		)
		and
		flags and
		flags.fullscreen and
		flags.fullscreentype == "desktop"
	then
		x, y = get_default_fullscreen_mode()
	end

	window.SetSize(Vec2(x, y))
	sync_window_globals(x, y)
end

function love.window.getMode()
	local w, h = window.GetSize():Unpack()
	return w,
	h,
	{
		fullscreen = false,
		vsync = false,
		fsaa = false,
		resizable = true,
		borderless = true,
		centered = false,
		display = 0,
		minwidth = 800,
		maxwidth = 600,
		highdpi = false,
		srgb = SRGB,
		refreshrate = 60,
		x = window.GetPosition().x,
		y = window.GetPosition().y,
	}
end

function love.window.getDesktopDimensions()
	local width, height = window.GetSize():Unpack()

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

function love.window.setIcon() end

function love.window.getIcon() end

function love.window.getFullscreenModes()
	return table.copy(FULLSCREEN_MODES)
end

event.AddListener("WindowFramebufferResized", "line_window_sync_" .. tostring(love), function(_, size)
	sync_window_globals(size.x, size.y)
end)
