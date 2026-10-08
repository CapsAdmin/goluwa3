local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local water = import("goluwa/render3d/water.lua")
local WAVE_KEYS = {
	"WindSpeed",
	"WindDirection",
	"Choppiness",
	"Development",
	"SwellHeight",
	"SwellWavelength",
	"SwellDirection",
	"Seed",
}

if SERVER then
	local function send(filter)
		local params = {}

		for _, key in ipairs(WAVE_KEYS) do
			params[key] = water.ocean[key]
		end

		message.Send("ocean_waves", filter, params)
	end

	event.AddListener("ClientEntered", "water_sync", send)

	event.AddListener("OceanChanged", "water_sync", function()
		send(nil)
	end)
end

if CLIENT then
	message.AddListener("ocean_waves", function(params)
		water.SetOcean(params)
	end)
end
