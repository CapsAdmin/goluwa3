local ffi = require("ffi")
local bit = require("bit")
local lzma = import("goluwa/codecs/lzma.lua")
local bsp = library()
bsp.file_extensions = {"bsp"}
bsp.magic_headers = {"VBSP"}
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local int32_ptr_t = ffi.typeof("const int32_t *")
local uint32_ptr_t = ffi.typeof("const uint32_t *")
local int16_ptr_t = ffi.typeof("const int16_t *")
local uint16_ptr_t = ffi.typeof("const uint16_t *")
local float_ptr_t = ffi.typeof("const float *")
local ffi_string = ffi.string
local LUMP_ENTITIES = 1
local LUMP_PAKFILE = 41
local LUMP_GAME = 36
local HEADER_SIZE = 8 + 64 * 16 + 4
local compile

do
	local ctypes = {
		byte = "uint8_t",
		short = "int16_t",
		["unsigned short"] = "uint16_t",
		int = "int32_t",
		long = "int32_t",
		["unsigned int"] = "uint32_t",
		float = "float",
		char = "char",
		vec3 = "float",
		ang3 = "float",
	}

	function compile(structure)
		structure = structure:gsub("//[^\n]*", ""):gsub("%s+", " ")
		local body = {}
		local lines = {}

		for field in structure:gmatch("(.-);") do
			field = field:gsub("^%s+", ""):gsub("%s+$", "")
			local type_name, key, count = field:match("^(.-)%s+([%w_]+)%s*%[?(%d*)%]?$")
			local padding = false

			if type_name:sub(1, 8) == "padding " then
				padding = true
				type_name = type_name:sub(9)
			end

			local ctype = assert(ctypes[type_name], "unknown bsp field type " .. type_name)
			local length = tonumber(count)

			if type_name == "vec3" or type_name == "ang3" then length = 3 end

			body[#body + 1] = ctype .. " " .. key .. (length and ("[" .. length .. "]") or "") .. ";"

			if not padding then
				if type_name == "char" then
					lines[#lines + 1] = key .. " = ffi_string(e." .. key .. ", " .. length .. "),"
				elseif length then
					local items = {}

					for i = 0, length - 1 do
						items[#items + 1] = "e." .. key .. "[" .. i .. "]"
					end

					lines[#lines + 1] = key .. " = {" .. table.concat(items, ", ") .. "},"
				else
					lines[#lines + 1] = key .. " = e." .. key .. ","
				end
			end
		end

		local struct_t = ffi.typeof("struct __attribute__((packed)) {" .. table.concat(body, " ") .. "}")
		local convert = assert(
			load(
				"local ffi_string = ...\nreturn function(e)\nreturn {\n" .. table.concat(lines, "\n") .. "\n}\nend"
			)
		)(ffi_string)
		return {
			ptr_t = ffi.typeof("const $ *", struct_t),
			size = ffi.sizeof(struct_t),
			convert = convert,
		}
	end
end

local specs = {
	brushes = compile[[
		int firstside;
		int numsides;
		int contents;
	]],
	brushsides = compile[[
		unsigned short planenum;
		short texinfo;
		short dispinfo;
		short bevel;
	]],
	planes = compile[[
		vec3 normal;
		float dist;
		int type;
	]],
	faces = compile[[
		unsigned short planenum;
		byte side;
		byte onNode;
		int firstedge;
		short numedges;
		short texinfo;
		short dispinfo;
		short render2dFogVolumeID;
		byte styles[4];
		int lightofs;
		float area;
		int LightmapTextureMinsInLuxels[2];
		int LightmapTextureSizeInLuxels[2];
		int origFace;
		unsigned short numPrims;
		unsigned short firstPrimID;
		unsigned int smoothingGroups;
	]],
	texinfos = compile[[
		float textureVecs[8];
		float lightmapVecs[8];
		int flags;
		int texdata;
	]],
	texdatas = compile[[
		vec3 reflectivity;
		int nameStringTableID;
		int width;
		int height;
		int view_width;
		int view_height;
	]],
	overlays = compile[[
		int id;
		short texinfo;
		unsigned short face_count_and_render_order;
		int faces[64];
		float u_range[2];
		float v_range[2];
		float uv_points[12];
		vec3 origin;
		vec3 normal;
	]],
	displacements = compile[[
		vec3 startPosition;
		int DispVertStart;
		int DispTriStart;
		int power;
		int minTess;
		float smoothingAngle;
		int contents;
		unsigned short MapFace;
		char asdf[2];
		int LightmapAlphaStart;
		int LightmapSamplePositionStart;
		padding byte padding[128];
	]],
	models = compile[[
		vec3 mins;
		vec3 maxs;
		vec3 origin;
		int headnode;
		int firstface;
		int numfaces;
	]],
	areas = compile[[
		int numareaportals;
		int firstareaportal;
	]],
	cubemaps = compile[[
		int origin[3];
		int size;
	]],
	static_prop = compile[[
		vec3 origin;
		ang3 angles;
		unsigned short prop_type;
		unsigned short first_leaf;
		unsigned short leaf_count;
		byte solid;
		byte flags;
		int skin;
		float fade_min_dist;
		float fade_max_dist;
		vec3 lighting_origin;
	]],
}

local function parse_numbers(str)
	local numbers = {}

	for token in str:gsub("%s+", " "):gmatch("[^ ]+") do
		numbers[#numbers + 1] = tonumber(token)
	end

	return numbers
end

local function parse_entities(text, stage)
	local entities = {}
	local count = 0

	for block in text:gmatch("{(.-)}") do
		local ent = {}

		for k, v in block:gmatch([["(.-)" "(.-)"]]) do
			if k == "angles" then
				local n = parse_numbers(v)
				v = {type = "ang3", n[1], n[2], n[3]}
			elseif k == "_light" or k == "_lightHDR" or k == "_ambient" or k == "_ambientHDR" then
				local n = parse_numbers(v)
				local r, g, b, brightness, r_hdr, g_hdr, b_hdr, brightness_hdr = n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8]

				if brightness_hdr then
					r, g, b, brightness = r_hdr, g_hdr, b_hdr, brightness_hdr
				end

				g = g or r
				b = b or r
				brightness = brightness or 255

				if not r or r < 0 or g < 0 or b < 0 or brightness < 0 then
					v = false
				else
					v = {
						r = (r / 255) ^ 2.2,
						g = (g / 255) ^ 2.2,
						b = (b / 255) ^ 2.2,
						brightness = brightness,
					}
				end
			elseif k:find("color", nil, true) then
				local n = parse_numbers(v)
				v = {type = "color", n[1], n[2], n[3], n[4]}
			elseif
				k == "origin" or
				k:find("dir", nil, true) or
				k:find("mins", nil, true) or
				k:find("maxs", nil, true)
			then
				local n = parse_numbers(v)
				v = {type = "vec3", n[1], n[2], n[3]}
			end

			ent[k] = tonumber(v) or v
		end

		ent.vdf = block
		ent.classname = ent.classname or "unknown"
		count = count + 1
		entities[count] = ent

		if stage and count % 500 == 0 then stage() end
	end

	return entities
end

function bsp.Decode(str, options, stage)
	options = options or {}
	local length = #str

	if length < HEADER_SIZE or str:sub(1, 4) ~= "VBSP" then
		return nil, "not a vbsp file"
	end

	local base = ffi.cast(uint8_ptr_t, str)

	local function at(offset, size)
		if offset < 0 or size < 0 or offset + size > length then
			error("bsp data is out of range", 3)
		end

		return base + offset
	end

	local header = {
		ident = ffi.cast(int32_ptr_t, base)[0],
		version = ffi.cast(int32_ptr_t, base)[1],
		lumps = {},
	}

	for i = 1, 64 do
		local lump = ffi.cast(int32_ptr_t, at(8 + (i - 1) * 16, 16))

		if header.version > 21 then
			header.lumps[i] = {version = lump[0], fileofs = lump[1], filelen = lump[2]}
		else
			header.lumps[i] = {fileofs = lump[0], filelen = lump[1], version = lump[2]}
		end

		header.lumps[i].fourCC = ffi_string(at(8 + (i - 1) * 16 + 12, 4), 4)
	end

	header.map_revision = ffi.cast(int32_ptr_t, at(8 + 64 * 16, 4))[0]
	local lump_cache = {}

	local function lump_data(index)
		local cached = lump_cache[index]

		if cached then return cached[1], cached[2] end

		local lump = header.lumps[index]
		local pointer, size = at(lump.fileofs, lump.filelen), lump.filelen
		local uncompressed_size = ffi.cast(uint32_ptr_t, ffi.cast("const char *", lump.fourCC))[0]

		if
			uncompressed_size ~= 0 and
			lump.filelen >= 17 and
			ffi_string(pointer, 4) == "LZMA"
		then
			local array, array_size = lzma.DecodeToArray(ffi_string(pointer, lump.filelen))
			lump_cache[index] = {array, array_size}
			return array, array_size
		end

		lump_cache[index] = {pointer, size}
		return pointer, size
	end

	local function read_lump(index, spec)
		local lump = header.lumps[index]

		if lump.filelen == 0 then return nil end

		local data, size = lump_data(index)
		local count = math.floor(size / spec.size)
		local elements = ffi.cast(spec.ptr_t, data)
		local out = {}
		local convert = spec.convert

		for i = 0, count - 1 do
			out[i + 1] = convert(elements[i])
		end

		if stage then stage() end

		return out
	end

	local function read_numbers(index, ptr_t, element_size, vector)
		local lump = header.lumps[index]

		if lump.filelen == 0 then return nil end

		local data, size = lump_data(index)
		local count = math.floor(size / element_size)
		local elements = ffi.cast(ptr_t, data)
		local out = {}

		if vector then
			for i = 0, count - 1 do
				out[i + 1] = {elements[i * 3], elements[i * 3 + 1], elements[i * 3 + 2]}
			end
		else
			for i = 0, count - 1 do
				out[i + 1] = elements[i]
			end
		end

		if stage then stage() end

		return out
	end

	header.pakfile_offset = header.lumps[LUMP_PAKFILE].fileofs
	header.pakfile_length = header.lumps[LUMP_PAKFILE].filelen
	local entities_lump = header.lumps[LUMP_ENTITIES]
	local entities_data, entities_size = lump_data(LUMP_ENTITIES)
	local text_length = 0

	while text_length < entities_size and entities_data[text_length] ~= 0 do
		text_length = text_length + 1
	end

	header.entities = parse_entities(ffi_string(entities_data, text_length), stage)

	do
		local lump = header.lumps[LUMP_GAME]
		local game_lumps = ffi.cast(int32_ptr_t, at(lump.fileofs, 4))[0]
		local position = lump.fileofs + 4

		for _ = 1, game_lumps do
			local entry = at(position, 16)
			local id = ffi_string(entry, 4)
			local version = ffi.cast(uint16_ptr_t, entry + 6)[0]
			local fileofs = ffi.cast(int32_ptr_t, entry + 8)[0]
			local filelen = ffi.cast(int32_ptr_t, entry + 12)[0]
			position = position + 16

			if id == "prps" then
				local cursor = fileofs
				local count = ffi.cast(int32_ptr_t, at(cursor, 4))[0]
				cursor = cursor + 4
				local paths = {}

				for i = 1, count do
					local name = at(cursor, 128)
					local stop = 0

					while stop < 128 and name[stop] ~= 0 do
						stop = stop + 1
					end

					local path = ffi_string(name, stop)

					if path ~= "" then paths[i] = path end

					cursor = cursor + 128
				end

				count = ffi.cast(int32_ptr_t, at(cursor, 4))[0]
				cursor = cursor + 4
				local leafs = {}
				local leaf_values = ffi.cast(uint16_ptr_t, at(cursor, count * 2))

				for i = 1, count do
					leafs[i] = leaf_values[i - 1]
				end

				cursor = cursor + count * 2
				header.static_prop_leafs = leafs
				count = ffi.cast(int32_ptr_t, at(cursor, 4))[0]
				cursor = cursor + 4
				local lump_size = ((filelen + fileofs) - cursor) / count
				local spec = specs.static_prop

				for _ = 1, count do
					local start = cursor
					local prop = spec.convert(ffi.cast(spec.ptr_t, at(cursor, spec.size))[0])
					cursor = cursor + spec.size

					if version >= 5 then
						prop.forced_fade_scale = ffi.cast(float_ptr_t, at(cursor, 4))[0]
						cursor = cursor + 4
					end

					if version == 6 or version == 7 then
						prop.min_dx_level = ffi.cast(uint16_ptr_t, at(cursor, 4))[0]
						prop.max_dx_level = ffi.cast(uint16_ptr_t, at(cursor, 4))[1]
						cursor = cursor + 4
					end

					if version >= 8 then
						local levels = at(cursor, 4)
						prop.min_cpu_level, prop.max_cpu_level, prop.min_gpu_level, prop.max_gpu_level = levels[0], levels[1], levels[2], levels[3]
						cursor = cursor + 4
					end

					if version >= 7 then
						local color = at(cursor, 4)
						prop.rendercolor = {type = "color", color[0], color[1], color[2], color[3]}
						cursor = cursor + 4
					end

					if version == 11 then
						cursor = cursor + 4
						prop.flags_ex = ffi.cast(uint32_ptr_t, at(cursor, 4))[0]
						cursor = cursor + 4
						prop.uniform_scale = ffi.cast(float_ptr_t, at(cursor, 4))[0]
						cursor = cursor + 4
					else
						cursor = cursor + (lump_size - (cursor - start))
					end

					prop.origin = {type = "vec3", prop.origin[1], prop.origin[2], prop.origin[3]}
					prop.angles = {type = "ang3", prop.angles[1], prop.angles[2], prop.angles[3]}
					prop.lighting_origin = {
						type = "vec3",
						prop.lighting_origin[1],
						prop.lighting_origin[2],
						prop.lighting_origin[3],
					}
					prop.model = paths[prop.prop_type + 1] or paths[1]
					prop.classname = "static_entity"
					header.entities[#header.entities + 1] = prop
				end
			end
		end

		if stage then stage() end
	end

	if options.cubemaps then header.cubemaps = read_lump(43, specs.cubemaps) end

	header.brushes = read_lump(19, specs.brushes)
	header.brushsides = read_lump(20, specs.brushsides)
	header.planes = read_lump(2, specs.planes)
	header.vertices = read_numbers(4, float_ptr_t, 12, true)
	header.surfedges = read_numbers(14, int32_ptr_t, 4)
	local edges_lump = header.lumps[13]

	if edges_lump.filelen > 0 then
		local data, size = lump_data(13)
		local count = math.floor(size / 4)
		local values = ffi.cast(uint16_ptr_t, data)
		header.edges = {}

		for i = 0, count - 1 do
			header.edges[i + 1] = {values[i * 2], values[i * 2 + 1]}
		end
	end

	header.faces = read_lump(8, specs.faces)
	header.texinfos = read_lump(7, specs.texinfos)
	header.texdatas = read_lump(3, specs.texdatas)
	local texdata_string_table = read_numbers(45, int32_ptr_t, 4)
	header.texdatastringdata = {}

	if texdata_string_table then
		local string_data, string_size = lump_data(44)

		for i, offset in ipairs(texdata_string_table) do
			local stop = offset

			while stop < string_size and string_data[stop] ~= 0 do
				stop = stop + 1
			end

			header.texdatastringdata[i] = ffi_string(string_data + offset, stop - offset)
		end
	end

	header.overlays = read_lump(46, specs.overlays)
	header.displacements = {}
	local displacement_lump = header.lumps[27]

	if displacement_lump.filelen > 0 then
		local data, size = lump_data(27)
		local count = math.floor(size / 176)
		local spec = specs.displacements
		local elements = ffi.cast(spec.ptr_t, data)
		local vertices, vertices_size = lump_data(34)
		local vertex_pointer = ffi.cast(float_ptr_t, vertices)

		for i = 0, count - 1 do
			local displacement = spec.convert(elements[i])
			local first = displacement.DispVertStart
			local heightmap = {}
			local vertex_count = ((2 ^ displacement.power) + 1) ^ 2

			if first < 0 or (first + vertex_count) * 20 > vertices_size then
				error("bsp displacement vertices are out of range")
			end

			for k = 0, vertex_count - 1 do
				local o = (first + k) * 5
				heightmap[k + 1] = {
					pos = {vertex_pointer[o], vertex_pointer[o + 1], vertex_pointer[o + 2]},
					dist = vertex_pointer[o + 3],
					alpha = vertex_pointer[o + 4],
				}
			end

			displacement.heightmap = heightmap
			header.displacements[i + 1] = displacement

			if stage and i % 50 == 0 then stage() end
		end
	end

	header.models = read_lump(15, specs.models)
	local nodes_lump = header.lumps[6]

	if nodes_lump.filelen > 0 then
		local data, size = lump_data(6)
		local count = math.floor(size / 32)
		local values = ffi.cast(int32_ptr_t, data)
		header.nodes = {}

		for i = 0, count - 1 do
			header.nodes[i + 1] = {values[i * 8], values[i * 8 + 1], values[i * 8 + 2]}
		end
	end

	local leaf_size = header.lumps[11].version == 0 and 56 or 32
	local leafs_lump = header.lumps[11]

	if leafs_lump.filelen > 0 then
		local data, size = lump_data(11)
		local count = math.floor(size / leaf_size)
		header.leafs = {}

		for i = 0, count - 1 do
			local leaf = data + i * leaf_size
			local shorts = ffi.cast(int16_ptr_t, leaf)
			local unsigned_shorts = ffi.cast(uint16_ptr_t, leaf)
			header.leafs[i + 1] = {
				contents = ffi.cast(int32_ptr_t, leaf)[0],
				area = bit.band(unsigned_shorts[3], 0x1FF),
				mins = {shorts[4], shorts[5], shorts[6]},
				maxs = {shorts[7], shorts[8], shorts[9]},
				first_leaf_face = unsigned_shorts[10],
				leaf_face_count = unsigned_shorts[11],
				first_leaf_brush = unsigned_shorts[12],
				leaf_brush_count = unsigned_shorts[13],
			}
		end
	end

	header.leaf_faces = read_numbers(17, uint16_ptr_t, 2) or {}
	header.leaf_brushes = read_numbers(18, uint16_ptr_t, 2) or {}
	header.areas = read_lump(21, specs.areas) or {}
	local portals_lump = header.lumps[22]
	header.areaportals = {}

	if portals_lump.filelen > 0 then
		local data, size = lump_data(22)
		local count = math.floor(size / 12)

		for i = 0, count - 1 do
			header.areaportals[i + 1] = ffi.cast(uint16_ptr_t, data + i * 12 + 2)[0]
		end
	end

	return header
end

return bsp
