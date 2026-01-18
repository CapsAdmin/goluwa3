local raycast = require("raycast")
local event = require("event")
local render2d = require("render2d.render2d")
local render3d = require("render3d.render3d")
local tostring_object = require("helpers.tostring_object").tostring_object
local gfx = require("render2d.gfx")
local fonts = require("render2d.fonts")
local enable = false
local cached_material = nil
local cached_lines = {}

event.AddListener("Draw2D", "raycast", function(cmd, dt)
	if not enable then return end

	local cam = render3d.GetCamera()
	local origin = cam:GetPosition()
	local direction = cam:GetRotation():GetForward()
	local found = raycast.Cast(origin, direction)

	if found[1] then
		local hit = found[1]

		if hit and hit.sub_mesh and hit.sub_mesh.data then
			local mat = hit.sub_mesh.data

			-- Cache the result if material is the same as last frame
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

				-- Process all properties except Flags
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

			-- Draw cached lines
			local y = 50
			local x = 10
			local line_height = 15
			local indent_size = 15
			local padding = 5
			render2d.SetTexture(nil)

			for i, line in ipairs(cached_lines) do
				local indent_offset = line.indent * indent_size
				-- Draw black background rectangle
				render2d.SetColor(0, 0, 0, 0.7)
				render2d.DrawRect(x + indent_offset - padding, y - padding, 400, line_height + padding)
				-- Draw text
				render2d.SetColor(1, 1, 1, 1)
				fonts.GetFont():DrawText(line.text, x + indent_offset, y)
				y = y + line_height

				-- Draw texture preview if this is a texture
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
		-- Clear cache when nothing is hit
		cached_material = nil
		cached_lines = {}
	end
end)

event.AddListener("KeyInput", "material_debug", function(key, press)
	if not press then return end

	if key == "m" then
		enable = not enable
		print("Material debug: " .. (enable and "ON" or "OFF"))
	end
end)
