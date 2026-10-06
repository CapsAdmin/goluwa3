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
local Color = import("goluwa/structs/color.lua")
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

do
	local SERVER_TIME_INTERVAL = 0.1

	event.AddListener("NetworkStarted", function()
		if CLIENT then
			packet.AddListener("server_command", function(buffer)
				system.SetServerTime(buffer:ReadDouble())
			end)
		end

		if SERVER then
			timer.Repeat("server_command_tick", SERVER_TIME_INTERVAL, function()
				local buffer = packet.CreateBuffer()
				buffer:WriteDouble(system.GetTime())
				packet.Broadcast("server_command", buffer, "sequenced")
			end)
		end
	end)
end

do
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

do
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
