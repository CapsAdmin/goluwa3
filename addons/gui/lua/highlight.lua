local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local system = import("goluwa/system.lua")
local highlight = library()
local overlay_matrix = Matrix44()
local listener_key = "gui_highlight_service"
local highlighted_entity = nil

local function is_valid_entity(entity)
	return entity and entity.IsValid and entity:IsValid() or false
end

local function get_drawable_target(entity)
	if not is_valid_entity(entity) then return nil end

	local target = entity.visual

	if not target then return nil end

	local entries = target:GetRenderEntries()
	return entries and entries[1] and target or nil
end

local function is_drawable_model_entity(entity)
	return get_drawable_target(entity) ~= nil
end

local function is_drawable_2d_entity(entity)
	return is_valid_entity(entity) and
		entity.transform and
		entity.gui_element and
		entity.gui_element.GetVisible and
		entity.gui_element:GetVisible()
end

local function draw_overlay_polygon(polygon, material, world_matrix)
	if not polygon then return end

	render3d.SetWorldMatrix(world_matrix)
	render3d.SetMaterial(material)
	render3d.UploadForwardOverlayConstants()
	polygon:Draw()
end

local function draw_visual_model_overlay(entity)
	local target = get_drawable_target(entity)

	if not target then return end

	local world_matrix = target:GetWorldMatrix()

	if not world_matrix then return end

	local pulse = (math.sin(system.GetElapsedTime() * 6) + 1) * 0.5
	local alpha = 0.2 + pulse * 0.35
	local emissive = 0.12 + pulse * 0.32
	local material = debug_draw.GetMaterial{
		shape_type = "generic",
		color = Color(1, 0.35 + pulse * 0.35, 0.15, alpha),
		emissive = Color(emissive, emissive * 0.6, emissive * 0.25, 1),
		ignore_z = true,
		translucent = true,
		double_sided = true,
	}

	local entries = target.GetRenderEntries and target:GetRenderEntries() or target.Primitives or {}

	for _, prim in ipairs(entries) do
		if prim.polygon3d then
			local final_matrix = world_matrix

			if prim.transform and prim.transform.GetWorldMatrix then
				final_matrix = prim.transform:GetWorldMatrix()
			elseif prim.local_matrix then
				final_matrix = prim.local_matrix:GetMultiplied(world_matrix, overlay_matrix)
			end

			draw_overlay_polygon(prim.polygon3d, material, final_matrix)
		end
	end
end

local function draw_2d_overlay(entity)
	if not is_drawable_2d_entity(entity) then return end

	local transform = entity.transform
	local gui = entity.gui_element
	local size = transform:GetSize()

	if size.x <= 0 or size.y <= 0 then return end

	local pulse = (math.sin(system.GetElapsedTime() * 6) + 1) * 0.5
	local fill_alpha = 0.05 + pulse * 0.08
	local outline_alpha = 0.45 + pulse * 0.35
	local radius = gui.GetBorderRadius and gui:GetBorderRadius() or 0
	local masked, clip_x1, clip_y1, clip_x2, clip_y2 = transform:BeginScrollViewportMask(0, 0, size.x, size.y)

	if masked == nil then return end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	render2d.SetTexture(nil)
	render2d.SetColor(1, 0.55 + pulse * 0.25, 0.18, fill_alpha)

	if radius > 0 then
		render2d.SetBorderRadius(radius, radius, radius, radius)
	end

	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetBorderRadius(0, 0, 0, 0)
	render2d.SetColor(1, 0.7 + pulse * 0.2, 0.3, outline_alpha)
	gfx.DrawOutlinedRect(0, 0, size.x, size.y, 2, radius)
	render2d.PopMatrix()
	transform:EndScrollViewportMask(masked, clip_x1, clip_y1, clip_x2, clip_y2)
end

local function draw_3d_overlay()
	if is_drawable_model_entity(highlighted_entity) then
		draw_visual_model_overlay(highlighted_entity)
	elseif highlighted_entity ~= nil and not is_drawable_2d_entity(highlighted_entity) then
		highlighted_entity = nil
	end
end

local function draw_2d_highlight_overlay()
	if is_drawable_2d_entity(highlighted_entity) then
		draw_2d_overlay(highlighted_entity)
	elseif highlighted_entity ~= nil and not is_drawable_model_entity(highlighted_entity) then
		highlighted_entity = nil
	end
end

function highlight.EnableHighlight(entity)
	local next_entity = nil

	if is_drawable_model_entity(entity) or is_drawable_2d_entity(entity) then
		next_entity = entity
	end

	highlighted_entity = next_entity
	return next_entity
end

function highlight.DisableHighlight()
	return highlight.EnableHighlight(nil)
end

function highlight.GetHighlightedEntity()
	return highlighted_entity
end

function highlight.Clear()
	highlighted_entity = nil
end

event.AddListener("Draw3DForwardOverlay", listener_key, draw_3d_overlay)
event.AddListener("Draw2D", listener_key, draw_2d_highlight_overlay)
return highlight
