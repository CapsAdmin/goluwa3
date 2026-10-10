local prefab = import("goluwa/entities/prefab.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local UNIT = import("goluwa/source_engine/units.lua").meters
local outfit = library()
outfit.VisorDistance = 16 * UNIT * 0.9
outfit.BodyRadius = 16 * UNIT
outfit.BodyHeight = 72 * UNIT

outfit.DefaultName = "player_outfit"
local selected = pvars.Setup("cl_outfit", outfit.DefaultName, nil, "prefab used as your player outfit, player_outfit_source is the gmod player model")

function outfit.GetLocalName()
	return selected:Get()
end

-- the player only tells how far it is crouched (player_avatar.crouch_alpha), what that does to the body is up to the outfit
outfit.CrouchScript = [[
local UNIT = import("goluwa/source_engine/units.lua").meters
local Vec3 = import("goluwa/structs/vec3.lua")
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT

function Entity:Update(dt)
	local player = self:GetParent()
	while player:IsValid() and not player.player_avatar do
		player = player:GetParent()
	end
	if not player:IsValid() then return end
	local height = math.lerp(player.player_avatar.crouch_alpha or 0, HEIGHT, CROUCH_HEIGHT)
	self.transform:SetScale(Vec3(1, height / HEIGHT, 1))
	self.transform:SetPosition(Vec3(0, height * 0.5, 0))
end
]]

function outfit.GetName(owner_id)
	return "outfit_" .. owner_id:gsub("[^%w_%-%. ]", "_")
end

function outfit.Exists(name)
	return prefab.definitions[name] ~= nil or vfs.IsFile(prefab.GetPath(name))
end

function outfit.GetDefault()
	return {
		inputs = {},
		entities = {
			{guid = "root", components = {}},
			{
				guid = "body",
				parent = "root",
				properties = {Name = "body"},
				components = {
					transform = {},
					script = {Source = outfit.CrouchScript},
					model = {
						ModelPath = "models/capsule.lua",
						ModelOptions = {radius = outfit.BodyRadius, height = outfit.BodyHeight},
						MaterialConfig = {
							Color = Color.FromHSV(math.random(), 0.75, 1),
							Roughness = 0.45,
							Metallic = 0,
						},
					},
				},
			},
			{
				guid = "visor",
				parent = "root",
				properties = {Name = "visor"},
				components = {
					transform = {Attachment = "head", Position = FORWARD * outfit.VisorDistance},
					model = {
						ModelPath = "models/box.lua",
						ModelOptions = {size = Vec3(0.34, 0.1, 0.12)},
						MaterialConfig = {
							Color = Color(0.05, 0.05, 0.06, 1),
							Roughness = 0.1,
							Metallic = 0.6,
						},
					},
				},
			},
		},
	}
end

function outfit.LoadLocal()
	local name = outfit.GetLocalName()

	if not outfit.Exists(name) then
		prefab.Register(name, outfit.GetDefault())
		prefab.Save(name)
	end

	prefab.Get(name).local_only = true
	return name
end

return outfit
