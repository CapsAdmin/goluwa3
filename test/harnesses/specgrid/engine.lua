-- SPECGRID_LIVE=1 keeps the engine running without capturing
-- SPECGRID_EYE=x,y,z (source units, printed by gmod's specgrid.lua) luajit glw --3d lua test/harnesses/specgrid/engine.lua
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Quat = import("goluwa/structs/quat.lua")
local event = import("goluwa/event.lua")
local Shot = import("goluwa/render3d/shot.lua")
local commands = import("goluwa/cli/commands.lua")
local Material = import("goluwa/render3d/material.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local s2m = import("goluwa/codecs/internal/source.lua").meters
local ex, ey, ez = os.getenv("SPECGRID_EYE"):match("([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
ex, ey, ez = tonumber(ex), tonumber(ey), tonumber(ez)
local function to_engine(x, y, z) return Vec3(-y, z, -x) * s2m end
local rows = {
	{"envbase", "envmap, mask = base alpha", "cols: alpha 0 64 128 192 255"},
	{"envnormal", "envmap, mask = normal alpha", "cols: alpha 0 64 128 192 255"},
	{"envtint", "envmap, $envmaptint", "cols: tint 0 .25 .5 .75 1"},
	{"phongnormal", "phong boost 4, mask = normal alpha", "cols: alpha 0 64 128 192 255"},
	{"phongbase", "phong boost 4, mask = base alpha", "cols: alpha 0 64 128 192 255"},
	{"phongexp", "phong exponent, no mask", "cols: exponent 5 10 30 100 300"},
}
local spacing = 40
local radius = 17.8
local char_width = 6.3
local live = os.getenv("SPECGRID_LIVE") ~= nil
commands.ExecuteCommandString("map gm_construct")
event.AddListener("BVHSceneReady", "specgrid", function()
	for ri, row in ipairs(rows) do
		local z = ez - 64 + 20 + (#rows - ri) * spacing

		for ci = 1, 5 do
			shapes.Sphere{
				Position = to_engine(ex + 250, ey - (ci - 3) * spacing, z),
				Radius = radius * s2m,
				Collision = false,
				Material = Material.FromVMT("materials/specgrid/" .. row[1] .. "_" .. ci .. ".vmt"),
			}
		end

		local width = math.max(#row[2], #row[3]) * char_width + 16
		debug_draw.DrawText{
			id = "specgrid_label_" .. ri,
			time = 1e9,
			position = to_engine(ex + 250, ey + 2 * spacing + 40, z),
			lines = {row[2], row[3]},
			offset = Vec2(-width, -16),
			title_color = {1, 1, 0.6, 1},
			text_color = {0.8, 0.8, 0.8, 1},
		}
	end

	if live then return event.destroy_tag end

	Shot.Capture({Position = to_engine(ex, ey, ez), Rotation = Quat(0, 0, 0, 1), FOV = 1.287}, function(tex)
		print(tex:SaveWithoutAlpha("test/harnesses/specgrid/engine.png"))
		os.exit(0)
	end, {settle = 6})
	return event.destroy_tag
end)
