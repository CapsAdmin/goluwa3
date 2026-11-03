local vfs = import("goluwa/vfs.lua")
local resource = import("goluwa/resource.lua")
local audio = AUDIO and import("goluwa/audio.lua")
local preview = {}
local current
local current_path

function preview.Play(path)
	if not audio then return false end

	preview.Stop()
	local full_path = "sound/" .. path

	if not vfs.IsFile(full_path) then return false end

	resource.skip_providers = true
	current = audio.CreateSource(full_path)
	resource.skip_providers = false
	current:SetSpatial(false)
	current:SetNormalized(true)
	current:Play(0)
	current_path = path
	return true
end

function preview.Stop()
	if current then current:Stop() end

	current = nil
	current_path = nil
end

function preview.GetPath()
	return current_path
end

function preview.IsPlaying(path)
	return current ~= nil and
		current_path == path and
		(
			current:IsPlaying() or
			not current:IsReady()
		)
end

function preview.GetProgress()
	if not current or not current:IsReady() then return 0 end

	return math.min(current:Tell("seconds") / current:GetDuration(), 1)
end

return preview
