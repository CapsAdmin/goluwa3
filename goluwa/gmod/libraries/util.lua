local codec = import("goluwa/codec.lua")
local crypto = import("goluwa/crypto.lua")
local steam = import("goluwa/steam.lua")
local vfs = import("goluwa/vfs.lua")
local util = gine.env.util

function util.FilterText(str, context, ply)
	return str
end

function util.KeyValuesToTable(str)
	local tbl, err = steam.VDFToTable(str, true)

	if not tbl then
		llog(err)
		return {}
	end

	local key, val = next(tbl)
	return val
end

function util.CRC(str)
	return crypto.CRC32(tostring(str))
end

if MENU then
	function util.RelativePathToFull_Menu(path)
		if path == "." then path = "" end

		return R(path) or ""
	end
end

function util.JSONToTable(str)
	local ok, res = pcall(codec.Decode, "json", str)

	if ok then return res end

	wlog(res)
end

function util.TableToJSON(tbl)
	return codec.Encode("json", tbl)
end

function util.SteamIDTo64(str)
	return steam.SteamIDToCommunityID(str)
end

function util.IsValidModel(path)
	return vfs.IsFile(path)
end

function util.IsValidRagdoll(ent)
	return false
end

function util.PointContents()
	return 0
end

function util.GetPixelVisibleHandle()
	return {}
end

function gine.env.LocalToWorld()
	return gine.env.Vector(), gine.env.Angle()
end

function gine.env.WorldToLocal()
	return gine.env.Vector(), gine.env.Angle()
end

function util.GetSunInfo()
	return {
		direction = gine.env.Vector(0, 0, 1),
		obstruction = 0,
	}
end

function util.GetPixelVisibleHandle()
	return {}
end

function util.PixelVisible(pos, radius, handle)
	return 1
end
