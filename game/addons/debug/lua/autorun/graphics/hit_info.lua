local raycast = import("goluwa/physics/raycast.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local tostring_object = import("goluwa/helpers/tostring_object.lua").tostring_object
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
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
end

local enabled = false

event.AddListener("KeyInput", "material_debug", function(key, press)
	if not press then return end

	if key == "m" then
		enabled = not enabled

		if enabled then
			event.AddListener("Render2D", "material_debug_draw", draw)
		else
			event.RemoveListener("Render2D", "material_debug_draw")
		end

		print("Material debug: " .. (enable and "ON" or "OFF"))
	end
end)
