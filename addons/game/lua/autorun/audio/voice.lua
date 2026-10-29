local event = import("goluwa/event.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PlayerAvatar = import("lua/components/player_avatar.lua")
local mouth_world = Matrix44()

event.AddListener("ClientVoiceOrigin", "player_mouth", function(client)
	for _, avatar in ipairs(PlayerAvatar.Instances or {}) do
		local mouth = avatar.Owner:GetOwnedBy() == client and
			avatar.armature and
			avatar.armature:GetBoneMatrix("mouth")

		if mouth then
			mouth:GetMultiplied(avatar.Owner.transform:GetWorldMatrix(), mouth_world)
			return Vec3(mouth_world:GetTranslation()),
			Vec3(-mouth_world.m20, -mouth_world.m21, -mouth_world.m22):GetNormalized()
		end
	end
end)
