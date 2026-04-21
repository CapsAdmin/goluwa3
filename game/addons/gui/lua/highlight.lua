local Color = import("goluwa/structs/color.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local event = import("goluwa/event.lua")
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

local function is_drawable_model_entity(entity)
	return is_valid_entity(entity) and
		entity.model and
		entity.model.Primitives and
		entity.model.Primitives[1] ~= nil
end

local function draw_overlay_polygon(polygon, material, world_matrix)
	if not polygon then return end

	render3d.SetWorldMatrix(world_matrix)
	render3d.SetMaterial(material)
	render3d.UploadGBufferConstants()
	polygon:Draw()
end

local function draw_visual_model_overlay(entity)
	if not is_drawable_model_entity(entity) then return end

	local world_matrix = entity.model:GetWorldMatrix()

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

	for _, prim in ipairs(entity.model.Primitives) do
		if prim.polygon3d then
			local final_matrix = world_matrix

			if prim.local_matrix then
				final_matrix = prim.local_matrix:GetMultiplied(world_matrix, overlay_matrix)
			end

			draw_overlay_polygon(prim.polygon3d, material, final_matrix)
		end
	end
end

local function draw_overlay()
	if is_drawable_model_entity(highlighted_entity) then
		draw_visual_model_overlay(highlighted_entity)
	elseif highlighted_entity ~= nil then
		highlighted_entity = nil
	end
end

function highlight.EnableHighlight(entity)
	local next_entity = is_drawable_model_entity(entity) and entity or nil
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

event.AddListener("Draw3DGeometryOverlay", listener_key, draw_overlay)
return highlight
