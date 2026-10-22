local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local item_highlight = import("lua/components/item_highlight.lua")
local third_person = import("lua/third_person.lua")
local MAX_DISTANCE = 12
local NAME_SIZE = 30
local KEY_SIZE = 18
local position = Vec3()
local white = Color(1, 1, 1, 1)

event.AddListener("DrawHUD", "item_highlight_hud", function()
	if third_person.IsHudHidden() then return end

	local camera = render3d.GetMainCamera()
	local camera_position = camera:GetPosition()
	local forward = camera:GetRotation():GetForward()
	local w, h = render2d.GetSize()

	for _, item in ipairs(item_highlight.Instances) do
		if item.beams and item:IsDropped() and item:GetAnchor() then
			local center = item:GetAnchor():GetCenter()
			position:Set(center.x, center.y + 0.4, center.z)
			local to_item = position - camera_position
			local distance = to_item:GetLength()
			local facing = to_item:GetNormalized():GetDot(forward)
			local alpha = math.clamp(facing + 0.01, 0, 1) ^ 10 * (1 - distance / MAX_DISTANCE) ^ 0.25

			if distance < MAX_DISTANCE and alpha > 0.001 then
				local screen = camera:WorldPositionToScreen(position, w, h)

				if screen then
					local name = item.Owner.weapon.DisplayName
					local name_w, name_h = render2d.GetTextSize(name, nil, NAME_SIZE)
					local color = item.Color
					render2d.SetTexture(nil)
					render2d.SetColor(0, 0, 0, 0.6 * alpha)
					render2d.DrawRoundedRect(screen.x - name_w / 2 - 40, screen.y - 4, name_w + 80, name_h + 8, 4)
					render2d.DrawText{
						text = name,
						x = screen.x - name_w / 2,
						y = screen.y,
						size = NAME_SIZE,
						foreground_color = color,
						alpha = alpha,
					}
					local key_w = render2d.GetTextSize("E  TAKE", nil, KEY_SIZE)
					render2d.DrawText{
						text = "E  TAKE",
						x = screen.x - key_w / 2,
						y = screen.y + name_h + 8,
						size = KEY_SIZE,
						foreground_color = white,
						alpha = alpha * 0.9,
					}
				end
			end
		end
	end
end)
