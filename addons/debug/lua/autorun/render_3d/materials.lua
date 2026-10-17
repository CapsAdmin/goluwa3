local raycast = import("goluwa/render3d/raycast.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local tostring_object = import("goluwa/tostring_object.lua").tostring_object
local commands = import("goluwa/cli/commands.lua")
local Material = import("goluwa/render3d/material.lua")

do
	local cached_material = nil
	local cached_lines = {}

	local function draw(cmd, dt)
		local cam = render3d.GetCamera()
		local origin = cam:GetPosition()
		local direction = cam:GetRotation():GetForward()
		local found = raycast.Cast(origin, direction)

		if found[1] then
			local hit = found[1]

			if hit and hit.primitive and hit.primitive.material then
				local mat = hit.primitive.material

				if mat ~= cached_material then
					cached_material = mat
					cached_lines = {}
					local props = mat:GetStorableTable()
					local tbl = table.to_list(props, function(a, b)
						return a.key > b.key
					end)

					if mat.vmt_surfaceprop then
						table.insert(tbl, {key = "vmt surface prop", val = tostring_object(mat.vmt_surfaceprop)})
					end

					for i, prop in ipairs(tbl) do
						local is_texture = type(prop.val) == "table" and prop.val.GetSize
						table.insert(
							cached_lines,
							{
								text = tostring(prop.key) .. ": " .. tostring(prop.val),
								indent = 0,
								texture = is_texture and prop.val or nil,
							}
						)
					end
				end

				local y = 50
				local x = 10
				local line_height = 15
				local indent_size = 15
				local padding = 5
				render2d.SetTexture(nil)

				for i, line in ipairs(cached_lines) do
					local indent_offset = line.indent * indent_size
					render2d.SetColor(0, 0, 0, 0.7)
					render2d.DrawRect(x + indent_offset - padding, y - padding, 400, line_height + padding)
					render2d.DrawText{text = line.text, x = x + indent_offset, y = y}
					y = y + line_height

					if line.texture then
						local tex_size = 100
						render2d.SetTexture(line.texture)
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(x + indent_offset, y, tex_size, tex_size)
						y = y + tex_size + 10
						render2d.SetTexture(nil)
					end
				end
			end
		else
			cached_material = nil
			cached_lines = {}
		end
	end

	local enabled = false

	input.Bind("m", "material_debug", function()
		enabled = not enabled

		if enabled then
			event.AddListener("Draw2D", "material_debug_draw", draw)
		else
			event.RemoveListener("Draw2D", "material_debug_draw")
		end

		print("Material debug: " .. (enabled and "ON" or "OFF"))
	end)
end

do
	local function color_is_default(color)
		return color and color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1
	end

	commands.Add("dump_cached_materials", function()
		local rows = {}

		for material, stats in pairs(Material.GetCacheStats()) do
			local sources = {}

			for source in pairs(stats.sources) do
				sources[#sources + 1] = source
			end

			table.sort(sources)
			rows[#rows + 1] = {
				material = material,
				requests = stats.requests,
				source = table.concat(sources, "+"),
				primary_key = stats.key_order[1] or "<unknown>",
				key_count = #stats.key_order,
			}
		end

		table.sort(rows, function(a, b)
			if a.requests ~= b.requests then return a.requests > b.requests end

			return a.primary_key < b.primary_key
		end)

		print(string.format("[cached_materials] unique=%d", #rows))

		for _, row in ipairs(rows) do
			print(
				string.format(
					"[cached_materials] requests=%d source=%s keys=%d material=%s",
					row.requests,
					row.source,
					row.key_count,
					row.primary_key
				)
			)
		end
	end)

	commands.Add("dump_cached_material_feature_summary", function()
		local stats = Material.GetCacheStats()
		local materials = {}

		for material in pairs(stats) do
			materials[#materials + 1] = material
		end

		local counts = {
			total = #materials,
			vmt = 0,
			crymtl = 0,
			albedo = 0,
			normal = 0,
			detail_blend = 0,
			detail_normal = 0,
			metallic_roughness = 0,
			metallic = 0,
			roughness = 0,
			transmission_texture = 0,
			ambient_occlusion_texture = 0,
			emissive_texture = 0,
			nondefault_factor = 0,
			nondefault_color = 0,
			nondefault_ao = 0,
			emissive_enabled = 0,
			displacement = 0,
			terrain = 0,
			transmission = 0,
		}

		for _, material in ipairs(materials) do
			local sources = stats[material].sources

			if sources.vmt then counts.vmt = counts.vmt + 1 end

			if sources.crymtl then counts.crymtl = counts.crymtl + 1 end

			if material:GetAlbedoTexture() ~= nil then counts.albedo = counts.albedo + 1 end

			if material:GetNormalTexture() ~= nil then counts.normal = counts.normal + 1 end

			if material:GetAlbedo2Texture() ~= nil or material:GetBlendTexture() ~= nil then
				counts.detail_blend = counts.detail_blend + 1
			end

			if material:GetNormal2Texture() ~= nil or material:GetDetailTexture() ~= nil then
				counts.detail_normal = counts.detail_normal + 1
			end

			if material:GetMetallicRoughnessTexture() ~= nil then
				counts.metallic_roughness = counts.metallic_roughness + 1
			end

			if material:GetMetallicTexture() ~= nil then
				counts.metallic = counts.metallic + 1
			end

			if material:GetRoughnessTexture() ~= nil then
				counts.roughness = counts.roughness + 1
			end

			if material:GetTransmissionTexture() ~= nil then
				counts.transmission_texture = counts.transmission_texture + 1
			end

			if material:GetAmbientOcclusionTexture() ~= nil then
				counts.ambient_occlusion_texture = counts.ambient_occlusion_texture + 1
			end

			if material:GetEmissiveTexture() ~= nil then
				counts.emissive_texture = counts.emissive_texture + 1
			end

			if not color_is_default(material:GetColorMultiplier()) then
				counts.nondefault_color = counts.nondefault_color + 1
			end

			if
				material:GetMetallicMultiplier() ~= 1.0 or
				material:GetRoughnessMultiplier() ~= 1.0 or
				material:GetRoughnessMin() ~= 0.0 or
				material:GetRoughnessMax() ~= 1.0 or
				material:GetMetallicMaskMin() ~= 0.0 or
				material:GetMetallicMaskMax() ~= 1.0 or
				material:GetAlphaCutoff() ~= 0.5
			then
				counts.nondefault_factor = counts.nondefault_factor + 1
			end

			if material:GetAmbientOcclusionMultiplier() ~= 1.0 then
				counts.nondefault_ao = counts.nondefault_ao + 1
			end

			if
				material:GetEmissiveTexture() ~= nil or
				material:GetAlbedoAlphaIsEmissive() or
				material:GetAdditive() or
				material:GetMetallicTextureAlphaIsEmissive()
			then
				counts.emissive_enabled = counts.emissive_enabled + 1
			end

			if material:HasHeightMap() then
				counts.displacement = counts.displacement + 1
			end

			if material:GetTerrainMaterialTexture() ~= nil then
				counts.terrain = counts.terrain + 1
			end

			if material:GetTransmissive() then
				counts.transmission = counts.transmission + 1
			end
		end

		print(
			string.format(
				"[cached_material_features] total=%d vmt=%d crymtl=%d",
				counts.total,
				counts.vmt,
				counts.crymtl
			)
		)
		print(
			string.format(
				"[cached_material_features] base albedo=%d normal=%d",
				counts.albedo,
				counts.normal
			)
		)
		print(
			string.format(
				"[cached_material_features] detail_blend=%d detail_normal=%d",
				counts.detail_blend,
				counts.detail_normal
			)
		)
		print(
			string.format(
				"[cached_material_features] metallic_roughness=%d metallic=%d roughness=%d transmission_texture=%d",
				counts.metallic_roughness,
				counts.metallic,
				counts.roughness,
				counts.transmission_texture
			)
		)
		print(
			string.format(
				"[cached_material_features] ao_texture=%d ao_nondefault=%d emissive_texture=%d emissive_enabled=%d",
				counts.ambient_occlusion_texture,
				counts.nondefault_ao,
				counts.emissive_texture,
				counts.emissive_enabled
			)
		)
		print(
			string.format(
				"[cached_material_features] factor_nondefault=%d color_nondefault=%d",
				counts.nondefault_factor,
				counts.nondefault_color
			)
		)
		print(
			string.format(
				"[cached_material_features] displacement=%d terrain=%d transmission=%d",
				counts.displacement,
				counts.terrain,
				counts.transmission
			)
		)
	end)
end
