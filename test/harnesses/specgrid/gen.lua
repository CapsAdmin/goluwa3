-- writes flat-colour RGBA8888 VTFs + VMTs for a shininess comparison grid, loaded identically by gmod and goluwa
local root = "/run/media/caps/extra/SteamLibrary/steamapps/common/GarrysMod/garrysmod/materials/specgrid/"
os.execute("mkdir -p '" .. root .. "'")

local function write_vtf(name, r, g, b, a)
	local w, h = 4, 4
	local hdr = {}
	local function u8(v) hdr[#hdr + 1] = string.char(v) end
	local function u16(v) u8(v % 256) u8(math.floor(v / 256)) end
	local function u32(v) u16(v % 65536) u16(math.floor(v / 65536)) end
	local ffi = require("ffi")
	local fbuf = ffi.new("float[1]")
	local function f32(v) fbuf[0] = v hdr[#hdr + 1] = ffi.string(fbuf, 4) end
	hdr[#hdr + 1] = "VTF\0"
	u32(7) u32(2) u32(80)
	u16(w) u16(h)
	u32(0x100 + 0x200 + 0x2000) -- NOMIP, NOLOD, EIGHTBITALPHA
	u16(1) u16(0)
	u32(0)
	f32(0.2) f32(0.2) f32(0.2)
	u32(0)
	f32(1)
	u32(0) -- RGBA8888
	u8(1)
	u32(0xFFFFFFFF)
	u8(0) u8(0)
	u16(1)
	local s = table.concat(hdr)
	s = s .. string.rep("\0", 80 - #s)
	s = s .. string.rep(string.char(r, g, b, a), w * h)
	local f = assert(io.open(root .. name .. ".vtf", "wb"))
	f:write(s)
	f:close()
end

local alphas = {0, 64, 128, 192, 255}
local base_grey = 128
local rows = {
	{"envbase", function(a) return [["$basetexture" "specgrid/base_a%d"
		"$envmap" "env_cubemap"
		"$basealphaenvmapmask" 1]], {a} end},
	{"envnormal", function(a) return [["$basetexture" "specgrid/base_a255"
		"$bumpmap" "specgrid/bump_a%d"
		"$envmap" "env_cubemap"
		"$normalmapalphaenvmapmask" 1]], {a} end},
	{"envtint", function(a) return [["$basetexture" "specgrid/base_a255"
		"$envmap" "env_cubemap"
		"$envmaptint" "[%f %f %f]"]], {a / 255, a / 255, a / 255} end},
	{"phongnormal", function(a) return [["$basetexture" "specgrid/base_a255"
		"$bumpmap" "specgrid/bump_a%d"
		"$phong" 1
		"$phongexponent" 30
		"$phongboost" 4
		"$phongfresnelranges" "[1 1 1]"]], {a} end},
	{"phongbase", function(a) return [["$basetexture" "specgrid/base_a%d"
		"$phong" 1
		"$phongexponent" 30
		"$phongboost" 4
		"$phongfresnelranges" "[1 1 1]"
		"$basemapalphaphongmask" 1]], {a} end},
	{"phongexp", function(a, ci) return [["$basetexture" "specgrid/base_a255"
		"$phong" 1
		"$phongexponent" %d
		"$phongboost" 1
		"$phongfresnelranges" "[1 1 1]"]], {({5, 10, 30, 100, 300})[ci]} end},
}

for _, a in ipairs(alphas) do
	write_vtf("base_a" .. a, base_grey, base_grey, base_grey, a)
	write_vtf("bump_a" .. a, 128, 128, 255, a)
end

for ri, row in ipairs(rows) do
	for ci, a in ipairs(alphas) do
		local fmt, args = row[2](a, ci)
		local f = assert(io.open(root .. row[1] .. "_" .. ci .. ".vmt", "wb"))
		f:write('"VertexLitGeneric"\n{\n\t' .. string.format(fmt, table.unpack(args)) .. "\n}\n")
		f:close()
	end
end
print("wrote", root)
os.exit(0)
