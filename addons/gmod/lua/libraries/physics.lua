function gine.env.util.TraceLine(info)
	local data = {}
	data.Entity = NULL
	data.Fraction = 0
	data.FractionLeftSolid = 0
	data.Hit = false
	data.HitBox = 0
	data.HitGroup = 0
	data.HitNoDraw = false
	data.HitNonWorld = false
	data.HitNormal = gine.env.Vector(0, 0, 0)
	data.HitPos = gine.env.Vector(0, 0, 0)
	data.HitSky = false
	data.HitTexture = "error"
	data.HitWorld = false
	data.MatType = 0
	data.Normal = gine.env.Vector(0, 0, 0)
	data.PhysicsBone = 0
	data.StartPos = gine.env.Vector(0, 0, 0)
	data.SurfaceProps = 0
	data.StartSolid = false
	return data
end

gine.env.util.TraceHull = gine.env.util.TraceLine

do
	do
		local density = 2

		function gine.env.physenv.SetAirDensity(num)
			density = num
		end

		function gine.env.physenv.GetAirDensity(num)
			return density
		end
	end

	do
		local gravity

		function gine.env.physenv.SetGravity(vec)
			gravity = vec
		end

		function gine.env.physenv.GetGravity()
			return (gravity and gravity * 1) or gine.env.Vector(0, 0, -600)
		end
	end

	do
		local settings = {
			MaxCollisionChecksPerTimestep = 50000,
			MaxCollisionsPerObjectPerTimestep = 10,
			LookAheadTimeObjectsVsObject = 0.5,
			MaxVelocity = 4000,
			MinFrictionMass = 10,
			MaxFrictionMass = 2500,
			LookAheadTimeObjectsVsWorld = 1,
			MaxAngularVelocity = 7272.7275390625,
		}

		function gine.env.physenv.SetPerformanceSettings(tbl)
			table.merge(settings, tbl)
		end

		function gine.env.physenv.GetPerformanceSettings()
			return table.copy(settings)
		end
	end
end

do
	local META = gine.EnsureMetaTable("Entity")

	function META:SetSolid(b) end

	function META:PhysicsInit() end

	function META:GetPhysicsObject()
		return NULL
	end
end
