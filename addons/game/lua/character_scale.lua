local character_scale = {}

function character_scale.Get(entity)
	local movement = entity.character_movement

	if movement then return movement.Scale end

	if entity.ai_controller then return entity.transform:GetScale().y end

	local avatar = entity.player_avatar
	return avatar and avatar.Scale or 1
end

return character_scale
