local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local battlecam = import("lua/battlecam.lua")
local targeting = import("lua/targeting.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local U = import("goluwa/source_engine/units.lua").meters
local SIZE = 14
local LIFT = Vec3(0, 40 * U, 0)

event.AddListener("DrawHUD", "battlecam", function()
	if not battlecam.IsEnabled() then return end

	local target = targeting.Get()

	if not target then return end

	local w, h = render2d.GetSize()
	local screen = render3d.GetMainCamera():WorldPositionToScreen(target:GetPosition() + LIFT, w, h)

	if not screen then return end

	local x, y = screen.x, screen.y - 20 + math.sin(system.GetElapsedTime() * 8) * 3
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.7)
	render2d.DrawRoundedRect(x - SIZE / 2 - 1, y - SIZE / 2 - 1, SIZE + 2, SIZE + 2, 3)
	render2d.SetColor(1, 0.25, 0.25, 0.95)
	render2d.DrawRoundedRect(x - SIZE / 2, y - SIZE / 2, SIZE, SIZE, 2)
end)
