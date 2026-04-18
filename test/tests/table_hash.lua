local ffi = require("ffi")
local T = import("test/environment.lua")
local Texture = import("goluwa/render/texture.lua")
local resource = import("goluwa/resource.lua")
local codec = import("goluwa/codec.lua")
local callback = import("goluwa/callback.lua")
local Buffer = import("goluwa/structs/buffer.lua")

local function make_decoded_rgba(r, g, b, a)
	r = r or 255
	g = g or 0
	b = b or 0
	a = a or 255
	local pixels = ffi.new("uint8_t[4]", {r, g, b, a})
	return {
		width = 1,
		height = 1,
		buffer = Buffer.New(pixels, 4),
	}
end

local function with_stubbed_texture_loading(download_fn, decode_fn, fn)
	local old_download = resource.Download
	local old_decode = codec.DecodeFile
	Texture.ClearCache()
	resource.Download = download_fn
	codec.DecodeFile = decode_fn
	local ok, err = xpcall(fn, debug.traceback)
	resource.Download = old_download
	codec.DecodeFile = old_decode
	Texture.ClearCache()

	if not ok then error(err, 0) end
end

T.Test("table.hash is stable for the same table identity", function()
	local tbl = {hello = "world"}
	local h1 = table.hash(tbl)
	local h2 = table.hash(tbl)
	T(h1)["=="](h2)
end)

T.Test("table.hash differs for distinct tables with equal contents", function()
	local a = {value = 1}
	local b = {value = 1}
	T(table.hash(a) == table.hash(b))["=="](false)
end)

T.Test3D("Texture cache key reuses identical inline sampler configs", function()
	local pending = callback.Create()
	local download_calls = 0

	with_stubbed_texture_loading(function(path)
		download_calls = download_calls + 1
		return pending
	end, function(path)
		return make_decoded_rgba(255, 255, 255, 255)
	end, function()
		local tex1 = Texture.New{
			path = "textures/table_hash_cache.png",
			sampler = {
				min_filter = "nearest",
				mag_filter = "linear",
			},
		}
		local tex2 = Texture.New{
			path = "textures/table_hash_cache.png",
			sampler = {
				min_filter = "nearest",
				mag_filter = "linear",
			},
		}
		T(tex2 == tex1)["=="](true)
		T(download_calls)["=="](1)
		pending:Resolve("os:fake/table_hash_cache.png")
		T(tex1:IsReady())["=="](true)
		T(tex2:IsReady())["=="](true)
	end)
end)

T.Test3D("Texture sampler config hash is stable across repeated queries", function()
	local tex = Texture.New{
		width = 1,
		height = 1,
		sampler = {
			min_filter = "nearest",
			mag_filter = "linear",
		},
	}
	local h1 = tex:GetSamplerConfigHash()
	local h2 = tex:GetSamplerConfigHash()
	T(h1)["=="](h2)
end)
