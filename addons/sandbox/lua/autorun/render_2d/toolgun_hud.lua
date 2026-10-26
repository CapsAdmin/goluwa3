local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local system = import("goluwa/system.lua")
local third_person = import("lua/third_person.lua")
local toolgun = import("lua/toolgun.lua")
local spawnmenu = RENDER_3D and import("lua/spawnmenu.lua")
local BUTTON = import("goluwa/network/usercmd.lua").BUTTON
local MARGIN = 24
local WIDTH = 360
local PADDING = 14
local LINE_GAP = 4
local KEY_WIDTH = 46
local fonts = {}
local keys = {}
local texts = {}
local MOUSE_LABELS = {[BUTTON.ATTACK1] = "LMB", [BUTTON.ATTACK2] = "RMB"}

event.AddListener("DrawHUD", "toolgun_hud", function()
	local rig = _G.PLAYER_RIG

	if not (rig and rig:IsValid()) or third_person.IsHudHidden() or spawnmenu.IsShown() then
		return
	end

	local holder = rig.weapon_holder
	local weapon = holder:GetWeapon("right")

	if not (weapon and weapon.weapon_toolgun) then
		weapon = holder:GetWeapon("left")
	end

	if not (weapon and weapon.weapon_toolgun) then return end

	local primary, secondary = holder:GetButtons(weapon)
	local context = weapon.weapon_toolgun:GetContext()
	context:Refresh()
	local tool = context:GetTool()

	if fonts.theme ~= theme.active then
		fonts.theme = theme.active
		fonts.title = theme.active:GetFont("heading", "L")
		fonts.body = theme.active:GetFont("body", "S")
		fonts.key = theme.active:GetFont("body_strong", "S")
	end

	local instructions = tool.Instructions
	local count = 0
	local left = instructions.Stages and
		instructions.Stages[context:GetStage() + 1] or
		instructions.Left

	if left then
		count = count + 1
		keys[count], texts[count] = MOUSE_LABELS[primary], left
	end

	if instructions.Right and secondary ~= 0 then
		count = count + 1
		keys[count], texts[count] = MOUSE_LABELS[secondary], instructions.Right
	end

	if instructions.Reload then
		count = count + 1
		keys[count], texts[count] = "R", instructions.Reload
	end

	if context.clipboard then
		count = count + 1
		keys[count], texts[count] = "", context.clipboard.count .. " object(s) copied"
	end

	local description = fonts.body:WrapString(tool.Description, WIDTH - PADDING * 2)
	local _, title_h = fonts.title:GetTextSize(tool.DisplayName)
	local _, description_h = fonts.body:GetTextSize(description)
	local _, line_h = fonts.body:GetTextSize("Ag")
	local height = PADDING * 2 + title_h + description_h + LINE_GAP * 5 + count * (
			line_h + LINE_GAP
		)
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7)
	render2d.DrawRoundedRect(MARGIN, MARGIN, WIDTH, height, 8)
	render2d.SetColor(0.35, 0.75, 1, 1)
	render2d.DrawRoundedRect(MARGIN, MARGIN, 4, height, 2)
	local x = MARGIN + PADDING
	local y = MARGIN + PADDING
	render2d.SetColor(1, 1, 1, 1)
	fonts.title:DrawText(tool.DisplayName, x, y, 0)
	y = y + title_h + LINE_GAP * 2
	render2d.SetColor(0.8, 0.82, 0.86, 1)
	fonts.body:DrawText(description, x, y, 0)
	y = y + description_h + LINE_GAP * 3

	for i = 1, count do
		render2d.SetColor(0.45, 0.78, 1, 1)
		fonts.key:DrawText(keys[i], x, y, 0)
		render2d.SetColor(1, 1, 1, 0.92)
		fonts.body:DrawText(texts[i], x + KEY_WIDTH, y, 0)
		y = y + line_h + LINE_GAP
	end

	local w, h = render2d.GetSize()
	local pulse = 7 + math.sin(system.GetElapsedTime() * 8) * 2

	for _, target in ipairs(context.targets) do
		local screen = render3d.GetMainCamera():WorldPositionToScreen(toolgun.GetTargetPosition(target), w, h)

		if screen then
			render2d.SetColor(0, 0, 0, 0.6)
			render2d.DrawCircle(screen.x, screen.y, pulse + 1, 3, 24)
			render2d.SetColor(0.35, 0.75, 1, 1)
			render2d.DrawCircle(screen.x, screen.y, pulse, 2, 24)
		end
	end
end)
