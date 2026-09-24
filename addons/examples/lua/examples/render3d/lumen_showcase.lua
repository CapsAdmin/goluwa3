local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("lua/shapes.lua")

local root = Entity.New{Name = "lumen_showcase"}

local floor_mat = shapes.Material{Color = Color(0.35, 0.33, 0.30, 1), Roughness = 0.9}
local dark_mat = shapes.Material{Color = Color(0.12, 0.12, 0.12, 1), Roughness = 0.95}
local white_mat = shapes.Material{Color = Color(0.85, 0.85, 0.85, 1), Roughness = 0.8}

shapes.Box{
	Name = "floor",
	Parent = root,
	Position = Vec3(0, -0.5, 0),
	Size = Vec3(40, 1, 40),
	Material = floor_mat,
	RigidBody = false,
}

local LIGHT_HEIGHT_ABOVE_PEDESTAL = 0.8
local PANEL_HEIGHT_ABOVE_LIGHT = 1.2

local function pedestal(x, z, size)
	local s = size or 1
	shapes.Box{
		Parent = root,
		Position = Vec3(x, s * 0.5, z),
		Size = Vec3(s, s, s),
		Material = dark_mat,
		RigidBody = false,
	}
	return s
end

local function panel(x, z, y, size)
	shapes.Box{
		Parent = root,
		Position = Vec3(x, y, z),
		Size = Vec3(size, 0.1, size),
		Material = white_mat,
		RigidBody = false,
	}
end

local function station(name, x, lumen, color, pedestal_size, panel_size)
	local top = pedestal(x, 0, pedestal_size or 1.5)
	local light_y = top + LIGHT_HEIGHT_ABOVE_PEDESTAL
	panel(x, 0, light_y + PANEL_HEIGHT_ABOVE_LIGHT, panel_size or 3)
	local ent = Entity.New{Name = name, Parent = root}
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(x, light_y, 0))
	local light = ent:AddComponent("light_point")
	light:SetColor(color or Color(1, 0.95, 0.85, 1))
	light:SetLumen(lumen)
	return light
end

station("candle_1lumen", -30, 1, Color(1, 0.6, 0.2, 1))
station("nightlight_10lumen", -20, 10, Color(0.4, 0.8, 1, 1))
station("incandescent_450lumen", -10, 450, Color(1, 0.9, 0.7, 1))
station("incandescent_850lumen", 0, 850, Color(1, 0.92, 0.82, 1))
station("led_1000lumen", 10, 1000, Color(1, 1, 1, 1))
station("headlight_2500lumen", 20, 2500, Color(0.9, 0.95, 1, 1), 2, 4)
station("stage_10000lumen", 30, 10000, Color(1, 0.8, 0.4, 1), 2, 4)
