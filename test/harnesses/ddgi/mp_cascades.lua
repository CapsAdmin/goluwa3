-- a MP_EXTRA file for test/harnesses/perf/map_perf.lua: prints the DDGI cascades each view ends with (spacing, probes per axis, how far
-- each one reaches from the camera, how many of the ten are in use). MP_MAP=quarry MP_EXTRA=test/harnesses/ddgi/mp_cascades.lua
local ddgi = import("goluwa/render3d/ddgi.lua")
local render3d = import("goluwa/render3d/render3d.lua")

function _G.MP_REPORT()
	local state = ddgi.GetFrameState()
	local camera = render3d.GetCamera():GetPosition()
	local lines = {}

	for i = 1, state.cascade_count do
		local c = state.cascades[i]
		local lo_x, hi_x = c.x * c.spacing, (c.x + c.size.x) * c.spacing
		local lo_z, hi_z = c.z * c.spacing, (c.z + c.size.z) * c.spacing
		lines[#lines + 1] = string.format(
			"%d: spacing %.2f %dx%dx%d reaches x %.0f..%.0f z %.0f..%.0f (camera %.0f %.0f)",
			i - 1,
			c.spacing,
			c.size.x,
			c.size.y,
			c.size.z,
			lo_x - camera.x,
			hi_x - camera.x,
			lo_z - camera.z,
			hi_z - camera.z,
			camera.x,
			camera.z
		)
	end

	print("MP cascades " .. state.cascade_count .. " in use")

	for _, line in ipairs(lines) do
		print("MP   " .. line)
	end
end
