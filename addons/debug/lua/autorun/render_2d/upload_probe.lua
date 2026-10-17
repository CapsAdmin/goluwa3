local commands = import("goluwa/cli/commands.lua")
local probe = import("goluwa/render/upload_probe.lua")

commands.Add("upload_probe_start", function()
	probe.Start(true)
	logf("[upload_probe] started\n")
end)

commands.Add("upload_probe_stop", function()
	probe.Stop()
	logf("[upload_probe] stopped\n")
end)

commands.Add("upload_probe_reset", function()
	probe.Reset()
	logf("[upload_probe] reset\n")
end)

commands.Add("upload_probe_dump=number[32]", function(limit)
	probe.Dump(limit)
end)

commands.Add("upload_probe_dump_blocks=number[32]", function(limit)
	probe.DumpBlocks(limit)
end)
