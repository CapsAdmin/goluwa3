HOTRELOAD = false
local render = import("goluwa/render/render.lua")
local timer = import("goluwa/timer.lua")
local callback_id = "render3d_hotreload"
local render3d = import.loaded["goluwa/render3d/render3d.lua"]

-- Capture the old module tables before clearing the import cache so we can
-- remap stale upvalues in the rest of the loaded code afterwards.
local old_modules = {}

for path, module in pairs(import.loaded) do
	if type(path) == "string" and path:find("goluwa/render3d", 1, true) then
		old_modules[module] = path
	end
end

for k in pairs(import.loaded) do
	if type(k) == "string" and k:find("goluwa/render3d", 1, true) then import.loaded[k] = nil end
end

local function refresh_upvalues()
	local replacements = {}

	for old_module, path in pairs(old_modules) do
		replacements[old_module] = import.loaded[path]
	end

	local function patch_table(tbl)
		for _, value in pairs(tbl) do
			if type(value) == "function" then
				local i = 1

				while true do
					local name = debug.getupvalue(value, i)

					if not name then break end

					local replacement = replacements[debug.getupvalue(value, i)]

					if replacement then debug.setupvalue(value, i, replacement) end

					i = i + 1
				end
			end
		end
	end

	for _, module in pairs(import.loaded) do
		if type(module) == "table" then patch_table(module) end
	end
end

render.RegisterFlushCallback(callback_id, function(reason)
	if reason ~= "begin_frame" then return end

	render.UnregisterFlushCallback(callback_id)

	-- Destroy the old module's GPU state before re-importing, otherwise the
	-- old framebuffers and textures stay resident in VRAM next to the new ones.
	if render3d and render3d.Shutdown then render3d.Shutdown() end

	HOTRELOAD = true
	local module = import("goluwa/render3d/render3d.lua")
	module:Initialize()
	HOTRELOAD = false

	refresh_upvalues()

	timer.Delay(0, function()
		collectgarbage("collect")
	end, callback_id .. "_gc")
end)
