local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local network = import("goluwa/network/network.lua")
local default_ip = "*"
local default_port = 1234

if CLIENT then
	local ip_cvar = pvars.Setup("cl_ip", default_ip)
	local port_cvar = pvars.Setup("cl_port", default_port)
	local last_ip
	local last_port

	commands.Add("retry", function()
		if last_ip then network.Connect(last_ip, last_port) end
	end)

	commands.Add("connect=string|nil,number|nil", function(ip, port)
		ip = ip or ip_cvar:Get()
		port = tonumber(port) or port_cvar:Get()
		logf("connecting to %s:%i\n", ip, port)
		last_ip = ip
		last_port = port
		network.Connect(ip, port)
	end)

	commands.Add("disconnect", function()
		network.Disconnect()
	end)
end

if SERVER then
	local ip_cvar = pvars.Setup("sv_ip", default_ip)
	local port_cvar = pvars.Setup("sv_port", default_port)

	commands.Add("host=string|nil,number|nil", function(ip, port)
		ip = ip or ip_cvar:Get()
		port = tonumber(port) or port_cvar:Get()
		logf("hosting at %s:%i\n", ip, port)
		network.Host(ip, port)
	end)
end
