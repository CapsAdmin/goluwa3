local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local BaseTheme = import("./base.lua")
local PlayfulTheme = objects.CreateTemplate("ui_theme_playful")
PlayfulTheme.Base = BaseTheme
PlayfulTheme.Name = "playful"

do
	local function get_button_pivot_target(pnl)
		local mpos = system.GetWindow():GetMousePosition()
		local local_pos = pnl.transform:GlobalToLocal(mpos)
		local size = pnl.transform:GetSize()
		local pivot = local_pos / size
		return -pivot + Vec2(1, 1)
	end

	local function get_button_angle_target(pnl)
		local mpos = system.GetWindow():GetMousePosition()
		local local_pos = pnl.transform:GlobalToLocal(mpos)
		local size = pnl.transform:GetSize()
		local nx = (local_pos.x / size.x) * 2 - 1
		local ny = (local_pos.y / size.y) * 2 - 1
		return Ang3(-ny, nx, 0) * 0.01
	end

	function PlayfulTheme:UpdateButtonAnimations(pnl)
		local state = pnl:GetState()
		state.anim = state.anim or
			{
				glow_alpha = 0,
				press_scale = 0,
				last_hovered = state.hovered or false,
				last_active = false,
				last_tilting = false,
			}
		local anim = state.anim
		local is_active = not state.disabled and
			(
				((
					state.hovered and
					state.pressed
				))
				or
				(
					state.active or
					false
				)
			)
		local is_tilting = is_active

		if is_active ~= anim.last_active then
			if not pnl.animation then
				anim.press_scale = is_active and 1 or 0
				pnl.transform:SetDrawScaleOffset(is_active and (Vec2() + 0.97) or Vec2(1, 1))
			else
				pnl.animation:Animate{
					id = "press_scale",
					get = function()
						return anim.press_scale
					end,
					set = function(value)
						anim.press_scale = value
					end,
					to = is_active and 1 or 0,
					interpolation = (state.pressed and not state.hovered) and "linear" or "inOutSine",
					time = (state.pressed and not state.hovered) and 0.2 or 0.1,
				}
				pnl.animation:Animate{
					id = "DrawScaleOffset",
					get = function()
						return pnl.transform:GetDrawScaleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawScaleOffset(value)
					end,
					to = is_active and (Vec2() + 0.97) or (Vec2(1, 1)),
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 100},
					time = (state.pressed and not state.hovered) and 0.2 or nil,
				}
			end

			anim.last_active = is_active
		end

		if state.hovered ~= anim.last_hovered then
			if not pnl.animation then
				anim.glow_alpha = (state.hovered and not state.disabled) and 1 or 0
			else
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = (state.hovered and not state.disabled) and 1 or 0,
					interpolation = "inOutSine",
					time = 0.1,
				}
			end

			anim.last_hovered = state.hovered
		end

		if is_tilting ~= anim.last_tilting or is_tilting then
			if not pnl.animation then
				pnl.transform:SetPivot(is_tilting and get_button_pivot_target(pnl) or Vec2(0.5, 0.5))
				pnl.transform:SetDrawAngleOffset(is_tilting and get_button_angle_target(pnl) or Ang3(0, 0, 0))
			else
				pnl.animation:Animate{
					id = "Pivot",
					get = function()
						return pnl.transform:GetPivot()
					end,
					set = function(value)
						pnl.transform:SetPivot(value)
					end,
					to = not is_tilting and
						Vec2(0.5, 0.5) or
						{
							__lsx_value = function(panel)
								return get_button_pivot_target(panel)
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
				pnl.animation:Animate{
					id = "DrawAngleOffset",
					get = function()
						return pnl.transform:GetDrawAngleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawAngleOffset(value)
					end,
					to = not is_tilting and
						Ang3(0, 0, 0) or
						{
							__lsx_value = function(panel)
								return get_button_angle_target(panel)
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
			end

			anim.last_tilting = is_tilting
		end
	end
end

return PlayfulTheme:Register()
