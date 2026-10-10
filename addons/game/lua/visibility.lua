local visibility = library()

function visibility.SetTreeVisible(entity, visible)
	if entity.visual then entity.visual:SetVisible(visible) end

	for _, child in ipairs(entity:GetChildren()) do
		visibility.SetTreeVisible(child, visible)
	end
end

return visibility
