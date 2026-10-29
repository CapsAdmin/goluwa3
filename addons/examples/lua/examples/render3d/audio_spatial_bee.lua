local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local CENTER = Vec3(0, 0, 0)
local EYE_HEIGHT = 1.7
local RADIUS = 2
local TILT = math.rad(45)
local LAP_SECONDS = 10
local SAMPLE_RATE = 48000
local WINGBEAT = 220
local scene = _G.audio_spatial_bee_scene

if scene then
	event.RemoveListener("Update", "audio_spatial_bee")
	scene.source:Stop()

	if scene.ground:IsValid() then scene.ground:Remove() end

	if scene.bee:IsValid() then scene.bee:Remove() end
end

local samples = ffi.new("float[?]", SAMPLE_RATE)
local harmonics = math.floor(16000 / WINGBEAT)
local seed = 1
local peak = 0

for i = 0, SAMPLE_RATE - 1 do
	local t = i / SAMPLE_RATE
	local buzz = 0

	for k = 1, harmonics do
		buzz = buzz + math.sin(2 * math.pi * WINGBEAT * k * t + math.pi * k * (k - 1) / harmonics) / math.sqrt(k)
	end

	seed = (seed * 1103515245 + 12345) % 2147483648
	local hiss = seed / 2147483648 - 0.5
	samples[i] = (buzz * 0.2 + hiss * 0.3) * (0.7 + 0.3 * math.sin(2 * math.pi * 26 * t))
	peak = math.max(peak, math.abs(samples[i]))
end

for i = 0, SAMPLE_RATE - 1 do
	samples[i] = samples[i] * 0.9 / peak
end

scene = {}
_G.audio_spatial_bee_scene = scene
scene.ground = shapes.Box{
	Name = "audio_spatial_bee_ground",
	Position = CENTER + Vec3(0, -EYE_HEIGHT - 0.5, 0),
	Size = Vec3(40, 1, 40),
	Material = shapes.Material{Color = Color(0.35, 0.33, 0.3, 1), Roughness = 0.9, Metallic = 0},
	RigidBody = {MotionType = "static"},
}
scene.bee = shapes.Sphere{
	Name = "audio_spatial_bee",
	Position = CENTER + Vec3(RADIUS, 0, 0),
	Radius = 0.06,
	Material = shapes.Material{Color = Color(0.95, 0.75, 0.15, 1), Roughness = 0.5, Metallic = 0},
	Collision = false,
}
scene.source = audio.CreateSource{data = samples, samples = SAMPLE_RATE, channels = 1, sample_rate = SAMPLE_RATE}
scene.source:SetNormalized(true)
scene.source:SetLooping(true)
scene.source:SetPosition(CENTER + Vec3(RADIUS, 0, 0))
scene.source:Play()
local start = system.GetElapsedTime()

event.AddListener("Update", "audio_spatial_bee", function()
	local t = system.GetElapsedTime() - start
	local angle = t / LAP_SECONDS * 2 * math.pi
	local around = math.sin(angle) * RADIUS
	local position = CENTER + Vec3(math.cos(angle) * RADIUS, around * math.sin(TILT), -around * math.cos(TILT))
	scene.bee.transform:SetPosition(position)
	scene.source:SetPosition(position)
	scene.source:SetPitch(1 + math.sin(t * 3.7) * 0.03)
end)

logn(
	"audio_spatial_bee: stand at the center, the bee circles you right, above in front, left and below behind; set audio_pinna to 0 to compare, 2 to exaggerate"
)
