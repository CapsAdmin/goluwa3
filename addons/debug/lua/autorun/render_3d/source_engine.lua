local commands = import("goluwa/cli/commands.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local fs = import("goluwa/filesystem/fs.lua")
local lights = import("goluwa/source_engine/lights.lua")

commands.Add("dump_unused_vmt_properties", function()
	local vmt_stats = vmt_material.GetStats()
	local unused = {}

	for k, count in pairs(vmt_stats.seen) do
		if not vmt_stats.used[k] then
			local values = {}

			if vmt_stats.values[k] then
				for val, _ in pairs(vmt_stats.values[k]) do
					table.insert(values, val)
				end

				table.sort(values)
			end

			table.insert(unused, {key = k, count = count, values = values})
		end
	end

	table.sort(unused, function(a, b)
		if a.count ~= b.count then return a.count > b.count end

		return a.key < b.key
	end)

	print("Unused VMT properties (found in files but never accessed by code):")

	for _, item in ipairs(unused) do
		local val_str = #item.values > 0 and
			(
				" (values: " .. table.concat(item.values, ", ") .. ")"
			)
			or
			""
		print(string.format("  %-30s %d%s", item.key, item.count, val_str))
	end

	if #unused == 0 then
		print("  None! All properties found in VMTs have been accessed at least once.")
	end
end)

commands.Add("bsp_dump_lights", function()
	local lines = {}

	for component in pairs(lights.GetInstances()) do
		local owner = component.Owner
		local light = owner.light_spot or owner.light_point
		local pos = owner.transform:GetPosition()
		local raw = {}

		for key, value in pairs(component.Info) do
			raw[#raw + 1] = key .. "=" .. tostring(
					type(value) == "table" and
						table.concat({value.r, value.g, value.b, value.brightness}, ",") or
						value
				)
		end

		table.sort(raw)
		lines[#lines + 1] = string.format(
			"%s #%d at %.2f %.2f %.2f\n  bsp: %s\n  engine: color %.3f %.3f %.3f  lumen %.4g  candela %.4g  range %g  source radius %.2f  linear %.4g  quadratic %.4g  effective range %.2f%s",
			owner:GetName(),
			#lines + 1,
			pos.x,
			pos.y,
			pos.z,
			table.concat(raw, "  "),
			light.Color.r,
			light.Color.g,
			light.Color.b,
			light.Lumen,
			light.Lumen * light:GetInverseEmissionSolidAngle(),
			light.Range,
			light.SourceRadius,
			light.LinearFalloff,
			light.QuadraticFalloff,
			light:GetEffectiveRange(),
			light.Type == "light_spot" and
				string.format("  cone %g..%g", light.InnerCone, light.OuterCone) or
				""
		)
	end

	local path = "./storage/logs/bsp_lights.txt"
	fs.write_file(path, table.concat(lines, "\n") .. "\n")
	logf("%d bsp lights written to %s\n", #lines, path)
end)
