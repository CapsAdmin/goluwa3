local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local system = import("goluwa/system.lua")
local highlight = library()
highlight.entity = NULL

function highlight.SetEntity(entity)
	highlight.entity = entity or NULL
end

function highlight.GetEntity()
	return highlight.entity
end

local overlay_matrix = Matrix44()
local material = debug_draw.GetMaterial{
	shape_type = "generic",
	ignore_z = true,
	translucent = true,
	double_sided = true,
}

event.AddListener("Draw3DForwardOverlay", "highlight", function()
	local ent = highlight.entity

	if not ent:IsValid() then return end

	if not ent.visual or not ent.visual.Is3D then return end

	local pulse = (math.sin(system.GetElapsedTime() * 6) + 1) * 0.5
	local alpha = 0.2 + pulse * 0.35
	local emissive = 0.12 + pulse * 0.32
	local world_matrix = ent.transform:GetWorldMatrix()
	material:SetColorMultiplier(Color(1, 0.35 + pulse * 0.35, 0.15, alpha))
	material:SetEmissiveMultiplier(Color(emissive, emissive * 0.6, emissive * 0.25, 1))

	for _, prim in ipairs(ent.visual:GetRenderEntries()) do
		if prim.polygon3d then
			local final_matrix = world_matrix

			if prim.transform and prim.transform.GetWorldMatrix then
				final_matrix = prim.transform:GetWorldMatrix()
			elseif prim.local_matrix then
				final_matrix = prim.local_matrix:GetMultiplied(world_matrix, overlay_matrix)
			end

			render3d.SetWorldMatrix(final_matrix)
			render3d.SetMaterial(material)
			render3d.UploadForwardOverlayConstants()
			prim.polygon3d:Draw()
		end
	end
end)

event.AddListener("Draw2D", "highlight", function()
	local ent = highlight.entity

	if not ent:IsValid() then return end

	if not ent.transform or not ent.transform.Is2D then return end

	local size = ent.transform:GetSize()

	if size.x <= 0 or size.y <= 0 then return end

	local pulse = (math.sin(system.GetElapsedTime() * 6) + 1) * 0.5
	local fill_alpha = 0.05 + pulse * 0.08
	local outline_alpha = 0.45 + pulse * 0.35
	local masked, clip_x1, clip_y1, clip_x2, clip_y2 = ent.transform:BeginScrollViewportMask(0, 0, size.x, size.y)

	if masked == nil then return end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(ent.transform:GetWorldMatrix())
	render2d.SetTexture(nil)
	render2d.SetColor(1, 0.55 + pulse * 0.25, 0.18, fill_alpha)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetColor(1, 0.7 + pulse * 0.2, 0.3, outline_alpha)
	render2d.DrawOutlinedRect(0, 0, size.x, size.y, 2)
	render2d.PopMatrix()
	ent.transform:EndScrollViewportMask(masked, clip_x1, clip_y1, clip_x2, clip_y2)
end)

return highlight
