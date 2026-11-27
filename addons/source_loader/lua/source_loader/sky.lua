local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local vdf = import("goluwa/codecs/vdf.lua")
local timer = import("goluwa/timer.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local sky = {}
-- the face suffixes in the order of the faces get_face picks
local FACES = {"rt", "lf", "bk", "ft", "up", "dn"}
local MODE_SRGB, MODE_COMPRESSED_HDR, MODE_LINEAR = 0, 1, 2
local SAMPLER = {
	min_filter = "linear",
	mag_filter = "linear",
	mipmap_mode = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}
-- the sky of the loaded map: {path = cubemap texture path} for source 2, {skyname = name} for source 1
sky.current = nil

function sky.Find()
	local names = {}

	for _, file in ipairs(vfs.Find("materials/skybox/")) do
		local name = file:lower():match("^(.-)rt%.vmt$")

		if name and not name:ends_with("_hdr") then names[#names + 1] = name end
	end

	table.sort(names)
	return names
end

local function read_face(base, face)
	local path = "materials/skybox/" .. base .. face .. ".vmt"

	if not vfs.IsFile(path) then return nil end

	local _, vmt = next(vdf.Decode(vfs.Read(path), "vmt"))

	-- some skies are a flat $color instead of a texture
	if not (vmt.hdrcompressedtexture or vmt.hdrbasetexture or vmt.basetexture) then
		local r, g, b = vmt.color:match("(%d+)%s+(%d+)%s+(%d+)")
		return {
			texture = Texture.FromColor(Color(tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255, 1)),
			compressed = false,
			scale = {1, 1},
		}
	end

	local key = vmt.hdrcompressedtexture and
		"hdrcompressedtexture" or
		vmt.hdrbasetexture and
		"hdrbasetexture" or
		"basetexture"
	local scale_x, scale_y = 1, 1

	if vmt.basetexturetransform then
		scale_x, scale_y = vmt.basetexturetransform:match("scale ([%d%.]+) ([%d%.]+)")
	end

	return {
		texture = Texture.New{
			path = "materials/" .. vmt[key]:gsub("\\", "/"):gsub("%.vtf$", "") .. ".vtf",
			sampler = SAMPLER,
		},
		compressed = key == "hdrcompressedtexture",
		scale = {tonumber(scale_x), tonumber(scale_y)},
	}
end

local Constants = ffi.typeof([[struct {
	int index[6];
	int mode[6];
	float scale[12];
}]])
-- rt faces +x, lf -x, bk +y, ft -y, up +z and dn -z; going right around the horizon is bk rt ft lf, up's right edge meets ft and its bottom edge rt
local DECLARATIONS = [[
	layout(push_constant) uniform SkyFaces {
		int index[6];
		int mode[6];
		vec2 scale[6];
	} sky_faces;
]]
local ASSEMBLE_GLSL = [[
	vec4 shade(vec2 uv, vec3 c) {
		vec3 a = abs(c);
		int face;
		vec2 st;

		if (a.x >= a.y && a.x >= a.z) {
			face = c.x > 0.0 ? 0 : 1;
			st = c.x > 0.0 ? vec2(-c.y, c.z) / c.x : vec2(c.y, c.z) / -c.x;
		} else if (a.y >= a.z) {
			face = c.y > 0.0 ? 2 : 3;
			st = c.y > 0.0 ? vec2(c.x, c.z) / c.y : vec2(-c.x, c.z) / -c.y;
		} else {
			face = c.z > 0.0 ? 4 : 5;
			st = c.z > 0.0 ? vec2(-c.y, -c.x) / c.z : vec2(-c.y, c.x) / -c.z;
		}

		if (sky_faces.index[face] < 0) return vec4(0.0, 0.0, 0.0, 1.0);

		vec2 face_uv = vec2(st.x + 1.0, 1.0 - st.y) * 0.5 * sky_faces.scale[face];
		vec4 texel = textureLod(TEXTURE(sky_faces.index[face]), face_uv, 0.0);
		int mode = sky_faces.mode[face];
		vec3 color = mode == 0 ? pow(texel.rgb, vec3(2.2)) : mode == 1 ? texel.rgb * texel.a * 16.0 : texel.rgb;
		return vec4(color, 1.0);
	}
]]

local function get_mode(face)
	if face.texture.format:find("float") then return MODE_LINEAR end

	return face.compressed and MODE_COMPRESSED_HDR or MODE_SRGB
end

-- assembles a source 1 skybox's six face materials into a cube texture with z up like source 2's, then calls
-- on_ready(cube); the _hdr variant is used when there is one
function sky.Load(name, on_ready)
	local base = vfs.IsFile("materials/skybox/" .. name .. "_hdrrt.vmt") and
		name .. "_hdr" or
		name
	local faces = {}
	local textures = {}

	for i, suffix in ipairs(FACES) do
		faces[i] = read_face(base, suffix)

		if faces[i] then textures[#textures + 1] = faces[i].texture end
	end

	local function assemble()
		for _, texture in ipairs(textures) do
			if not texture:IsReady() then return timer.Delay(0.05, assemble) end
		end

		local size = 4
		local loaded = {}

		-- a face whose texture failed to load (the loader warns) is left black like a missing one
		for i = 1, 6 do
			if faces[i] and not faces[i].texture.format then faces[i] = nil end

			if faces[i] then
				size = math.max(size, faces[i].texture:GetWidth())
				loaded[#loaded + 1] = faces[i].texture
			end
		end

		local cube = Texture.New{
			width = size,
			height = size,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = "auto",
			image = {
				array_layers = 6,
				flags = {"cube_compatible"},
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			view = {view_type = "cube", layer_count = 6},
			sampler = SAMPLER,
		}
		cube:Shade(
			ASSEMBLE_GLSL,
			{
				textures = loaded,
				custom_declarations = DECLARATIONS,
				fragment_push_constants = {
					size = ffi.sizeof(Constants),
					get_data = function(_, _, pipeline)
						local constants = Constants()

						for i = 1, 6 do
							local face = faces[i]
							constants.index[i - 1] = face and pipeline:GetTextureIndex(face.texture) or -1
							constants.mode[i - 1] = face and get_mode(face) or 0
							constants.scale[(i - 1) * 2] = face and face.scale[1] or 1
							constants.scale[(i - 1) * 2 + 1] = face and face.scale[2] or 1
						end

						return constants
					end,
				},
			}
		)
		on_ready(cube)
	end

	assemble()
end

-- calls on_ready(cube) with the loaded map's sky
function sky.LoadCurrent(on_ready)
	local current = assert(sky.current, "the loaded map has no sky")

	if current.skyname then return sky.Load(current.skyname, on_ready) end

	local cube = Texture.New{path = current.path, sampler = SAMPLER}

	local function wait()
		if not cube:IsReady() then return timer.Delay(0.05, wait) end

		on_ready(cube)
	end

	wait()
end

return sky
