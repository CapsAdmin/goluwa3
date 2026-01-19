local vfs = require("vfs")
local Buffer = require("structs.buffer")
local ttf = library()
ttf.file_extensions = {"ttf", "otf"}

local function read_tag(buffer)
	return buffer:ReadBytes(4)
end

function ttf.DecodeBuffer(input_buffer)
	local font = {}
	-- Offset Table
	font.scaler_type = input_buffer:ReadU32BE()
	font.num_tables = input_buffer:ReadU16BE()
	font.search_range = input_buffer:ReadU16BE()
	font.entry_selector = input_buffer:ReadU16BE()
	font.range_shift = input_buffer:ReadU16BE()
	-- Table Directory
	font.tables = {}

	for i = 1, font.num_tables do
		local tag = read_tag(input_buffer)
		font.tables[tag] = {
			checksum = input_buffer:ReadU32BE(),
			offset = input_buffer:ReadU32BE(),
			length = input_buffer:ReadU32BE(),
		}
	end

	-- Helper to read a table by tag
	function font:GetTableBuffer(tag)
		local info = self.tables[tag]

		if not info then return nil end

		local pos = input_buffer:GetPosition()
		input_buffer:SetPosition(info.offset)
		local data = input_buffer:ReadBytes(info.length)
		input_buffer:SetPosition(pos)
		return Buffer.New(data)
	end

	-- Parse 'name' table for basic font info if available
	local name_table = font:GetTableBuffer("name")

	if name_table then
		font.names = {}
		local format = name_table:ReadU16BE()
		local count = name_table:ReadU16BE()
		local string_offset = name_table:ReadU16BE()

		for i = 1, count do
			local platform_id = name_table:ReadU16BE()
			local encoding_id = name_table:ReadU16BE()
			local language_id = name_table:ReadU16BE()
			local name_id = name_table:ReadU16BE()
			local length = name_table:ReadU16BE()
			local offset = name_table:ReadU16BE()
			local pos = name_table:GetPosition()
			name_table:SetPosition(string_offset + offset)
			local name_bytes = name_table:ReadBytes(length)
			name_table:SetPosition(pos)
			-- We mostly care about English (language_id 0x409 in platform 3, or language 0 in platform 1)
			-- For now just store them. 
			-- Platform 3 (Windows) uses UTF-16BE.
			-- Platform 1 (Macintosh) uses Roman (usually ASCII for names).
			font.names[name_id] = font.names[name_id] or {}
			font.names[name_id][platform_id .. "_" .. encoding_id .. "_" .. language_id] = name_bytes

			-- Common name IDs:
			-- 1: Font Family
			-- 2: Font Subfamily
			-- 4: Full Name
			-- 6: PostScript Name
			if platform_id == 1 and language_id == 0 then
				if name_id == 1 then font.family = name_bytes end

				if name_id == 2 then font.subfamily = name_bytes end

				if name_id == 4 then font.full_name = name_bytes end
			elseif platform_id == 3 and language_id == 0x0409 then
				-- Basic UTF-16BE to ASCII conversion (only works for ASCII characters)
				local ascii = {}

				for j = 1, #name_bytes, 2 do
					table.insert(ascii, name_bytes:sub(j + 1, j + 1))
				end

				local name_str = table.concat(ascii)

				if name_id == 1 then font.family = name_str end

				if name_id == 2 then font.subfamily = name_str end

				if name_id == 4 then font.full_name = name_str end
			end
		end
	end

	-- Parse 'head' for unitsPerEm
	local head_table = font:GetTableBuffer("head")

	if head_table then
		head_table:Advance(18) -- Skip version, revision, checksumAdj, magicNumber, flags
		font.units_per_em = head_table:ReadU16BE()
	end

	-- Parse 'hhea' for ascent, descent, lineGap
	local hhea_table = font:GetTableBuffer("hhea")

	if hhea_table then
		hhea_table:Advance(4) -- Skip version
		font.ascent = hhea_table:ReadI16BE()
		font.descent = hhea_table:ReadI16BE()
		font.line_gap = hhea_table:ReadI16BE()
	end

	-- Parse 'maxp' for numGlyphs
	local maxp_table = font:GetTableBuffer("maxp")

	if maxp_table then
		maxp_table:Advance(4) -- Skip version
		font.num_glyphs = maxp_table:ReadU16BE()
	end

	-- Parse 'OS/2' for extra metrics
	local os2_table = font:GetTableBuffer("OS/2")

	if os2_table then
		local version = os2_table:ReadU16BE()
		os2_table:Advance(6) -- Skip xAvgCharWidth, usWeightClass, usWidthClass
		font.fs_type = os2_table:ReadU16BE()
		os2_table:Advance(58) -- Skip a lot of fields
		font.typo_ascent = os2_table:ReadI16BE()
		font.typo_descent = os2_table:ReadI16BE()
		font.typo_line_gap = os2_table:ReadI16BE()
		font.win_ascent = os2_table:ReadU16BE()
		font.win_descent = os2_table:ReadU16BE()

		if version >= 2 then
			os2_table:Advance(8) -- Skip ulCodePageRange1, ulCodePageRange2
			font.x_height = os2_table:ReadI16BE()
			font.cap_height = os2_table:ReadI16BE()
		end
	end

	-- Parse 'cmap' to map characters to glyph indices
	local cmap_table = font:GetTableBuffer("cmap")

	if cmap_table then
		cmap_table:Advance(2) -- Skip version
		local num_subtables = cmap_table:ReadU16BE()
		local subtable_offset = nil

		-- Prefer Windows Unicode (3, 1) or Unicode (0, 3)
		for i = 1, num_subtables do
			local platform_id = cmap_table:ReadU16BE()
			local encoding_id = cmap_table:ReadU16BE()
			local offset = cmap_table:ReadU32BE()

			if (platform_id == 3 and encoding_id == 1) or (platform_id == 0) then
				subtable_offset = offset

				break
			end
		end

		if subtable_offset then
			cmap_table:SetPosition(subtable_offset)
			local format = cmap_table:ReadU16BE()

			if format == 4 then
				local length = cmap_table:ReadU16BE()
				cmap_table:Advance(2) -- Skip language
				local seg_count_x2 = cmap_table:ReadU16BE()
				local seg_count = seg_count_x2 / 2
				cmap_table:Advance(6) -- Skip searchRange, entrySelector, rangeShift
				local end_codes = {}

				for i = 1, seg_count do
					end_codes[i] = cmap_table:ReadU16BE()
				end

				cmap_table:Advance(2) -- Skip reservedPad
				local start_codes = {}

				for i = 1, seg_count do
					start_codes[i] = cmap_table:ReadU16BE()
				end

				local id_deltas = {}

				for i = 1, seg_count do
					id_deltas[i] = cmap_table:ReadI16BE()
				end

				local id_range_offsets_pos = cmap_table:GetPosition()
				local id_range_offsets = {}

				for i = 1, seg_count do
					id_range_offsets[i] = cmap_table:ReadU16BE()
				end

				function font:GetGlyphIndex(char_code)
					for i = 1, seg_count do
						if end_codes[i] >= char_code then
							if start_codes[i] <= char_code then
								if id_range_offsets[i] == 0 then
									return (char_code + id_deltas[i]) % 65536
								else
									local offset = (
											id_range_offsets_pos + (
												i - 1
											) * 2
										) + id_range_offsets[i] + (
											char_code - start_codes[i]
										) * 2
									cmap_table:SetPosition(offset)
									local glyph_index = cmap_table:ReadU16BE()

									if glyph_index ~= 0 then
										return (glyph_index + id_deltas[i]) % 65536
									end

									return 0
								end
							else
								return 0
							end
						end
					end

					return 0
				end
			end
		end
	end

	-- Parse 'hhea' and 'hmtx' for horizontal metrics
	local hhea_table = font:GetTableBuffer("hhea")
	local hmtx_table = font:GetTableBuffer("hmtx")

	if hhea_table and hmtx_table then
		hhea_table:Advance(34) -- Skip to numberOfHMetrics
		local num_h_metrics = hhea_table:ReadU16BE()
		local h_metrics = {}

		for i = 0, num_h_metrics - 1 do
			h_metrics[i] = {
				advance_width = hmtx_table:ReadU16BE(),
				lsb = hmtx_table:ReadI16BE(),
			}
		end

		function font:GetGlyphMetrics(glyph_index)
			if glyph_index < num_h_metrics then
				return h_metrics[glyph_index]
			else
				-- For glyphs beyond num_h_metrics, advance width is the same as the last one
				local last = h_metrics[num_h_metrics - 1]
				hmtx_table:SetPosition(num_h_metrics * 4 + (glyph_index - num_h_metrics) * 2)
				return {
					advance_width = last.advance_width,
					lsb = hmtx_table:ReadI16BE(),
				}
			end
		end
	end

	-- Parse 'loca' and 'glyf' for actual glyph shapes
	local loca_table = font:GetTableBuffer("loca")
	local glyf_table = font:GetTableBuffer("glyf")
	local head_table = font:GetTableBuffer("head")

	if loca_table and glyf_table and head_table then
		head_table:Advance(50) -- Skip to indexToLocFormat
		local index_to_loc_format = head_table:ReadI16BE()

		function font:GetGlyphData(glyph_index)
			local start_offset, end_offset

			if index_to_loc_format == 0 then
				loca_table:SetPosition(glyph_index * 2)
				start_offset = loca_table:ReadU16BE() * 2
				end_offset = loca_table:ReadU16BE() * 2
			else
				loca_table:SetPosition(glyph_index * 4)
				start_offset = loca_table:ReadU32BE()
				end_offset = loca_table:ReadU32BE()
			end

			if start_offset == end_offset then return nil end -- Empty glyph (like space)
			glyf_table:SetPosition(start_offset)
			local glyph = {}
			glyph.num_contours = glyf_table:ReadI16BE()
			glyph.x_min = glyf_table:ReadI16BE()
			glyph.y_min = glyf_table:ReadI16BE()
			glyph.x_max = glyf_table:ReadI16BE()
			glyph.y_max = glyf_table:ReadI16BE()

			if glyph.num_contours >= 0 then
				-- Simple glyph
				local end_pts_of_contours = {}

				for i = 1, glyph.num_contours do
					end_pts_of_contours[i] = glyf_table:ReadU16BE()
				end

				local instruction_length = glyf_table:ReadU16BE()
				glyf_table:Advance(instruction_length)
				local num_points = end_pts_of_contours[glyph.num_contours] + 1
				local flags = {}
				local i = 1

				while i <= num_points do
					local flag = glyf_table:ReadByte()
					flags[i] = flag
					i = i + 1

					if bit.band(flag, 8) ~= 0 then -- Repeat flag
						local count = glyf_table:ReadByte()

						for j = 1, count do
							flags[i] = flag
							i = i + 1
						end
					end
				end

				local x_coords = {}
				local last_x = 0

				for i = 1, num_points do
					local flag = flags[i]

					if bit.band(flag, 2) ~= 0 then -- X Short Vector
						local val = glyf_table:ReadByte()

						if bit.band(flag, 16) == 0 then val = -val end

						last_x = last_x + val
					else
						if bit.band(flag, 16) == 0 then
							last_x = last_x + glyf_table:ReadI16BE()
						end
					end

					x_coords[i] = last_x
				end

				local y_coords = {}
				local last_y = 0

				for i = 1, num_points do
					local flag = flags[i]

					if bit.band(flag, 4) ~= 0 then -- Y Short Vector
						local val = glyf_table:ReadByte()

						if bit.band(flag, 32) == 0 then val = -val end

						last_y = last_y + val
					else
						if bit.band(flag, 32) == 0 then
							last_y = last_y + glyf_table:ReadI16BE()
						end
					end

					y_coords[i] = last_y
				end

				glyph.points = {}

				for i = 1, num_points do
					glyph.points[i] = {
						x = x_coords[i],
						y = y_coords[i],
						on_curve = bit.band(flags[i], 1) ~= 0,
					}
				end

				glyph.end_pts_of_contours = end_pts_of_contours
			else
				-- Compound glyph
				glyph.is_compound = true
				glyph.components = {}
				local ARG_1_AND_2_ARE_WORDS = 0x0001
				local ARGS_ARE_XY_VALUES = 0x0002
				local WE_HAVE_A_SCALE = 0x0008
				local MORE_COMPONENTS = 0x0020
				local WE_HAVE_AN_X_AND_Y_SCALE = 0x0040
				local WE_HAVE_A_TWO_BY_TWO = 0x0080

				repeat
					local flags = glyf_table:ReadU16BE()
					local glyph_index = glyf_table:ReadU16BE()
					local arg1, arg2

					if bit.band(flags, ARG_1_AND_2_ARE_WORDS) ~= 0 then
						arg1 = glyf_table:ReadI16BE()
						arg2 = glyf_table:ReadI16BE()
					else
						arg1 = glyf_table:ReadI8()
						arg2 = glyf_table:ReadI8()
					end

					local m = {1, 0, 0, 1, 0, 0} -- transform matrix [a b c d e f]
					if bit.band(flags, ARGS_ARE_XY_VALUES) ~= 0 then
						m[5] = arg1
						m[6] = arg2
					else

					-- TODO: match points
					end

					if bit.band(flags, WE_HAVE_A_SCALE) ~= 0 then
						m[1] = glyf_table:ReadI16BE() / 16384
						m[4] = m[1]
					elseif bit.band(flags, WE_HAVE_AN_X_AND_Y_SCALE) ~= 0 then
						m[1] = glyf_table:ReadI16BE() / 16384
						m[4] = glyf_table:ReadI16BE() / 16384
					elseif bit.band(flags, WE_HAVE_A_TWO_BY_TWO) ~= 0 then
						m[1] = glyf_table:ReadI16BE() / 16384
						m[2] = glyf_table:ReadI16BE() / 16384
						m[3] = glyf_table:ReadI16BE() / 16384
						m[4] = glyf_table:ReadI16BE() / 16384
					end

					table.insert(glyph.components, {glyph_index = glyph_index, matrix = m})				
				until bit.band(flags, MORE_COMPONENTS) == 0
			end

			return glyph
		end
	end

	return font
end

if false then --test
	local file = assert(vfs.Open("/home/caps/Downloads/Roboto/static/Roboto-Regular.ttf"))
	local file_content = file:ReadAll()
	local input_buffer = Buffer.New(file_content, #file_content)
	table.print(ttf.DecodeBuffer(input_buffer))
end

return ttf
