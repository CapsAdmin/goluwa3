local lua_type = _G.type

local function make_is(name)
	if name:sub(1, 1) == name:sub(1, 1):upper() then
		gine.env["is" .. name:lower()] = function(var)
			return name and lua_type(var) == "table" and var.MetaName == name
		end
	else
		gine.env["is" .. name:lower()] = function(var)
			return lua_type(var) == name
		end
	end
end

make_is("string")
make_is("number")
make_is("table")
make_is("Entity")
make_is("Angle")
make_is("Vector")
make_is("function")
make_is("Panel")
make_is("Matrix")

function gine.env.isbool(obj)
	return lua_type(obj) == "boolean"
end

gine.env.IsEntity = gine.env.isentity

function gine.env.type(obj)
	local t = lua_type(obj)

	if t == "table" then
		local meta = getmetatable(obj)

		if meta and meta.MetaName then return meta.MetaName end
	end

	return t
end

do
	local tr = {
		Angle = gine.env.TYPE_ANGLE,
		boolean = gine.env.TYPE_BOOL,
		Color = gine.env.TYPE_COLOR,
		ConVar = gine.env.TYPE_CONVAR,
		CTakeDamageInfo = gine.env.TYPE_DAMAGEINFO,
		DynamicLight = gine.env.TYPE_DLIGHT,
		CEffectData = gine.env.TYPE_EFFECTDATA,
		Entity = gine.env.TYPE_ENTITY,
		Player = gine.env.TYPE_ENTITY,
		File = gine.env.TYPE_FILE,
		["function"] = gine.env.TYPE_FUNCTION,
		IMesh = gine.env.TYPE_IMESH,
		lightuserdata = gine.env.TYPE_LIGHTUSERDATA,
		CLuaLocomotion = gine.env.TYPE_LOCOMOTION,
		IMaterial = gine.env.TYPE_MATERIAL,
		VMatrix = gine.env.TYPE_MATRIX,
		CMoveData = gine.env.TYPE_MOVEDATA,
		CNavArea = gine.env.TYPE_NAVAREA,
		CNavLadder = gine.env.TYPE_NAVLADDER,
		["nil"] = gine.env.TYPE_NIL,
		number = gine.env.TYPE_NUMBER,
		Panel = gine.env.TYPE_PANEL,
		CLuaParticle = gine.env.TYPE_PARTICLE,
		CLuaEmitter = gine.env.TYPE_PARTICLEEMITTER,
		CNewParticleEffect = gine.env.TYPE_PARTICLESYSTEM,
		PathFollower = gine.env.TYPE_PATH,
		PhysObj = gine.env.TYPE_PHYSOBJ,
		pixelvis_handle_t = gine.env.TYPE_PIXELVISHANDLE,
		CRecipientFilter = gine.env.TYPE_RECIPIENTFILTER,
		IRestore = gine.env.TYPE_RESTORE,
		ISave = gine.env.TYPE_SAVE,
		Vehicle = gine.env.TYPE_SCRIPTEDVEHICLE,
		CSoundPatch = gine.env.TYPE_SOUND,
		IGModAudioChannel = gine.env.TYPE_SOUNDHANDLE,
		string = gine.env.TYPE_STRING,
		table = gine.env.TYPE_TABLE,
		ITexture = gine.env.TYPE_TEXTURE,
		thread = gine.env.TYPE_THREAD,
		CUserCmd = gine.env.TYPE_USERCMD,
		userdata = gine.env.TYPE_USERDATA,
		bf_read = gine.env.TYPE_USERMSG,
		Vector = gine.env.TYPE_VECTOR,
		IVideoWriter = gine.env.TYPE_VIDEO,
	}

	function gine.env.TypeID(val)
		return tr[gine.env.type(val)] or gine.env.TYPE_INVALID
	end
end

function gine.env.istable(obj)
	return gine.env.type(obj) == "table"
end

function gine.env.FindMetaTable(name)
	return gine.EnsureMetaTable(name)
end
