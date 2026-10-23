local Color = import("goluwa/structs/color.lua")
local DRY_TIME = 40
local QUENCH = 0.85
return {
	name = "water",
	channels = {"wet"},
	Init = function(cell) end,
	Apply = function(sim, cell, amount)
		cell.wet = math.min(math.max(cell.wet, amount), 1)
		cell.heat = cell.heat * (1 - amount * QUENCH)
		cell.ignition = 0
	end,
	Step = function(sim, cell, dt)
		if cell.heat > 0 then
			local weather = sim.GetWeatherWetness(cell)

			if weather > cell.wet then
				cell.wet = weather
				sim.Touch(cell)
			end
		end

		if cell.wet <= 0 then return false end

		if cell.frost <= 0 then
			cell.wet = math.max(cell.wet - dt / DRY_TIME * (1 + cell.heat * 4), 0)
			sim.Touch(cell)
		end

		return cell.wet > 0
	end,
	Site = function(cell)
		return math.min(cell.wet, cell.heat) * 2, 0, 0, 0
	end,
	particles = {
		{
			Name = "steam",
			Inherit = 0.4,
			Count = 2048,
			Value = 0,
			Rate = 3,
			MaxRate = 150,
			Life = {1, 2.5},
			Size = {0.2, 1.2},
			Rise = {0.6, 1.5},
			Height = {0.02, 0.2},
			Jitter = 0.3,
			Buoyancy = 0.8,
			Drag = 1,
			Turbulence = 0.6,
			Wind = 1,
			ColorStart = Color(0.95, 0.95, 0.95, 0.2),
			ColorEnd = Color(1, 1, 1, 0),
		},
	},
	glsl = {
		surface = [[
			if (e.wet > 0.0) {
				apply_surface_wetness(s, w, e.wet * (1.0 - smoothstep(0.0, 0.3, e.frost)));
			}
		]],
	},
}
