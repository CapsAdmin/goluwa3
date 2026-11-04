local players = import("lua/players.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AIController = import("lua/components/ai_controller.lua")
local inventory_menu = {}
local PARTY_FACTION = "friend"
local PARTY_RADIUS = 25
local state = {open = false, subject = 1, place = "right"}
local subjects = {}
local SOCKETS = {right = "grip_r", left = "grip_l"}
local socket_world = Matrix44()

function inventory_menu.IsOpen()
	return state.open
end

function inventory_menu.GetState()
	return state
end

function inventory_menu.GetSubjects()
	return subjects
end

function inventory_menu.GetSubject()
	return subjects[state.subject]
end

function inventory_menu.RefreshSubjects()
	local rig = players.GetLocal()
	local position = rig.transform:GetPosition()
	subjects = {rig}

	for _, controller in ipairs(AIController.Instances) do
		local owner = controller.Owner

		if
			controller.Faction == PARTY_FACTION and
			owner.weapon_holder and
			not owner.health:IsDead()
			and
			(
				owner.transform:GetPosition() - position
			):GetLength() < PARTY_RADIUS
		then
			subjects[#subjects + 1] = owner
		end
	end

	state.subject = math.min(state.subject, #subjects)
end

function inventory_menu.GetPlaces()
	local places = {"right", "left"}

	for _, weapon in ipairs(inventory_menu.GetSubject().weapon_holder:GetWeapons()) do
		local mount = weapon.weapon:GetMount()

		if mount ~= "hand" and not table.has_value(places, mount) then
			places[#places + 1] = mount
		end
	end

	return places
end

function inventory_menu.GetSocketPosition(subject, place)
	local armature = subject.armature
	local matrix = armature and armature:GetBoneMatrix(SOCKETS[place] or place)

	if not matrix then return end

	matrix:GetMultiplied(armature.Owner.transform:GetWorldMatrix(), socket_world)
	return Vec3(socket_world:GetTranslation())
end

function inventory_menu.IsMount(place)
	return place ~= "right" and place ~= "left"
end

-- the candidates for a place: weapons that fit, then the empty hand
function inventory_menu.GetCandidates(place)
	local candidates = {}

	for _, weapon in ipairs(inventory_menu.GetSubject().weapon_holder:GetWeapons()) do
		if weapon.weapon:CanEquip(place) then candidates[#candidates + 1] = weapon end
	end

	if place == "left" then candidates[#candidates + 1] = false end

	return candidates
end

function inventory_menu.Open()
	if not players.GetLocal() then return end

	state.open = true
	state.subject, state.place = 1, "right"
	inventory_menu.RefreshSubjects()
	event.Call("InventoryMenuChanged")
end

function inventory_menu.Close()
	state.open = false
	event.Call("InventoryMenuChanged")
end

function inventory_menu.SetSubject(index)
	state.subject, state.place = index, "right"
	event.Call("InventoryMenuChanged")
end

function inventory_menu.SetPlace(place)
	state.place = place
	event.Call("InventoryMenuChanged")
end

function inventory_menu.Equip(weapon, place)
	local subject = inventory_menu.GetSubject()
	local holder = subject.weapon_holder

	if players.IsLocal(subject) then
		local input = subject.player_input

		if weapon then
			for index, other in ipairs(holder:GetWeapons()) do
				if other == weapon then input:Select(index, place == "left") end
			end
		else
			input:Select(usercmd.SELECT_EMPTY, true)
		end
	elseif holder:HasAuthority() then
		if weapon then holder:Equip(weapon, place) else holder:EmptyLeftHand() end
	end
end

event.AddListener("KeyInput", "inventory_menu", function(key, press)
	if key ~= "grave_accent" or not press then return end

	if state.open then inventory_menu.Close() else inventory_menu.Open() end

	return true
end)

return inventory_menu
