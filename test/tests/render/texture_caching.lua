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

T.Test3D("Texture cache hit waits to call on_ready until async load completes", function()
	local pending = callback.Create()
	local download_calls = 0
	local on_ready_calls = 0
	local observed_ready_state = nil
	local observed_tex = nil

	with_stubbed_texture_loading(function(path)
		download_calls = download_calls + 1
		return pending
	end, function(path)
		return make_decoded_rgba(255, 0, 0, 255)
	end, function()
		local tex1 = Texture.New{path = "textures/cache_async_ready.png"}
		T(tex1:IsReady())["=="](false)
		local tex2 = Texture.New{
			path = "textures/cache_async_ready.png",
			on_ready = function(tex)
				on_ready_calls = on_ready_calls + 1
				observed_ready_state = tex:IsReady()
				observed_tex = tex
			end,
		}
		T(tex2 == tex1)["=="](true)
		T(download_calls)["=="](1)
		T(on_ready_calls)["=="](0)
		pending:Resolve("os:fake/cache_async_ready.png")
		T(tex1:IsReady())["=="](true)
		T(on_ready_calls)["=="](1)
		T(observed_ready_state)["=="](true)
		T(observed_tex == tex1)["=="](true)
	end)
end)

T.Test3D("Texture cache retries a failed path on the next request", function()
	local pending1 = callback.Create()
	local pending2 = callback.Create()
	local pending = {pending1, pending2}
	local download_calls = 0
	local decode_calls = 0

	with_stubbed_texture_loading(function(path)
		download_calls = download_calls + 1
		return table.remove(pending, 1)
	end, function(path)
		decode_calls = decode_calls + 1
		error("decode failed for test")
	end, function()
		local tex1 = Texture.New{path = "textures/cache_failure.png"}
		T(download_calls)["=="](1)
		pending1:Resolve("os:fake/cache_failure.png")
		T(tex1:IsReady())["=="](true)
		T(decode_calls)["=="](1)
		local tex2 = Texture.New{path = "textures/cache_failure.png"}
		T(tex2 == tex1)["=="](false)
		T(download_calls)["=="](2)
		pending2:Resolve("os:fake/cache_failure.png")
		T(tex2:IsReady())["=="](true)
		T(decode_calls)["=="](2)
	end)
end)

T.Test3D("Texture cache key distinguishes srgb variants on the same path", function()
	local pending1 = callback.Create()
	local pending2 = callback.Create()
	local pending = {pending1, pending2}
	local download_calls = 0
	local decode_calls = 0

	with_stubbed_texture_loading(function(path)
		download_calls = download_calls + 1
		return table.remove(pending, 1)
	end, function(path)
		decode_calls = decode_calls + 1
		return make_decoded_rgba(255, 255, 255, 255)
	end, function()
		local srgb_tex = Texture.New{path = "textures/cache_srgb.png", srgb = true}
		pending1:Resolve("os:fake/cache_srgb.png")
		T(srgb_tex:IsReady())["=="](true)
		T(srgb_tex.format)["=="]("r8g8b8a8_srgb")
		local linear_tex = Texture.New{path = "textures/cache_srgb.png", srgb = false}
		T(linear_tex == srgb_tex)["=="](false)
		T(linear_tex:IsReady())["=="](false)
		T(download_calls)["=="](2)
		T(decode_calls)["=="](1)
		pending2:Resolve("os:fake/cache_srgb.png")
		T(linear_tex:IsReady())["=="](true)
		T(decode_calls)["=="](2)
		T(linear_tex.format)["=="]("r8g8b8a8_unorm")
	end)
end)

T.Test3D("Texture decoding is rerun after texture cache clear", function()
	local pending1 = callback.Create()
	local pending2 = callback.Create()
	local pending = {pending1, pending2}
	local download_calls = 0
	local decode_calls = 0

	with_stubbed_texture_loading(function(path)
		download_calls = download_calls + 1
		return table.remove(pending, 1)
	end, function(path)
		decode_calls = decode_calls + 1
		return make_decoded_rgba(0, 255, 0, 255)
	end, function()
		local tex1 = Texture.New{path = "textures/cache_decode.png"}
		pending1:Resolve("os:fake/cache_decode.png")
		T(tex1:IsReady())["=="](true)
		T(download_calls)["=="](1)
		T(decode_calls)["=="](1)
		Texture.ClearCache()
		local tex2 = Texture.New{path = "textures/cache_decode.png"}
		pending2:Resolve("os:fake/cache_decode.png")
		T(tex2 == tex1)["=="](false)
		T(download_calls)["=="](2)
		T(decode_calls)["=="](2)
	end)
end)
