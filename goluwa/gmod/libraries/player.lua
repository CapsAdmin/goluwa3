local fallback_clients

local function get_fallback_client()
	fallback_clients = fallback_clients or {}
	fallback_clients.local_client = fallback_clients.local_client or
		{
			gine_nick = "Player",
			IsBot = function()
				return false
			end,
			SetNick = function(self, nick)
				self.gine_nick = nick
			end,
			Nick = function(self)
				return self.gine_nick or "Player"
			end,
			IsValid = function()
				return true
			end,
		}
	return fallback_clients.local_client
end

local function get_clients()
	if _G.clients then return _G.clients end

	fallback_clients = fallback_clients or {}
	fallback_clients.GetAll = fallback_clients.GetAll or function()
		return {get_fallback_client()}
	end
	fallback_clients.CreateBot = fallback_clients.CreateBot or
		function()
			local bot = {
				gine_nick = "Bot",
				IsBot = function()
					return true
				end,
				SetNick = function(self, nick)
					self.gine_nick = nick
				end,
				Nick = function(self)
					return self.gine_nick or "Bot"
				end,
				IsValid = function()
					return true
				end,
			}
			fallback_clients.bots = fallback_clients.bots or {}
			list.insert(fallback_clients.bots, bot)
			return bot
		end
	fallback_clients.GetLocalClient = fallback_clients.GetLocalClient or get_fallback_client
	return fallback_clients
end

do
	local player = gine.env.player

	function player.GetAll()
		local out = {}
		local clients = get_clients()

		for _, cl in ipairs(clients.GetAll()) do
			list.insert(out, gine.WrapObject(cl, "Player"))
		end

		return out
	end

	function player.GetCount()
		return #get_clients().GetAll()
	end

	function player.GetHumans()
		local out = {}
		local clients = get_clients()

		for _, cl in ipairs(clients.GetAll()) do
			if not cl:IsBot() then list.insert(out, gine.WrapObject(cl, "Player")) end
		end

		return out
	end

	function player.GetBots()
		local out = {}
		local clients = get_clients()

		for _, cl in ipairs(clients.GetAll()) do
			if cl:IsBot() then list.insert(out, gine.WrapObject(cl, "Player")) end
		end

		return out
	end
end

do
	if SERVER then
		function gine.env.player.CreateNextBot(name)
			local clients = get_clients()
			local client = clients.CreateBot()
			client:SetNick(name)
			return gine.WrapObject(client, "Player")
		end
	end

	function gine.env.LocalPlayer()
		local clients = get_clients()
		gine.local_player = gine.local_player or gine.WrapObject(clients.GetLocalClient(), "Player")
		return gine.local_player
	end

	function gine.env.Player(idx)
		return gine.env.LocalPlayer()
	end

	function gine.env.GetViewEntity()
		return gine.env.LocalPlayer()
	end

	local META = gine.EnsureMetaTable("Player")

	function META:Crouching() end

	function META:GetShootPos()
		if CLIENT then gine.env.EyePos() end

		return gine.env.Vector()
	end

	function META:GetAimVector()
		if CLIENT then return gine.env.EyeVector() end

		return gine.env.Vector()
	end

	function META:GetHull()
		return gine.env.Vector(-16, -16, 0), gine.env.Vector(16, 16, 72)
	end

	function META:GetHullDuck()
		return gine.env.Vector(-16, -16, 0), gine.env.Vector(16, 16, 32)
	end

	function META:GetViewEntity()
		return NULL
	end

	function META:VoiceVolume()
		return math.random()
	end

	function META:SetVoiceVolumeScale(scale)
		self.__obj.gine_voice_volume_scale = tonumber(scale) or 1
	end

	function META:GetVoiceVolumeScale()
		return self.__obj.gine_voice_volume_scale or 1
	end

	function META:SetArmor(num)
		self.__obj.gine_armor = num
	end

	function META:Armor()
		return self.__obj.gine_armor or 0
	end

	function META:SetTeam(id)
		self.__obj.gine_team = id
	end

	function META:Team()
		return self.__obj.gine_team or gine.env.TEAM_SPECTATOR
	end

	function META:Frags()
		return 0
	end

	function META:Deaths()
		return 0
	end

	function META:Ping()
		return 0
	end

	function META:IsMuted()
		return false
	end

	function META:IsBot()
		return false
	end

	function META:IsListenServerHost()
		return false
	end

	function META:GetObserverTarget() end

	function META:GetRagdollEntity()
		return NULL
	end

	function META:SteamID()
		return "STEAM_0:1:" .. self:UniqueID()
	end

	function META:SteamID64()
		return "76561197978977007"
	end

	function META:Nick()
		if self.__obj.GetNick then return self.__obj:GetNick() end

		if self.__obj.Nick then return self.__obj:Nick() end

		return self.__obj.gine_nick or "Player"
	end

	function META:UniqueID()
		return crypto.CRC32(("%p"):format(self.__obj))
	end

	function META:ShouldDrawLocalPlayer()
		return false
	end

	function META:UserID()
		return math.abs(tonumber(self:UniqueID()) % 333) -- todo
	end

	function META:GetFriendStatus()
		return "none"
	end

	function META:GetAttachedRagdoll()
		return _G.NULL
	end

	function META:SetClassID(id)
		self.__obj.gine_classid = id
	end

	function META:GetClassID()
		return self.__obj.gine_classid or 0
	end

	function META:IsDrivingEntity(ent)
		return false
	end

	function META:GetVehicle()
		return NULL
	end

	function META:InVehicle()
		return false
	end

	function META:Alive()
		return true
	end

	function META:FlashlightIsOn()
		return false
	end

	--if SERVER then
	function META:IPAddress()
		return "192.168.1.101:27005"
	end

	--end
	function META:IsSpeaking()
		return false
	end

	function META:KeyDown(key)
		return gine.env.input.IsKeyDown(key)
	end

	function META:SetNoCollideWithTeammates(b) end

	function META:SetAvoidPlayers(b) end

	function META:GetViewModel()
		self.__obj.viewmodel = self.__obj.viewmodel or gine.env.ents.Create("predicted_viewmodel")
		return self.__obj.viewmodel
	end

	function META:UnSpectate() end

	function META:SetPlayerColor() end

	gine.GetSet(META, "Hands", NULL)
	gine.GetSet(META, "WalkSpeed", 200)
	gine.GetSet(META, "RunSpeed", 400)
	gine.GetSet(META, "CrouchedWalkSpeed", 0.3)
	gine.GetSet(META, "UnDuckSpeed", 0.1)
	gine.GetSet(META, "JumpPower", 200)
	gine.GetSet(META, "DuckSpeed", 0.1)
	gine.GetSet(META, "FOV", 90)
