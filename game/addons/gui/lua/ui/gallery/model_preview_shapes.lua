local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local ModelPreview = import("game/addons/gui/lua/model_preview.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")

local function create_material(color, emissive)
	return Material.New{
		ColorMultiplier = color,
		EmissiveMultiplier = emissive or Color(color.r * 0.1, color.g * 0.1, color.b * 0.1, 1),
		DoubleSided = true,
	}
end

local function create_primitive_entity(name, build_polygon, material, transform_props)
	local poly = Polygon3D.New()
	build_polygon(poly)
	poly:Upload()
	local entity = Entity.New{Name = name}
	entity:AddComponent("transform")
	entity:AddComponent("model")
	entity.model:AddPrimitive(poly, material)
	entity.model:BuildAABB()
	entity.model:SetUseOcclusionCulling(false)

	if transform_props then
		if transform_props.position then
			entity.transform:SetPosition(transform_props.position)
		end

		if transform_props.scale then
			entity.transform:SetScale(transform_props.scale)
		end

		if transform_props.angles then
			entity.transform:SetAngles(transform_props.angles)
		end
	end

	return entity
end

local function build_tile(definition)
	local preview_panel
	local entity
	local preview
	local base_angles = definition.base_angles or Ang3(0, 0, 0)

	local function cleanup()
		if preview and preview.IsValid and preview:IsValid() then preview:Remove() end

		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end

		preview = nil
		entity = nil
	end

	return Frame{
		Padding = Rect() + 12,
		layout = {
			FitWidth = true,
			FitHeight = true,
			MinSize = Vec2(188, 236),
		},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				layout = {
					Size = Vec2(164, 164),
					MinSize = Vec2(164, 164),
					MaxSize = Vec2(164, 164),
				},
				Ref = function(self)
					preview_panel = self
					self:AddGlobalEvent("Update")
					entity = definition.build_entity()
					preview = ModelPreview.New{
						Padding = definition.padding or 1.12,
						AmbientStrength = definition.ambient or 0.34,
						LightStrength = definition.light or 0.95,
					}
					preview:SetEntity(entity)
					preview:Refresh()
				end,
				OnRemove = function()
					cleanup()
				end,
				OnUpdate = function(self)
					if not entity or not entity:IsValid() or not preview or not preview:IsValid() then
						return
					end

					local t = system.GetElapsedTime()
					entity.transform:SetAngles(
						Ang3(
							base_angles.x + math.sin(t * (definition.pitch_speed or 0.65)) * (
									definition.pitch_range or
									0.18
								),
							base_angles.y + t * (definition.yaw_speed or 0.9),
							base_angles.z + math.cos(t * (definition.roll_speed or 0.5)) * (
									definition.roll_range or
									0.06
								)
						)
					)
					preview:Refresh()
				end,
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					render2d.SetTexture(nil)
					render2d.SetColor(0.05, 0.06, 0.08, 1)
					render2d.DrawRect(0, 0, size.x, size.y)
					render2d.SetColor(1, 1, 1, 0.05)
					gfx.DrawOutlinedRect(0, 0, size.x, size.y, 1, 16)

					if preview and preview.IsValid and preview:IsValid() then
						render2d.SetTexture(preview:GetTexture())
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(6, 6, size.x - 12, size.y - 12)
					end
				end,
			},
			Text{
				Text = definition.label,
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = definition.description,
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
		},
	}
end

local function build_definitions()
	return {
		{
			label = "Box",
			description = "A simple cube rendered through the offscreen model preview helper.",
			build_entity = function()
				return create_primitive_entity(
					"preview_box",
					function(poly)
						poly:CreateCube(0.55, 1.0)
					end,
					create_material(Color(0.95, 0.42, 0.28, 1))
				)
			end,
			yaw_speed = 0.9,
		},
		{
			label = "Sphere",
			description = "Dense enough to show curved shading while staying cheap in the gallery.",
			build_entity = function()
				return create_primitive_entity(
					"preview_sphere",
					function(poly)
						poly:CreateSphere(0.62, 24, 16, 1.0)
					end,
					create_material(Color(0.28, 0.72, 1.0, 1), Color(0.08, 0.16, 0.24, 1))
				)
			end,
			yaw_speed = 0.72,
			pitch_speed = 0.48,
		},
		{
			label = "Pillar",
			description = "A scaled box to show how the preview framing adapts to tall bounds.",
			build_entity = function()
				return create_primitive_entity(
					"preview_pillar",
					function(poly)
						poly:CreateCube(0.38, 1.0)
					end,
					create_material(Color(0.86, 0.8, 0.34, 1), Color(0.18, 0.14, 0.02, 1)),
					{scale = Vec3(0.9, 2.2, 0.9)}
				)
			end,
			padding = 1.18,
			yaw_speed = 0.6,
		},
		{
			label = "Plate",
			description = "A thin plane to show shallow shapes still fit the orthographic camera cleanly.",
			build_entity = function()
				return create_primitive_entity(
					"preview_plate",
					function(poly)
						poly:CreatePlane(
							Vec3(0, 0, 0),
							Vec3(0, 0, 1),
							Vec3(1, 0, 0),
							Vec3(0, 1, 0),
							0.8,
							0.58,
							1.0
						)
					end,
					create_material(Color(0.64, 0.36, 0.96, 1), Color(0.08, 0.03, 0.16, 1)),
					{angles = Ang3(0.3, 0, 0)}
				)
			end,
			base_angles = Ang3(0.3, 0, 0),
			yaw_speed = 1.05,
			pitch_range = 0.1,
		},
		{
			label = "Diamond",
			description = "A rotated cube to show off-axis silhouettes in the same preview setup.",
			build_entity = function()
				return create_primitive_entity(
					"preview_diamond",
					function(poly)
						poly:CreateCube(0.46, 1.0)
					end,
					create_material(Color(0.4, 0.9, 0.78, 1), Color(0.04, 0.12, 0.1, 1)),
					{angles = Ang3(0.7, 0.4, 0.3)}
				)
			end,
			base_angles = Ang3(0.7, 0.4, 0.3),
			yaw_speed = 0.84,
			roll_speed = 0.9,
			roll_range = 0.12,
		},
		{
			label = "Offset Sphere",
			description = "The mesh is shifted off the entity origin to demonstrate origin-targeted preview framing.",
			build_entity = function()
				return create_primitive_entity(
					"preview_offset_sphere",
					function(poly)
						poly:CreateSphere(0.48, 22, 14, 1.0)

						for _, vertex in ipairs(poly.Vertices) do
							vertex.pos = vertex.pos + Vec3(0.38, 0.12, 0)
						end

						poly:BuildBoundingBox()
					end,
					create_material(Color(1.0, 0.62, 0.22, 1), Color(0.2, 0.08, 0.02, 1))
				)
			end,
			padding = 1.16,
			yaw_speed = 0.66,
			pitch_speed = 0.52,
		},
	}
end

return {
	Name = "3d model preview",
	Create = function()
		local definitions = build_definitions()
		local rows = {}

		for i = 1, #definitions, 3 do
			local children = {}

			for j = i, math.min(i + 2, #definitions) do
				children[#children + 1] = build_tile(definitions[j])
			end

			rows[#rows + 1] = Row{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					AlignmentY = "start",
					ChildGap = 12,
				},
			}(children)
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				Padding = Rect(20, 20, 20, 20),
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Primitive entities rendered into 256x256 offscreen textures through the new model preview helper. Each tile owns its own entity and preview renderer.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Column{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = 12,
				},
			}(rows),
		}
	end,
}
