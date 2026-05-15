local system = import("goluwa/system.lua")

function gine.env.system.SteamTime()
	return os.time()
end

function gine.env.system.AppTime()
	return os.clock()
end

function gine.env.system.UpTime()
	return os.clock()
end

function gine.env.RealTime()
	return system.GetElapsedTime()
end

function gine.env.FrameNumber()
	return tonumber(system.GetFrameNumber())
end

function gine.env.FrameTime()
	return system.GetFrameTime()
end

function gine.env.VGUIFrameTime()
	return system.GetFrameTime()
end

function gine.env.CurTime() --system.GetServerTime()
	return system.GetElapsedTime()
end

function gine.env.SysTime() --system.GetServerTime()
	return system.GetTime()
end

function gine.env.engine.TickInterval()
	local frame_time = system.GetFrameTime()

	if frame_time > 0 then return frame_time end

	return 1 / 66
end
