local Texture = import("goluwa/render/texture.lua")
local water = import("goluwa/render3d/water.lua")
local ocean_fft = {}
local N = water.FFT_SIZE
-- the tiles are sampled at the texel of the world position they hold, which is half a texel off the uv
local HALF_TEXEL = 0.5 / N
ocean_fft.textures = {}

local function create_texture(format, name, data)
	local texture = Texture.New{
		width = N,
		height = N,
		format = format,
		buffer = data,
		image = {usage = {"storage", "sampled", "transfer_src", "transfer_dst"}},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
	texture:SetDebugName("ocean fft " .. name)
	return texture
end

-- the textures the transform works in and what it makes, and the spectrum when it has changed: h0 holds
-- the amplitudes of k and of -k, omega the number of the angular frequency in the wave period
function ocean_fft.Update()
	local t = ocean_fft.textures
	local waves = water.GetOceanWaves()

	for i = 1, #water.FFT_CASCADES do
		local cascade = t[i]

		if not cascade then
			cascade = {}
			t[i] = cascade
			cascade.temp0 = create_texture("r32g32b32a32_sfloat", "temp0 " .. i)
			cascade.temp1 = create_texture("r32g32b32a32_sfloat", "temp1 " .. i)
			-- displacement x, height, displacement z, d(displacement x)/dz
			cascade.displacement = create_texture("r16g16b16a16_sfloat", "displacement " .. i)
			-- slope x, slope z, d(displacement x)/dx, d(displacement z)/dz
			cascade.derivatives = create_texture("r16g16b16a16_sfloat", "derivatives " .. i)
		end

		if cascade.version ~= water.spectrum_version then
			if cascade.h0 then
				cascade.h0:Remove()
				cascade.omega:Remove()
			end

			cascade.h0 = create_texture("r32g32b32a32_sfloat", "h0 " .. i, waves.cascades[i].h0)
			cascade.omega = create_texture("r32_sfloat", "omega " .. i, waves.cascades[i].omega_index)
			cascade.version = water.spectrum_version
		end
	end

	return t
end

-- the lookup of the tiles of the first count cascades by the world position of what is
-- undisplaced. the block holds the displacement and derivative texture of each in fft_tex
function ocean_fft.GetGLSL(block, count)
	local lines = {}
	local function add(...)
		lines[#lines + 1] = string.format(...)
	end

	local function uv(i)
		return string.format("p / %.6f + %.8f", water.FFT_CASCADES[i].size, HALF_TEXEL)
	end

	add("vec2 fft_displacement(vec2 p) {")
	add("\tvec2 d = vec2(0.0);")

	for i = 1, count do
		add("\td += textureLod(TEXTURE(%s.fft_tex[%d]), %s, 0.0).xz;", block, (i - 1) * 2, uv(i))
	end

	add("\treturn d;")
	add("}")
	add("")
	add("// the point the waves carry to world_xz")
	add("vec2 fft_undisplace(vec2 world_xz, float choppiness) {")
	add("\tvec2 p = world_xz;")
	add("\tfor (int i = 0; i < 4; i++) p = world_xz - choppiness * fft_displacement(p);")
	add("\treturn p;")
	add("}")
	add("")
	add("// height, normal and the jacobian of the horizontal displacement, which drops towards 0 and below")
	add("// where a crest folds over and breaks")
	add("void fft_surface(vec2 p, float choppiness, out float height, out vec3 normal, out float jacobian) {")
	add("\theight = 0.0;")
	add("\tvec2 slope = vec2(0.0);")
	add("\tvec3 folds = vec3(0.0);")

	for i = 1, count do
		add("\t{")
		add("\t\tvec4 a = textureLod(TEXTURE(%s.fft_tex[%d]), %s, 0.0);", block, (i - 1) * 2, uv(i))
		add("\t\tvec4 b = textureLod(TEXTURE(%s.fft_tex[%d]), %s, 0.0);", block, (i - 1) * 2 + 1, uv(i))
		add("\t\theight += a.y;")
		add("\t\tslope += b.xy;")
		add("\t\tfolds += vec3(b.zw, a.w);")
		add("\t}")
	end

	add("\tfolds *= choppiness;")
	add("\tvec3 tangent_x = vec3(1.0 + folds.x, slope.x, folds.z);")
	add("\tvec3 tangent_z = vec3(folds.z, slope.y, 1.0 + folds.y);")
	add("\tnormal = normalize(cross(tangent_z, tangent_x));")
	add("\tjacobian = (1.0 + folds.x) * (1.0 + folds.y) - folds.z * folds.z;")
	add("}")
	return table.concat(lines, "\n")
end

return ocean_fft
