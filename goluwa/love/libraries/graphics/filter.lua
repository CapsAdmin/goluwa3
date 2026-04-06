local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ENV = shared.Get(love).ENV

function love.graphics.setDefaultImageFilter(min, mag, anisotropy)
	ENV.graphics_filter_min = min or "linear"
	ENV.graphics_filter_mag = mag or min or "linear"
	ENV.graphics_filter_anisotropy = anisotropy or 1
end

love.graphics.setDefaultFilter = love.graphics.setDefaultImageFilter
return love.graphics