end

do
	gine.AddEvent("ClientEntered", function(client)
		local ply = gine.WrapObject(client, "Player")
		gine.env.hook.Run(
			"player_connect",
			{
				name = ply:Nick(),
				networkid = ply:SteamID(),
				address = ply:IPAddress(),
				userid = ply:UserID(),
				bot = 0, -- ply:IsBot(),
				index = ply:EntIndex(),
			}
		)
		gine.env.gamemode.Call("PlayerConnect", ply:Nick(), ply:IPAddress())

		timer.Delay(
			0.5,
			function()
				gine.env.hook.Run("player_spawn", {
					userid = ply:UserID(),
				})

				timer.Delay(
					0,
					function()
						gine.env.hook.Run("player_activate", {
							userid = ply:UserID(),
						})

						timer.Delay(
							0,
							function()
								gine.env.gamemode.Call("OnEntityCreated", ply)
								gine.env.gamemode.Call("NetworkEntityCreated", ply)
								gine.env.gamemode.Call("PlayerInitialSpawn", ply)
								gine.env.gamemode.Call("PlayerSpawn", ply)
							end,
							nil,
							client
						)
					end,
					nil,
					client
				)
			end,
			nil,
			client
		)
	end)

	gine.AddEvent("ClientLeft", function(client, reason)
		local ply = gine.WrapObject(client, "Player")
		gine.env.gamemode.Call("EntityRemoved", ply)
		gine.env.gamemode.Call("PlayerDisconnected", ply)
		gine.env.hook.Run(
			"player_disconnect",
			{
				name = ply:Nick(),
				networkid = ply:SteamID(),
				userid = ply:UserID(),
				bot = ply:IsBot(),
				reason = reason,
			}
		)
	end)

	gine.AddEvent("ClientChat", function(client, msg)
		local ply = gine.WrapObject(client, "Player")

		if gine.env.gamemode.Call("OnPlayerChat", ply, msg, false, not ply:Alive()) == true then
			if SERVER then message.Broadcast("say", client, str, chat.seed) end

			if SERVER or not network.IsConnected() then chat.seed = chat.seed + 1 end

			return false
		end
	end)

	if RELOAD then
		for k, v in pairs(gine.env.player.GetAll()) do
			event.Call("ClientLeft", v.__obj, "reloading")
		end

		for k, v in pairs(gine.env.player.GetAll()) do
			event.Call("ClientEntered", v.__obj)
		end
	end
end
