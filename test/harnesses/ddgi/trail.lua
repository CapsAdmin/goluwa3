local pvars = import("goluwa/cli/pvars.lua")
local mode = os.getenv("TRAIL_MODE") or "move"
local out = os.getenv("TRAIL_OUT") or "tmp/trail.png"
local capture_frame = tonumber(os.getenv("TRAIL_FRAME") or "") or 500
local speed = tonumber(os.getenv("TRAIL_SPEED") or "") or 0.02
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
pvars.SetSession("ddgi_debug_gi", os.getenv("TRAIL_RAW") == nil)

for k, v in (os.getenv("TRAIL_PV") or ""):gmatch("(%S+)=(%S+)") do
	pvars.SetSession(k, v == "true" and true or v == "false" and false or tonumber(v))
end

local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")

local function box(name, position, size, material)
	return shapes.Box{Name = name, Position = position, Size = size, Material = material, Collision = false, RigidBody = false}
end

local white = shapes.Material{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9, Metallic = 0}
local grey = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.9, Metallic = 0}
local orange = shapes.Material{Color = Color(0.9, 0.4, 0.05, 1), Roughness = 0.9, Metallic = 0}
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200), white)
if os.getenv("TRAIL_BIG") then
	box("tower_a", Vec3(600, 150, 600), Vec3(20, 300, 20), grey)
	box("tower_b", Vec3(-700, 100, -400), Vec3(20, 200, 20), grey)
end

do
	local t, w, h = 0.4, 8, 4
	box("back", Vec3(0, h / 2, -w / 2), Vec3(w + t, h, t), grey)
	box("left", Vec3(-w / 2, h / 2, 0), Vec3(t, h, w), grey)
	box("right", Vec3(w / 2, h / 2, 0), Vec3(t, h, w), grey)
	box("front_left", Vec3(-2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
	box("front_right", Vec3(2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
	box("front_top", Vec3(0, 3.1, w / 2), Vec3(1.6, 1.8, t), grey)
end

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(QuatDeg3(-25, 0, 0))
	end
end

local function place(a)
	return Vec3(2.5 * math.cos(a), 0.3, 2.5 * math.sin(a))
end

local final_angle = capture_frame * speed
local mover = box("mover", mode == "static" and place(final_angle) or place(0), Vec3(0.8, 0.6, 0.8), orange)
View.New{
	Priority = 100,
	HideAvatars = true,
	Position = Vec3(0, 8, 0),
	Rotation = QuatDeg3(-90, 0, 0),
	OrthoMode = true,
	OrthoHalfHeight = 4.5,
	ExposureLock = tonumber(os.getenv("TRAIL_EV") or "") or 13,
}:Activate()
local frame = 0
local t200
Event.AddListener("Update", "trail", function()
	frame = frame + 1
	if frame == 200 then t200 = System.GetElapsedTime() end

	if mode == "move" then mover.transform:SetPosition(place(frame * speed)) end

	if frame == capture_frame then
		Screenshot(function(texture)
			texture:SaveWithoutAlpha(out)
			logf("[trail] saved %s mode=%s angle=%.3f fps=%.0f\n", out, mode, final_angle, (capture_frame - 200) / (System.GetElapsedTime() - t200))
			System.ShutDown(0)
		end, {update_events = 0})
	end
end)
