local Polygon3D = import("goluwa/render3d/polygon_3d.lua")

function gine.env.Mesh()
	return gine.WrapObject(Polygon3D.New(), "IMesh")
end

local META = gine.EnsureMetaTable("IMesh")

function META:BuildFromTriangles(tbl) end

function META:Destroy()
	self.__obj:Remove()
end

function META:Draw() end
