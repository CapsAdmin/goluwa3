local gfx = import("goluwa/render2d/gfx.lua")

do
	function gine.env.ParticleEmitter()
		local emitter = {}
		return gine.WrapObject(emitter, "CLuaEmitter")
	end

	local META = gine.EnsureMetaTable("CLuaEmitter")
	gine.GetSet(META, "NoDraw", false)

	function META:Add()
		return gine.WrapObject({}, "CLuaParticle")
	end
end

do
	local META = gine.EnsureMetaTable("CLuaParticle")
end
