local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local window = require("window")
local event = require("event")
local Panel = require("ecs.entities.2d.panel")
local glow_linear_tex = require("render.textures.glow_linear")
local glow_point_tex = require("render.textures.glow_point")
local gradient_tex = require("render.textures.gradient_linear")

local function line(x1, y1, x2, y2, thickness, tex)
	render2d.SetTexture(tex or glow_linear_tex)
	render2d.PushMatrix()
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.Translate(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

return function(props)
	local value = props.Value or 0.5
	local min_value = props.Min or 0
	local max_value = props.Max or 1
	local is_dragging = false
	local is_hovered = false
	local glow_alpha = 0
	local knob_scale = 1
	local ent
	local last_hovered

	local function SetValueFromPosition(x)
		local size = ent.transform:GetSize()
		local knob_width = 20
		local usable_width = size.x - knob_width
		local normalized = math.max(0, math.min(1, (x - knob_width / 2) / usable_width))
		value = min_value + normalized * (max_value - min_value)

		if props.OnChange then props.OnChange(value) end
	end

	local function UpdateAnimations()
		if not ent then return end

		if is_hovered ~= last_hovered then
			ent.animation:Animate(
				{
					id = "glow_alpha",
					get = function()
						return glow_alpha
					end,
					set = function(val)
						glow_alpha = val
					end,
					to = is_hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.15,
				}
			)
			ent.animation:Animate(
				{
					id = "knob_scale",
					get = function()
						return knob_scale
					end,
					set = function(val)
						knob_scale = val
					end,
					to = is_hovered and 1.2 or 1,
					interpolation = {
						type = "spring",
						bounce = 0.5,
						duration = 80,
					},
				}
			)
			last_hovered = is_hovered
		end
	end

	ent = Panel(
		{
			Name = "slider",
			Position = props.Position or (not props.Layout and Vec2(100, 100) or nil),
			Size = props.Size or Vec2(300, 40),
			Layout = props.Layout,
			Margin = props.Margin or Rect() + 10,
			Cursor = "hand",
			Color = Color(0, 0, 0, 0),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" then
						if press then
							is_dragging = true
							SetValueFromPosition(local_pos.x)
						end

						return true
					end
				end,
				OnGlobalMouseInput = function(self, button, press, mouse_pos)
					if button == "button_1" and not press and is_dragging then
						is_dragging = false
						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				is_hovered = hovered
				UpdateAnimations()
			end,
			gui_element = {
				OnDraw = function(self)
					if is_hovered then UpdateAnimations() end

					local size = self.Owner.transform.Size
					local track_height = 6
					local track_y = (size.y - track_height) / 2
					local knob_width = 20
					local knob_height = 30
					-- Draw track background
					render2d.SetTexture(nil)
					render2d.SetColor(0.2, 0.2, 0.2, 0.8)
					render2d.DrawRect(knob_width / 2, track_y, size.x - knob_width, track_height)
					-- Draw filled track
					local normalized = (value - min_value) / (max_value - min_value)
					local fill_width = normalized * (size.x - knob_width)
					render2d.PushUV()
					render2d.SetUV2(0, 0, 0.5, 1)
					render2d.SetTexture(gradient_tex)
					render2d.SetColor(0, 0.4, 0.7, 0.9)
					render2d.DrawRect(knob_width / 2, track_y, fill_width, track_height)
					render2d.PopUV()

					-- Glow effect on filled track
					if glow_alpha > 0 then
						render2d.SetBlendMode("additive")
						render2d.SetTexture(glow_linear_tex)
						render2d.SetColor(0, 0.5 * glow_alpha, 1 * glow_alpha, 0.3)
						render2d.DrawRect(knob_width / 2, track_y - 2, fill_width, track_height + 4)
						render2d.SetBlendMode("alpha")
					end

					-- Draw knob
					local knob_x = knob_width / 2 + normalized * (size.x - knob_width) - knob_width / 2
					local knob_y = (size.y - knob_height) / 2
					-- Knob shadow/glow
					render2d.SetTexture(glow_point_tex)
					render2d.SetBlendMode("additive")
					render2d.SetColor(0, 0.3, 0.5, 0.2 + glow_alpha * 0.3)
					local glow_size = 60 * knob_scale
					render2d.DrawRect(
						knob_x + knob_width / 2 - glow_size / 2,
						knob_y + knob_height / 2 - glow_size / 2,
						glow_size,
						glow_size
					)
					render2d.SetBlendMode("alpha")
					-- Knob body
					render2d.SetTexture(nil)
					render2d.SetColor(0.8, 0.8, 0.2, 1)
					local scaled_width = knob_width * knob_scale
					local scaled_height = knob_height * knob_scale
					local scale_offset_x = (scaled_width - knob_width) / 2
					local scale_offset_y = (scaled_height - knob_height) / 2
					render2d.DrawRect(
						knob_x - scale_offset_x,
						knob_y - scale_offset_y,
						scaled_width,
						scaled_height
					)
					-- Knob highlight
					render2d.PushUV()
					render2d.SetUV2(0, 0, 1, 0.5)
					render2d.SetTexture(gradient_tex)
					render2d.SetColor(1, 1, 1, 0.3)
					render2d.DrawRect(
						knob_x - scale_offset_x,
						knob_y - scale_offset_y,
						scaled_width,
						scaled_height * 0.5
					)
					render2d.PopUV()

					-- Edge glow
					if glow_alpha > 0 then
						render2d.SetBlendMode("additive")
						render2d.SetTexture(glow_linear_tex)
						render2d.SetColor(0.35 * glow_alpha, 0.71 * glow_alpha, 0.816 * glow_alpha, 1)
						-- Top edge
						line(
							knob_x - scale_offset_x,
							knob_y - scale_offset_y,
							knob_x + scaled_width - scale_offset_x,
							knob_y - scale_offset_y,
							1
						)
						-- Bottom edge
						line(
							knob_x - scale_offset_x,
							knob_y + scaled_height - scale_offset_y,
							knob_x + scaled_width - scale_offset_x,
							knob_y + scaled_height - scale_offset_y,
							1
						)
						render2d.SetBlendMode("alpha")
					end

					-- Update value during drag
					if is_dragging then
						local mpos = window.GetMousePosition()
						local lpos = self.Owner.transform:GlobalToLocal(mpos)
						SetValueFromPosition(lpos.x)
					end
				end,
			},
		}
	)
	return ent
end
