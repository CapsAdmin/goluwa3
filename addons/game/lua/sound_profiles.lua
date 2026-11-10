local vfs = import("goluwa/filesystem/vfs.lua")
local system = import("goluwa/system.lua")
local source1 = import("lua/sound_profiles/source1.lua")
local sound_profiles = {}
local CHECK_INTERVAL = 2
local active = source1
local checked = -math.huge

function sound_profiles.Get()
	if active ~= source1 then return active end

	local now = system.GetElapsedTime()

	if now - checked < CHECK_INTERVAL then return active end

	checked = now

	if vfs.IsFile("surfaceproperties/surfaceproperties.vsurf_c") then
		active = import("lua/sound_profiles/source2.lua")
	end

	return active
end

return sound_profiles
