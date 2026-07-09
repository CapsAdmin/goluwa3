local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local commands = import("goluwa/cli/commands.lua")
local clients = import("goluwa/network/clients.lua")
local Color = import("goluwa/structs/color.lua")
local message = import("goluwa/network/message.lua")
local chat = library()

local function getnick(client)
	return client:IsValid() and client:GetNick() or "server"
end

local function get_network()
	return import("goluwa/network/network.lua")
end

local enabled = pvars.Setup("chat_timestamps", true)

function chat.AddTimeStamp(tbl)
	if not enabled:Get() then return {} end

	tbl = tbl or {}
	local time = os.date("*t")
	list.insert(tbl, 1, " - ")
	list.insert(tbl, 1, Color(1, 1, 1))
	list.insert(tbl, 1, ("%.2d:%.2d"):format(time.hour, time.min))
	list.insert(tbl, 1, Color.FromBytes(118, 170, 217))
	return tbl
end

function chat.GetTimeStamp()
	local time = os.date("*t")
	return ("%.2d:%.2d - "):format(time.hour, time.min)
end

function chat.Append(var, str, skip_log)
	if not str then
		str = var
		var = NULL
	end

	local client = NULL

	if typex(var) == "client" then
		client = var
		var = getnick(var)
	elseif typex(var) == "null" then
		var = "disconnected"
	elseif not get_network().IsConnected() then
		var = "server"
	else
		var = tostring(var)
	end

	if not skip_log then logf("%s%s: %s\n", chat.GetTimeStamp(), var, str) end

	event.Call("Chat", var, str, client)
end

if CLIENT then
	message.AddListener("say", function(client, str, seed)
		chat.ClientSay(client, str, seed)
	end)

	function chat.Say(str)
		str = tostring(str)

		if get_network().IsConnected() then
			message.Send("say", str)
		else
			chat.ClientSay(clients.GetLocalClient(), str)
		end
	end
end

chat.seed = 0

function chat.ClientSay(client, str, skip_log, seed)
	local seed = seed or chat.seed
	print(client, str, skip_log, seed)

	if event.Call("ClientChat", client, str, seed) ~= false then
		chat.Append(client, str, skip_log)

		if SERVER then message.Broadcast("say", client, str, chat.seed) end

		if SERVER or not get_network().IsConnected() then chat.seed = chat.seed + 1 end
	end

	return false
end

if SERVER then
	message.AddListener("say", function(client, str)
		chat.ClientSay(client, str)
	end)

	function chat.Say(str)
		str = tostring(str)
		message.Broadcast("say", NULL, str)
		chat.Append(NULL, str)
	end
end

if CLIENT then
	event.AddListener("ChatBoxInput", "chat", function(str)
		chat.Say(str)
	end)
end

commands.Add("say=arg_line", function(text)
	chat.Say(text)
end)

return chat
