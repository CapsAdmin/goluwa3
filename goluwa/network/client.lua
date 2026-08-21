local clients = import("goluwa/network/clients.lua")
local lrun = import("goluwa/lrun.lua")
local nvars = import("goluwa/network/nvars.lua")
local objects = import("goluwa/objects/objects.lua")
local crypto = import("goluwa/crypto.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local network = import("goluwa/network/network.lua")
local message = import("goluwa/network/message.lua")
local packet = import("goluwa/network/packet.lua")
local timer = import("goluwa/timer.lua")
local input = import("goluwa/input.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local META = objects.CreateTemplate("client")
META.Name = "client"
META.socket = NULL
META:GetSet("UniqueID", "???")
nvars.IsSet(META, "Bot", false)
nvars.GetSet(META, "Group", "player")
nvars.GetSet(META, "Nick", USERNAME, "cl_nick")
nvars.GetSet(
	META,
	"AvatarPath",
	"https://secure.gravatar.com/avatar/4e6cf67564bd2084b7a4f21453cc99c8?s=180&d=identicon",
	"cl_avatar_path"
)
nvars.GetSet(META, "Ping", -1)
local client = library()
import.loaded["goluwa/network/client.lua"] = client
client.META = META

function META.New()
	return META:CreateObject()
end

function META:IsConnected()
	return self.connected
end

function META:GetNick()
	for key, client in ipairs(clients:GetAll()) do
		if client ~= self and client.nv.Nick and client.nv.Nick == self.nv.Nick then
			return ("%s (%s)"):format(self.nv.Nick, self:GetUniqueID())
		end
	end

	return self.nv.Nick or self.last_nick or "PubePurse"
end

function META:__tostring2()
	return string.format("[%s][%s]", self:GetName(), self:GetUniqueID())
end

function META:GetName()
	return self.nv and self.nv.Nick or self:GetUniqueID()
end

if SERVER then
	function META:SetGroup(group)
		local old = self.nv.Group
		self.nv.Group = group

		if old ~= group then
			event.CallShared("ClientChangedGroup", self, self.nv.Group)
		end
	end
end

function META:OnRemove()
	self.nv:Remove()
	clients.active_clients_uid[self:GetUniqueID()] = nil
	list.remove_value(clients.active_clients, self)

	if SERVER then self:Disconnect("removed") end
end

function META:GetUniqueColor()
	local crc = crypto.CRC32(self:GetUniqueID())
	local r, g, b = crc:match("(%d%d%d)(%d%d%d)(%d%d%d)")

	if not r then r, g, b = crc:match("(%d%d)(%d%d)(%d%d)") end

	local c = Color(tonumber(r), tonumber(g), tonumber(b), 1)
	c:SetLightness(1)
	return c
end

if SERVER then
	local reasons = {
		[0] = "timeout / unknown reason",
		[1] = "disconnected",
	}

	function META:Disconnect(code)
		if not self.disconnected then
			self.disconnected = true
			local reason = reasons[code] or "unknown disconnect code " .. code
			event.Call("ClientLeft", self, reason)
			message.Send("remove_client", nil, self:GetUniqueID(), reason)

			if self.socket:IsValid() then self.socket:Disconnect(code) end
		end
	end

	function META:Kick(reason)
		self:Disconnect(reason)
		self:Remove()
	end
end

do -- user command
	local client_command_length = 33 -- sample length in ms
	local client_tick_rate = 33 -- in ms
	local server_command_length = client_command_length
	local server_tick_rate = 10
	local layout = {
		{name = "mouse_pos", default = Vec2(0, 0), type = "vec2short"},
		{name = "velocity", default = Vec3(0, 0, 0)},
		{name = "angles", default = Ang3(0, 0, 0)},
		{name = "fov", default = 75},
	}
	local default = {
		time = 0,
		queue = {},
	}

	for i, v in ipairs(layout) do
		v.type = v.type or typex(v.default)
		default[v.name] = v.default
		v.client_name = "client_" .. v.name
	end

	function META:GetCurrentCommand()
		if not self.current_command then
			self.current_command = table.copy(default)
		end

		return self.current_command
	end

	event.AddListener("NetworkStarted", function()
		local function read_buffer(client, buffer)
			local cmd = client:GetCurrentCommand() -- get or create the cmd table
			local time_stamp -- first time is the base time
			for i = 1, 32 do
				local time = buffer:ReadDouble()

				if not time_stamp then time_stamp = time end

				cmd.queue[i] = cmd.queue[i] or table.copy(default)
				cmd.queue[i].time = system.GetTime() + (time - time_stamp)

				for _, v in ipairs(layout) do
					cmd.queue[i][v.name] = buffer:ReadType(v.type)
				end

				if CLIENT then
					cmd.queue[i].net_position = buffer:ReadVec3()
					cmd.queue[i].net_velocity = buffer:ReadVec3()
				end

				if buffer:TheEnd() then break end

				if i == 32 then wlog("command too big: ", client, 2) end
			end
		--list.sort(client.current_command.queue, function(a, b) return a.time > b.time end)
		end

		local function process_usercommand(client)
			local cmd = client:GetCurrentCommand()
			local data = cmd.queue[1]

			if data and data.time < system.GetTime() then
				for k, v in pairs(data) do
					cmd[k] = v
				end

				local pos, vel = event.Call("Move", client, cmd)
				cmd.net_position = pos
				cmd.net_velocity = vel
				list.remove(cmd.queue, 1)
			end
		end

		local lol = 0

		event.AddListener("Update", "interpolate_user_command", function()
			local time = system.GetTime()

			if lol < time - (1 / 33) then
				if CLIENT and network.IsConnected() then
					process_usercommand(clients:GetLocalClient())
				end

				if SERVER then
					for _, client in ipairs(clients:GetAll()) do
						process_usercommand(client)
					end
				end

				lol = time
			end
		end)

		if CLIENT then
			client_command_length = client_command_length / 1000
			client_tick_rate = 1 / client_tick_rate

			do
				local buffer = packet.CreateBuffer()
				local last_send = 0
				local last_tick = 0

				event.AddListener("Update", "user_command_tick", function(dt)
					if not network.IsConnected() then return end

					local cmd = clients:GetLocalClient():GetCurrentCommand()
					local move = event.Call("CreateMove", clients:GetLocalClient(), cmd, dt)
					local time = system.GetElapsedTime()

					if time > last_tick then
						buffer:WriteDouble(time)

						for _, v in ipairs(layout) do
							buffer:WriteType(move and move[v.name] or v.default, v.type)
							cmd[v.client_name] = move and move[v.name] or v.default
						end

						if last_send < time then
							packet.Send("user_command", buffer)
							buffer:Clear()
							last_send = time + client_command_length
						end

						last_tick = time + client_tick_rate
					end
				end)
			end

			packet.AddListener("user_command", function(buffer)
				local client = clients:GetByUniqueID(buffer:ReadString())

				if client:IsValid() then read_buffer(client, buffer) end
			end)

			packet.AddListener("server_command", function(buffer)
				local time = buffer:ReadDouble()
				system.SetServerTime(time)
			end)
		end

		if SERVER then
			server_command_length = server_command_length / 1000
			server_tick_rate = 1 / server_tick_rate

			do
				local buffer = packet.CreateBuffer()
				local last_send = 0

				timer.Repeat("server_command_tick", server_tick_rate, function()
					buffer:WriteDouble(system.GetTime())

					if last_send < system.GetTime() then
						packet.Broadcast("server_command", buffer)
						buffer:Clear()
						last_send = system.GetTime() + server_command_length
					end
				end)
			end

			packet.AddListener("user_command", function(buffer, client)
				read_buffer(client, buffer)
				local cmd = client:GetCurrentCommand()
				local buffer = packet.CreateBuffer()
				buffer:WriteString(client:GetUniqueID())
				buffer:WriteDouble(system.GetTime())

				for _, v in ipairs(layout) do
					buffer:WriteType(cmd.queue[1][v.name], v.type)
				end

				buffer:WriteVec3(cmd.net_position or Vec3(0, 0, 0))
				buffer:WriteVec3(cmd.net_velocity or Vec3(0, 0, 0))
				packet.Send("user_command", buffer)
			end)
		end
	end)
end

do -- input
	local function add_event(name, check)
		input.SetupAccessorFunctions(META, name, nil, nil, true)

		if CLIENT then
			event.AddListener(
				name .. "Input",
				"client_" .. name .. "_event",
				function(key, press)
					local client = clients:GetLocalClient()

					if client:IsValid() then
						if check and not check[key] then return end

						input.CallOnTable(client, name, key, press, nil, nil, true)
						message.Send("Client" .. name .. "Input", key, press)
						return event.Call("Client" .. name .. "Input", client, key, press)
					end
				end,
				{on_error = system.OnError}
			)
		end

		if SERVER then
			message.AddListener(
				"Client" .. name .. "Input",
				function(client, key, press)
					if client:IsValid() then
						if check and not check[key] then return end

						input.CallOnTable(client, name, key, press, nil, nil, true)
						event.Call("Client" .. name .. "Input", client, key, press)
					end
				end,
				{on_error = system.OnError}
			)
		end
	end

	add_event("Key")
	add_event("Char")
	add_event("Mouse")
end

do -- send lua
	if CLIENT then
		message.AddListener("sendlua", function(code, env)
			lrun.Execute(code, {log_error = true, name = "sendlua"})
		end)
	end

	if SERVER then
		function META:SendLua(code)
			message.Send("sendlua", self, code, env)
		end

		function META:Cexec(str)
			self:SendLua("commands.RunString('" .. str .. "')")
		end
	end
end

return META:Register()
