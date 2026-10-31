local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local screen_fields = import("goluwa/render3d/screen_fields.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local demo = {}
local INTERVAL = 2.4
local HERO = Vec3(0, 1, 0)
demo.Effects = {
	{
		name = "explosion: radial blur, shockwave ring and chromatic aberration in an expanding sphere",
		play = function()
			screen_fields.Add{
				Position = HERO,
				Duration = 0.9,
				Radius = 9,
				Thickness = 0.3,
				Blur = 70,
				Ring = 0.045,
				Aberration = 10,
			}
			vfx.Flash(HERO + Vec3(0, 0.5, 0), Color(1, 0.6, 0.25, 1), 300, 0.4)
		end,
	},
	{
		name = "impact punch: a screen wide zoom with blur and aberration",
		play = function()
			screen_fields.Add{
				Position = HERO,
				Duration = 0.4,
				Attack = 0.2,
				Radius = 200,
				Expand = false,
				Thickness = 1,
				Zoom = 0.07,
				Blur = 45,
				Aberration = 8,
			}
		end,
	},
	{
		name = "limit break: everything outside a sphere around the hero is darkened and desaturated",
		play = function()
			screen_fields.Add{
				Position = HERO,
				Duration = 1.8,
				Attack = 0.25,
				Radius = 3.2,
				Expand = false,
				Thickness = 0.4,
				Darken = 0.85,
				Blur = 14,
			}
		end,
	},
	{
		name = "heat haze: a distortion dome around a point",
		play = function()
			screen_fields.Add{
				Position = Vec3(0, 1.2, -4),
				Duration = 2,
				Attack = 0.3,
				Radius = 3.5,
				Expand = false,
				Thickness = 0.5,
				Haze = 1,
				Ring = 0.01,
			}
		end,
	},
}
local SUN = test_scene.GetNumber("FIELD_SUN", 35)
test_scene.Reset{sun = {elevation = SUN, azimuth = 200}}
local root = test_scene.GetRoot()
shapes.Box{
	Name = "screen_fields_floor",
	Parent = root,
	Position = Vec3(0, -0.5, 0),
	Size = Vec3(80, 1, 80),
	Material = shapes.Material{Color = Color(0.4, 0.4, 0.42, 1), Roughness = 0.7},
	RigidBody = {MotionType = "static"},
}
local COLORS = {
	Color(0.9, 0.25, 0.2, 1),
	Color(0.2, 0.6, 0.95, 1),
	Color(0.95, 0.8, 0.2, 1),
	Color(0.3, 0.85, 0.4, 1),
}

for i = 1, 11 do
	local angle = (i / 12 - 0.5) * math.pi * 1.7
	local distance = 4 + (i % 3) * 3
	shapes.Box{
		Name = "screen_fields_pillar",
		Parent = root,
		Position = Vec3(math.sin(angle) * distance, 1.5, -math.cos(angle) * distance),
		Size = Vec3(0.8, 3, 0.8),
		Material = shapes.Material{Color = COLORS[i % #COLORS + 1], Roughness = 0.5},
		RigidBody = {MotionType = "static"},
	}
end

shapes.Capsule{
	Name = "screen_fields_hero",
	Parent = root,
	Position = Vec3(0, 0.9, 0),
	Material = shapes.Material{Color = Color(0.95, 0.95, 0.95, 1), Roughness = 0.4},
	RigidBody = {MotionType = "static"},
}
local from = Vec3(0, 2.2, 8)
local direction = (Vec3(0, 1.2, 0) - from):GetNormalized()
local rotation = Quat()
rotation:Identity()
rotation:RotateYaw(math.atan2(-direction.x, -direction.z))
rotation:RotatePitch(math.asin(direction.y))
demo.view = View.New{
	Priority = 100,
	Position = from,
	Rotation = rotation,
	FOV = math.rad(70),
	ExposureLock = test_scene.GetNumber("FIELD_EV", 16),
}:Activate()
local fixed = test_scene.GetNumber("FIELD_EFFECT", 0)
local last = -math.huge
local count = 0
local current = demo.Effects[1]

event.AddListener("Update", "screen_fields_demo", function()
	local now = system.GetElapsedTime()

	if now - last < INTERVAL then return end

	last = now
	count = count + 1
	current = demo.Effects[fixed > 0 and fixed or (count - 1) % #demo.Effects + 1]
	current.play()
end)

event.AddListener("Draw2D", "screen_fields_demo", function()
	local _, height = render2d.GetSize()
	debug_draw.DrawTextBlock({current.name}, 16, height - 48, {background_alpha = 0.6})
end)

return demo
