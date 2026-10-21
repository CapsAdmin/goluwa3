local system = import("goluwa/system.lua")
local killfeed = {}
killfeed.Entries = {}
killfeed.Duration = 6
killfeed.MaxEntries = 6

function killfeed.Add(killer, victim)
	local entries = killfeed.Entries
	entries[#entries + 1] = {killer = killer, victim = victim, time = system.GetElapsedTime()}

	if #entries > killfeed.MaxEntries then table.remove(entries, 1) end
end

return killfeed
