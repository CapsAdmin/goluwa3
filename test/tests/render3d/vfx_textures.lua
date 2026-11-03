local T = import("test/environment.lua")
local vfx = import("goluwa/render3d/vfx.lua")

T.Test3D("vfx textures and flipbooks come from data files and are edited in place", function()
	T(table.has_value(vfx.GetTextureNames(), "glow") and true or false)["=="](true)
	T(table.has_value(vfx.GetTextureNames(), "snowflake") and true or false)["=="](true)
	T(table.has_value(vfx.GetFlipbookNames(), "smoke") and true or false)["=="](true)
	T(table.has_value(vfx.GetFlipbookNames(), "fire") and true or false)["=="](true)
	T(table.has_value(vfx.GetTextureNames(), "smoke") and true or false)["=="](false)
	T(vfx.IsFlipbook("fire"))["=="](true)
	T(vfx.IsFlipbook("glow"))["=="](false)
	T(vfx.GetNewFileName("glow"))["=="]("glow_2")
	local glow = vfx.GetTexture("glow")
	T(glow:GetWidth())["=="](256)

	local function center()
		return glow:GetPixel(128, 128)
	end

	local original = center()
	T(original)[">"](100)
	local red = table.copy(vfx.Files.Source.glow)
	red.Source = "return vec4(1.0, 0.0, 0.0, 1.0);"
	vfx.UpdateFile("glow", red)
	T(vfx.GetTexture("glow") == glow)["=="](true)
	local r, g = center()
	T(r)["=="](255)
	T(g)["=="](0)
	local broken = table.copy(red)
	broken.Source = broken.Source .. "\nbroken_call(1);\n"
	local ok, err = pcall(vfx.UpdateFile, "glow", broken)
	T(ok)["=="](false)
	T(err:find("line 2", 1, true) ~= nil)["=="](true)
	T(vfx.GetFileStatus("glow"))["=="](err)
	T(vfx.Files.Source.glow.Source)["=="](red.Source)
	T((center()))["=="](255)
	local wrong_kind = {
		Columns = 2,
		Rows = 2,
		TileSize = 32,
		Source = "vec4 flipbook_frame(vec2 local, float phase, float frame) { return vec4(1.0); }",
	}
	ok, err = pcall(vfx.UpdateFile, "glow", wrong_kind)
	T(ok)["=="](false)
	T(err:find("already a texture", 1, true) ~= nil)["=="](true)
	vfx.ReloadFile("glow")
	T(vfx.GetFileStatus("glow"))["=="](nil)
	T((center()))["=="](original)
end)

T.Test("vfx texture data is checked when registered", function()
	local function broken(name, data)
		return select(2, pcall(vfx.RegisterFile, name, data))
	end

	T(
		broken("bad-name", {Source = "return vec4(1.0);"}):find("letters", 1, true) ~= nil
	)["=="](true)
	T(broken("bad_source", {}):find("Source", 1, true) ~= nil)["=="](true)
	T(
		broken("bad_size", {Size = 1.5, Source = "return vec4(1.0);"}):find("Size", 1, true) ~= nil
	)["=="](true)
	T(
		broken("bad_grid", {Columns = 0, Rows = 1, TileSize = 16, Source = "flipbook_frame"}):find("Columns", 1, true) ~= nil
	)["=="](true)
	T(
		broken(
				"bad_flipbook",
				{Columns = 1, Rows = 1, TileSize = 16, Source = "return vec4(1.0);"}
			):find("flipbook_frame", 1, true) ~= nil
	)["=="](true)
	T(table.has_value(vfx.GetFileNames(), "bad_flipbook") and true or false)["=="](false)
end)
