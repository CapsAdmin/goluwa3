local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local View = import("goluwa/render3d/view.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local grenade_effects = import("lua/grenade_effects.lua")
local fluid_scene = {}
_G.fluid_scene = fluid_scene
render3d.SetOceanEnabled(false)
local root = Entity.New{Name = "fluid_scene"}
local concrete = shapes.Material{Color = Color(0.55, 0.55, 0.57, 1), Roughness = 0.8, Metallic = 0}
local grey = shapes.Material{Color = Color(0.85, 0.85, 0.85, 1), Roughness = 0.5, Metallic = 0}

local function box(name, position, size, material)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Material = material,
		RigidBody = {MotionType = "static"},
	}
end

box("ground", Vec3(0, -0.5, 0), Vec3(90, 1, 70), concrete)
box("wall", Vec3(0, 2, -6), Vec3(24, 4, 0.5), grey)
box("ledge", Vec3(-4, 3.2, 0), Vec3(2.5, 0.2, 1.5), grey)
box("pit_left", Vec3(2.2, 0.4, 0), Vec3(0.3, 0.8, 4), concrete)
box("pit_right", Vec3(5.8, 0.4, 0), Vec3(0.3, 0.8, 4), concrete)

local function lamp(kind, name, position, rotation, color, lumen, range, shadows)
	local entity = Entity.New{
		Name = name,
		Parent = root,
		transform = {Position = position, Rotation = rotation},
	}
	local light = entity:AddComponent(kind)
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetRange(range)
	light:SetSourceRadius(0.08)

	if shadows then
		local shadow = entity:AddComponent("shadow_map_point")
		shadow:SetSize(Vec2() + 512)
		shadow:SetNearPlane(0.05)
		shadow:SetFarPlane(range)
	end

	return light
end

box("lamp_post", Vec3(-6.5, 1.75, 1.2), Vec3(0.12, 3.5, 0.12), grey)
lamp(
	"light_point",
	"street_lamp",
	Vec3(-6.2, 3.6, 1.2),
	nil,
	Color(1, 0.78, 0.5, 1),
	6000,
	16,
	true
)
lamp(
	"light_point",
	"pit_lamp",
	Vec3(4, 2.6, 1.6),
	nil,
	Color(0.85, 0.95, 1, 1),
	2500,
	10,
	true
)
local steam_spot = lamp(
	"light_spot",
	"steam_spot",
	Vec3(13.5, 1.2, 2.5),
	QuatDeg3(10, 54, 0),
	Color(1, 1, 1, 1),
	20000,
	20,
	false
)
steam_spot:SetInnerCone(8)
steam_spot:SetOuterCone(16)
lamp(
	"light_point",
	"fog_lamp",
	Vec3(-8, 1.5, -18),
	nil,
	Color(1, 0.6, 0.35, 1),
	15000,
	30,
	false
)
Entity.New{
	Name = "fire",
	Parent = root,
	transform = {Position = Vec3(-4, 3, 0)},
	fluid_volume = {Size = Vec3(3, 6, 3), Resolution = 64, Medium = "smoke"},
}
Entity.New{
	Name = "fire_fuel",
	Parent = root,
	transform = {Position = Vec3(-4, 0.4, 0)},
	fluid_emitter = {
		Radius = 0.45,
		Fuel = 8,
		Smoke = 3,
		Temperature = 1200,
		Velocity = Vec3(0, 0.5, 0),
	},
}
Entity.New{
	Name = "poison",
	Parent = root,
	transform = {Position = Vec3(4, 1.5, 0)},
	fluid_volume = {
		Size = Vec3(6, 3, 6),
		Resolution = 64,
		Medium = "poison",
		Weight = 0.6,
		Buoyancy = 0,
		Dissipation = 0.02,
		Turbulence = 1,
	},
}
Entity.New{
	Name = "poison_leak",
	Parent = root,
	transform = {Position = Vec3(4, 1.4, 0)},
	fluid_emitter = {Radius = 0.3, Smoke = 4, Velocity = Vec3(1.5, 0.5, 0.5)},
}
Entity.New{
	Name = "steam",
	Parent = root,
	transform = {Position = Vec3(10, 3, 0)},
	fluid_volume = {
		Size = Vec3(3, 6, 3),
		Resolution = 48,
		Medium = "steam",
		Dissipation = 0.6,
		Turbulence = 2,
	},
}
Entity.New{
	Name = "steam_vent",
	Parent = root,
	transform = {Position = Vec3(10, 0.3, 0)},
	fluid_emitter = {Radius = 0.25, Smoke = 6, Temperature = 373, Velocity = Vec3(0, 3, 0)},
}
Entity.New{
	Name = "fog_bank",
	Parent = root,
	transform = {Position = Vec3(0, 2, -22)},
	fluid_volume = {
		Size = Vec3(70, 4, 24),
		Resolution = 64,
		Medium = "fog",
		Simulation = "procedural",
		Raymarch = false,
		Fill = 0.3,
		NoiseScale = 6,
		NoiseAmount = 1,
		Floor = false,
		Obstacles = false,
	},
}
local cart = shapes.Box{
	Name = "burning_cart",
	Parent = root,
	Position = Vec3(-6, 0.4, 7),
	Size = Vec3(1.2, 0.8, 0.8),
	Material = grey,
	RigidBody = {MotionType = "kinematic"},
}
Entity.New{
	Name = "cart_smoke",
	Parent = cart,
	transform = {Position = Vec3(0, 2.1, 0)},
	fluid_volume = {Size = Vec3(3, 5, 3), Resolution = 48, Medium = "smoke", Space = "world"},
}
Entity.New{
	Name = "cart_fire",
	Parent = cart,
	transform = {Position = Vec3(0, 0.8, 0)},
	fluid_emitter = {
		Radius = 0.35,
		Fuel = 8,
		Smoke = 2,
		Temperature = 1200,
		Velocity = Vec3(0, 0.5, 0),
	},
}
fluid_scene.cart_speed = 0.35

