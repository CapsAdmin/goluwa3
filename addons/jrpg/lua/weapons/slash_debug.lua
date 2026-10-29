local Vec3 = import("goluwa/structs/vec3.lua")
return {
	Values = {
		WorldSize = Vec3(0.1, 0.1, 0.1),
		Slot = 9.5,
		DisplayName = "Slash Debug",
		Category = "melee",
		PoseArms = false,
		FireRate = 0.3,
	},
	Nodes = {},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local slash = import("lua/jrpg/slash.lua")
local SLASH = {"slash"}
local META = objects.CreateTemplate("weapon_slash_debug")
local DIRECTIONS = {
	{"down", Vec3(0, -1, 0)},
	{"up", Vec3(0, 1, 0)},
	{"left", Vec3(-1, 0, 0)},
	{"right", Vec3(1, 0, 0)},
	{"stab", Vec3(0, 0, 1)},
}
local TEXT = Color(1, 1, 1, 1)
local RED = Color(1, 0.2, 0.2, 1)
local GREEN = Color(0.2, 1, 0.3, 1)
local BLUE = Color(0.3, 0.5, 1, 1)
local CYAN = Color(0.2, 0.9, 1, 1)
local SHOW_TIME = 5
local EXTENT = 0.7

function META:Initialize()
	self.index = 0
end

local function line(id, from, to, color)
	import("goluwa/debug_draw.lua").DrawLine{id = id, from = from, to = to, color = color, width = 2, time = SHOW_TIME, ignore_z = true}
end

function META:OnWeaponPrimary(cmd)
	self.index = self.index % #DIRECTIONS + 1
	local name, local_cut = DIRECTIONS[self.index][1], DIRECTIONS[self.index][2]
	local holder = self.Owner:GetParent()
	local hit, cut, hits, plane_normal = slash.Strike(holder, self.Owner, local_cut, 1, 1, 3, SLASH)
	effects.Text(holder, name, TEXT)

	if not effects.Visual then return false end

	local forward = actors.GetForward(holder)
	local origin = actors.GetCenter(holder) + forward * 1.5
	local normal = plane_normal

	if hits[1] then origin, normal = hits[1].point, hits[1].normal end

	line("slash_debug_cut", origin - cut * EXTENT, origin + cut * EXTENT, RED)
	line("slash_debug_normal", origin, origin + normal * EXTENT, GREEN)
	line("slash_debug_forward", origin - forward * EXTENT, origin + forward * EXTENT, BLUE)
	local a, b = cut * EXTENT, forward * EXTENT
	line("slash_debug_plane_1", origin + a + b, origin + a - b, CYAN)
	line("slash_debug_plane_2", origin + a - b, origin - a - b, CYAN)
	line("slash_debug_plane_3", origin - a - b, origin - a + b, CYAN)
	line("slash_debug_plane_4", origin - a + b, origin + a + b, CYAN)
	print(string.format("slash debug %s: cut %.2f %.2f %.2f normal %.2f %.2f %.2f hits %d", name, cut.x, cut.y, cut.z, normal.x, normal.y, normal.z, #hits))
	return false
end

return META:Register()
]=====],
}
