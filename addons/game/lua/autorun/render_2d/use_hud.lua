local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local AABB = import("goluwa/structs/aabb.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local targeting = import("lua/targeting.lua")
local third_person = import("lua/third_person.lua")
local camera_modes = import("lua/camera_modes.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local usable_component = import("lua/components/usable.lua")
local bounds = AABB(0, 0, 0, 0, 0, 0)
local KEY = "E"
local TEXT_SIZE = 28
local KEY_PADDING = 10
local BASE_SIZE = 70
local PULSE_TIME = 0.35
local FADE_IN_SPEED = 6
local FADE_OUT_SPEED = 3
local current
local last_center
local last_prompt = ""
local last_name
local last_name_color
local alpha = 0
local prompt_alpha = 0
local locked

event.AddListener("DrawHUD", "use_hud", function()
	local rig = _G.PLAYER_RIG

	if
		not (
			rig and
			rig:IsValid()
		) or
		third_person.IsHudHidden() or
		camera_modes.IsHudHidden()
	then
		return
	end

	local dt = system.GetFrameTime()
	local target = targeting.Get()
	local usable

	if not rig.health:IsDead() and not rig.character_pose:GetSeat():IsValid() then
		usable = usable_component.Find(rig)

		if usable and target and usable.Owner ~= target.Owner then usable = nil end
	end

	local focus = target and target.Owner or usable and usable.Owner

	if focus then
		locked = target ~= nil
		local box = visual_bounds.Get(focus, bounds) or
			focus.rigid_body:GetBroadphaseAABB(nil, nil, bounds)
		last_center = box:GetCenter()
		alpha = math.min(alpha + dt * FADE_IN_SPEED, 1)
	else
		alpha = math.max(alpha - dt * FADE_OUT_SPEED, 0)
	end

	if usable then
		current = usable
		last_prompt = usable.Prompt
		last_name = usable.Owner.weapon and usable.Owner.weapon:GetTitle()
		last_name_color = event.Call("GetUseColor", usable.Owner)
		prompt_alpha = math.min(prompt_alpha + dt * FADE_IN_SPEED, 1)
	else
		prompt_alpha = math.max(prompt_alpha - dt * FADE_OUT_SPEED, 0)
	end

	if alpha <= 0 then return end

	local w, h = render2d.GetSize()
	local screen = render3d.GetMainCamera():WorldPositionToScreen(last_center, w, h)

	if not screen then return end

	local ease = alpha * alpha
	local pulse = 0

	if current and current:IsValid() then
		pulse = math.max(1 - (system.GetElapsedTime() - current.last_use) / PULSE_TIME, 0)
	end

	local S = h / 1080
	theme.active:DrawReticle(
		screen.x,
		screen.y,
		(BASE_SIZE + (1 - ease) * 50 + pulse * 30) * S,
		{
			kind = locked and "target" or "use",
			alpha = ease,
			time = system.GetElapsedTime(),
		}
	)

	if prompt_alpha <= 0 then return end

	ease = prompt_alpha * prompt_alpha
	local active = theme.active
	local light = active:GetColor("text_on_dark")
	local font, weight = active:GetTextStyle("body_strong")
	local text = last_prompt:upper()
	local text_w, text_h = render2d.GetTextSize(text, font, TEXT_SIZE, weight)
	local key_w, key_h = render2d.GetTextSize(KEY, font, TEXT_SIZE, weight)
	local box_w = key_w + KEY_PADDING * 2
	local name_w = last_name and render2d.GetTextSize(last_name, font, TEXT_SIZE, weight) or 0
	local total = box_w + 14 + text_w + (last_name and 14 + name_w or 0)
	local x = screen.x - total / 2
	local y = screen.y - (BASE_SIZE + pulse * 30) * S / 2 - text_h - 24
	active:DrawHudPanel(x - 40, y - 8, total + 80, text_h + 16, {alpha = ease, opacity = 0.55})
	active:DrawKeycap(x, y - 2, box_w, text_h + 4, KEY, TEXT_SIZE, ease)
	render2d.DrawText{
		text = text,
		x = x + box_w + 14,
		y = y,
		font = font,
		weight = weight,
		size = TEXT_SIZE,
		foreground_color = light,
		alpha = ease,
	}

	if last_name then
		render2d.DrawText{
			text = last_name,
			x = x + box_w + 28 + text_w,
			y = y,
			font = font,
			weight = weight,
			size = TEXT_SIZE,
			foreground_color = last_name_color or light,
			alpha = ease,
		}
	end
end)
