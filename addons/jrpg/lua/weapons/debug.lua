local Vec3 = import("goluwa/structs/vec3.lua")
return {
	Values = {
		WorldSize = Vec3(0.1, 0.1, 0.1),
		Slot = 9.5,
		DisplayName = "Debug",
		Category = "melee",
		PoseArms = false,
		FireRate = 0,
	},
	Nodes = {},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local actors = import("lua/actors.lua")
local damage = import("lua/damage.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local effects = import("lua/jrpg/effects.lua")
local slash = import("lua/jrpg/slash.lua")
local BULLET = "bullet"
local RANGE = 50
local IMPULSE = 6
local TYPES = {BULLET}

for _, list in ipairs{damage_types.Physical, damage_types.Names} do
	for _, name in ipairs(list) do
		if name ~= "generic" then TYPES[#TYPES + 1] = name end
	end
end

local DAMAGES = {1, 5, 10, 20, 40}
local META = objects.CreateTemplate("weapon_debug")
local DIRECTIONS = {
	{"down", Vec3(0, -1, 0)},
	{"up", Vec3(0, 1, 0)},
	{"left", Vec3(-1, 0, 0)},
	{"right", Vec3(1, 0, 0)},
	{"stab", Vec3(0, 0, 1)},
}
local TEXT = Color(1, 1, 1, 1)
local RED = Color(1, 0.2, 0.2, 1)
local SHOW_TIME = 5
local EXTENT = 0.7
local ARROW_HEAD = 0.25
local ARROW_WING = 0.15

function META:Initialize()
	self.index = 0
	self.damage_index = 4
	self.type_index = 1
	self.aimed = true
	self:AddGlobalEvent("Draw2D")
end

function META:NextDamage(cmd)
	self.damage_index = self.damage_index % #DAMAGES + 1
end

function META:Select(cmd)
	if not usercmd.HasButton(cmd, usercmd.BUTTON.ACTIVE) then return end

	if usercmd.WasPressed(cmd, usercmd.BUTTON.RELOAD) then
		self.type_index = self.type_index % #TYPES + 1
		return "type"
	end

	if usercmd.WasPressed(cmd, usercmd.BUTTON.ATTACK3) then
		self.aimed = not self.aimed
		return "aim"
	end
end

function META:OnWeaponSecondary(cmd)
	self:NextDamage()
	effects.Text(self.Owner:GetParent(), "damage " .. DAMAGES[self.damage_index], TEXT)
end

function META:OnWeaponPredictSecondary(cmd)
	self:NextDamage()
end

function META:OnWeaponThink(dt, cmd)
	local changed = self:Select(cmd)
	local holder = self.Owner:GetParent()

	if changed == "type" then
		local type_name = TYPES[self.type_index]
		effects.Text(holder, type_name, damage_types.GetColor(type_name == BULLET and "generic" or type_name))
	elseif changed == "aim" then
		effects.Text(holder, self.aimed and "aimed" or "assisted", TEXT)
	end
end

function META:OnWeaponPredictThink(dt, cmd)
	self:Select(cmd)
end

function META:OnDraw2D()
	local holder = self.Owner:GetParent()

	if not holder.player_input or not self.Owner.weapon:IsEquipped() then return end

	local width, height = render2d.GetSize()
	local type_name = TYPES[self.type_index]
	local bullet = type_name == BULLET
	debug_draw.DrawTextBlock(
		{
			"debug weapon",
			"mode    " .. (bullet and "bullet (hitscan)" or "strike, " .. (self.aimed and "aimed" or "assisted") .. " (" .. DIRECTIONS[self.index % #DIRECTIONS + 1][1] .. " next)"),
			"type    " .. (bullet and "generic" or type_name),
			"damage  " .. DAMAGES[self.damage_index],
			"left click fire, right click damage, reload type, F aimed or assisted",
		},
		width,
		height,
		{
			padding = 8,
			line_gap = 3,
			background_alpha = 0.7,
			title_color = damage_types.GetColor(bullet and "generic" or type_name),
			text_color = TEXT,
		}
	)
end

local function line(id, from, to, color)
	import("goluwa/debug_draw.lua").DrawLine{id = id, from = from, to = to, color = color, width = 2, time = SHOW_TIME, ignore_z = true}
end

function META:OnWeaponPrimary(cmd)
	local holder = self.Owner:GetParent()
	local type_name = TYPES[self.type_index]

	if type_name == BULLET then
		effects.Text(holder, "bullet " .. DAMAGES[self.damage_index], TEXT)
		local origin = holder.transform:GetPosition() + holder.character_movement:GetViewOffset()
		local aim = cmd.aim:GetForward()
		local trace = damage.Sweep(origin, aim * RANGE, holder)

		if not trace then return end

		weapon_effects.Hit(self.Owner, trace.point, trace.normal, aim * IMPULSE)
		local victim = trace.entity and damage.GetVictim(trace.entity)

		if victim and victim.health then
			damage.Deal(
				victim,
				{
					Attacker = holder,
					Inflictor = self.Owner,
					Damage = DAMAGES[self.damage_index],
					Type = "generic",
					Position = trace.point,
					Normal = trace.normal,
					Force = aim * IMPULSE,
					Part = trace.entity.ragdoll_part and trace.entity.ragdoll_part.Group,
				}
			)
		end

		return
	end

	self.index = self.index % #DIRECTIONS + 1
	local name, local_cut = DIRECTIONS[self.index][1], DIRECTIONS[self.index][2]
	local hit, cut, hits, plane_normal = slash.Strike(
		holder,
		self.Owner,
		actors.GetForward(holder),
		local_cut,
		DAMAGES[self.damage_index],
		1,
		3,
		{type_name},
		self.aimed and {Origin = holder.transform:GetPosition() + holder.character_movement:GetViewOffset(), Direction = cmd.aim:GetForward()} or nil
	)
	effects.Text(holder, name .. " " .. DAMAGES[self.damage_index] .. " " .. type_name, TEXT)

	if not effects.Visual then return false end

	local forward = actors.GetForward(holder)
	local origin = actors.GetCenter(holder) + forward * 1.5
	local normal = plane_normal

	if hits[1] then origin, normal = hits[1].point, hits[1].normal end

	local side = normal:GetCross(cut)

	if side:GetLength() < 1e-3 then side = Vec3(0, 1, 0):GetCross(cut) end

	side = side:GetNormalized() * ARROW_WING
	local tip = origin + cut * EXTENT
	local head = tip - cut * ARROW_HEAD
	line("debug_arrow_shaft", origin - cut * EXTENT, tip, RED)
	line("debug_arrow_wing_1", tip, head + side, RED)
	line("debug_arrow_wing_2", tip, head - side, RED)
	print(string.format("slash debug %s: cut %.2f %.2f %.2f normal %.2f %.2f %.2f hits %d", name, cut.x, cut.y, cut.z, normal.x, normal.y, normal.z, #hits))
	return false
end

return META:Register()
]=====],
}