event.AddListener("Update", "fluid_scene_cart", function()
	if not cart:IsValid() then return event.destroy_tag end

	cart.transform:SetPosition(Vec3(-3 + math.sin(system.GetElapsedTime() * fluid_scene.cart_speed) * 4, 0.4, 7))
end)

local BLAST_PAD = Vec3(4, 0.05, 14)
local BLAST_RADIUS = 6
local UP = Vec3(0, 1, 0)
grenade_effects.PrewarmFluid(BLAST_RADIUS, 3)

function fluid_scene.Explode(position)
	grenade_effects.ExplodeFluid(position or BLAST_PAD, UP, BLAST_RADIUS)
end

function fluid_scene.ExplodeSprites(position)
	grenade_effects.Explode(position or BLAST_PAD, UP, BLAST_RADIUS)
end

box("blast_pad", Vec3(BLAST_PAD.x, 0.01, BLAST_PAD.z), Vec3(2, 0.02, 2), concrete)

local function button(name, x, prompt, color, press)
	box(name .. "_pedestal", Vec3(x, 0.5, 21), Vec3(0.5, 1, 0.5), grey)
	local cap = shapes.Box{
		Name = name,
		Parent = root,
		Position = Vec3(x, 1.05, 21),
		Size = Vec3(0.3, 0.1, 0.3),
		Material = shapes.Material{Color = color, Roughness = 0.4, Metallic = 0},
		RigidBody = {MotionType = "static"},
	}
	cap:AddComponent("usable", {Prompt = prompt})

	function cap:OnUsed()
		press()
		self.transform:SetPosition(Vec3(x, 1.02, 21))

		timer.Delay(0.2, function()
			if self:IsValid() then self.transform:SetPosition(Vec3(x, 1.05, 21)) end
		end)

		return true
	end

	return cap
end

button(
	"button_sprites",
	2.8,
	"sprite explosion",
	Color(0.9, 0.5, 0.1, 1),
	function()
		fluid_scene.ExplodeSprites()
	end
)

button(
	"button_fluid",
	5.2,
	"fluid explosion",
	Color(0.15, 0.45, 0.9, 1),
	function()
		fluid_scene.Explode()
	end
)

function fluid_scene.Barrage(interval)
	timer.Repeat(
		"fluid_scene_barrage",
		interval or 2.5,
		0,
		function()
			fluid_scene.Explode(BLAST_PAD + Vec3(math.randomf(-2, 2), 0, math.randomf(-2, 2)))
		end
	)
end

function fluid_scene.StopBarrage()
	timer.RemoveTimer("fluid_scene_barrage")
end

function fluid_scene.Drop(position)
	local crate = shapes.Box{
		Name = "crate",
		Parent = root,
		Position = position or Vec3(4, 3.5, 0),
		Size = Vec3(0.8, 0.8, 0.8),
		Material = grey,
		RigidBody = {MotionType = "dynamic", Mass = 40},
	}
	return crate
end

function fluid_scene.Roll(from, velocity)
	local ball, body = shapes.Sphere{
		Name = "ball",
		Parent = root,
		Position = from or Vec3(-1, 0.5, 0),
		Radius = 0.45,
		Material = grey,
		RigidBody = {MotionType = "dynamic", Mass = 20},
	}
	body:SetVelocity(velocity or Vec3(4, 0, 0))
	return ball
end

function fluid_scene.Puff(position, smoke, temperature)
	fluid_volumes.Splat(
		position or Vec3(-4, 1.2, 0),
		0.6,
		{smoke = smoke or 3, temperature = temperature or 900, velocity = Vec3(0, 4, 0)}
	)
end

fluid_scene.cameras = {
	overview = {Vec3(2, 3, 13), Vec3(-8, 0, 0)},
	fire = {Vec3(-4, 1.8, 5), Vec3(-2, 0, 0)},
	poison = {Vec3(4, 2.5, 6), Vec3(-20, 0, 0)},
	steam = {Vec3(10, 2.5, 6), Vec3(-5, 0, 0)},
	cart = {Vec3(-3, 2.5, 14), Vec3(-10, 0, 0)},
	explosions = {Vec3(4, 3.5, 30), Vec3(-6, 0, 0)},
	buttons = {Vec3(4, 1.7, 23.5), Vec3(-15, 0, 0)},
}

function fluid_scene.Goto(name)
	local camera = assert(fluid_scene.cameras[name], "unknown camera " .. tostring(name))

	if fluid_scene.view then fluid_scene.view:Remove() end

	fluid_scene.view = View.New{
		Priority = 100,
		Position = camera[1],
		Rotation = QuatDeg3(camera[2].x, camera[2].y, camera[2].z),
	}:Activate()
end

if os.getenv("CAM") then fluid_scene.Goto(os.getenv("CAM")) end
