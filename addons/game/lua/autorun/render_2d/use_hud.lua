local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local AABB = import("goluwa/structs/aabb.lua")
local third_person = import("lua/third_person.lua")
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
local TEXT = Color(1, 1, 1, 1)
local KEY_TEXT = Color(0.1, 0.1, 0.1, 1)
local current
local last_center
local last_prompt = ""
local alpha = 0

local function draw_reticle(x, y, size, a)
	render2d.SetTexture(nil)

	for i = 0, 3 do
		local angle = i * math.pi / 2 + system.GetElapsedTime() * -1.6
		local half = size / 2
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		render2d.Rotate(angle)
		render2d.SetColor(0, 0, 0, 0.6 * a)
		render2d.DrawRoundedRect(half - 3, -9, 8, 18, 2)
		render2d.SetColor(1, 1, 1, a)
		render2d.DrawRoundedRect(half - 2, -8, 4, 16, 1)
		render2d.PopMatrix()
	end

	render2d.SetColor(1, 1, 1, a * 0.9)
	render2d.DrawCircle(x, y, size / 2 - 6, 1.5, 40)
end

event.AddListener("DrawHUD", "use_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsHudHidden() then return end

	local dt = system.GetFrameTime()
	local usable

	if not rig.health:IsDead() and not rig.character_pose:GetSeat():IsValid() then
		usable = usable_component.Find(rig)
	end

	if usable then
		current = usable
		last_prompt = usable.Prompt
		local owner = usable.Owner
		local box = visual_bounds.Get(owner, bounds) or
			owner.rigid_body:GetBroadphaseAABB(nil, nil, bounds)
		last_center = box:GetCenter()
		alpha = math.min(alpha + dt * FADE_IN_SPEED, 1)
	else
		alpha = math.max(alpha - dt * FADE_OUT_SPEED, 0)
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

	draw_reticle(screen.x, screen.y, BASE_SIZE + (1 - ease) * 50 + pulse * 30, ease)
	local text = last_prompt:upper()
	local text_w, text_h = render2d.GetTextSize(text, nil, TEXT_SIZE)
	local key_w, key_h = render2d.GetTextSize(KEY, nil, TEXT_SIZE)
	local box_w = key_w + KEY_PADDING * 2
	local total = box_w + 14 + text_w
	local x = (w - total) / 2
	local y = h / 3
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55 * ease)
	render2d.DrawRoundedRect(x - 40, y - 8, total + 80, text_h + 16, 6)
	render2d.SetColor(0.92, 0.92, 0.92, ease)
	render2d.DrawRoundedRect(x, y - 2, box_w, text_h + 4, 5)
	render2d.DrawText{
		text = KEY,
		x = x + KEY_PADDING,
		y = y,
		size = TEXT_SIZE,
		foreground_color = KEY_TEXT,
		alpha = ease,
		softness = 0,
	}
	render2d.DrawText{
		text = text,
		x = x + box_w + 14,
		y = y,
		size = TEXT_SIZE,
		foreground_color = TEXT,
		alpha = ease,
	}
end)
