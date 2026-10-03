local math3d = library()

function math3d.BilerpVec3(a, b, c, d, alpha1, alpha2)
	return a:GetLerped(alpha1, b):Lerp(alpha2, c:GetLerped(alpha1, d))
end

function math3d.WorldToLocal(local_pos, local_ang, world_pos, world_ang)
	local pos, ang

	if world_ang and local_ang then
		local lmat = Matrix44():SetRotation(Quat():SetAngles(local_ang))
		local wmat = Matrix44():SetRotation(Quat():SetAngles(world_ang))
		ang = (wmat * lmat):GetRotation():GetAngles()
	end

	if world_pos and local_pos then
		local lmat = Matrix44():SetTranslation(local_pos:Unpack())
		local wmat = Matrix44():SetTranslation(world_pos:Unpack())
		pos = Vec3((wmat * lmat):GetTranslation())
	end

	return pos, ang
end

function math3d.LocalToWorld(local_pos, local_ang, world_pos, world_ang)
	local pos, ang

	if world_ang and local_ang then
		local lmat = Matrix44():SetRotation(Quat():SetAngles(local_ang)):GetInverse()
		local wmat = Matrix44():SetRotation(Quat():SetAngles(world_ang))
		ang = (wmat * lmat):GetRotation():GetAngles()
	end

	if world_pos and local_pos then
		local lmat = Matrix44():SetTranslation(local_pos:Unpack()):GetInverse()
		local wmat = Matrix44():SetTranslation(world_pos:Unpack())
		pos = Vec3((wmat * lmat):GetTranslation())
	end

	return pos, ang
end

function math3d.LinePlaneIntersection(pos, normal, screen_pos)
	local ln = math3d.ScreenToWorldDirection(screen_pos)
	local lp = cam:GetPosition() - pos
	local t = lp:GetDot(normal) / ln:GetDot(normal)

	if t < 0 then return lp + ln * -t end
end

function math3d.PointToAxis(pos, axis, screen_pos)
	local origin = math3d.WorldPositionToScreen(pos)
	local point = math3d.WorldPositionToScreen(pos + (axis * 8))
	local a = math.atan2(point.y - origin.y, point.x - origin.x)
	local d = math.cos(a) * (point.x - screen_pos.x) + math.sin(a) * (point.y - screen_pos.y)
	return Vec2(point.x + math.cos(a) * -d, point.y + math.sin(a) * -d)
end

function math3d.ScreenToWorldDirection(screen_pos, cam_pos, cam_ang, cam_fov, screen_width, screen_height)
	cam_pos = cam_pos or cam:GetPosition()
	cam_ang = cam_ang or cam:GetAngles()
	cam_fov = cam_fov or cam:GetFOV()
	screen_width = screen_width or render.GetWidth()
	screen_height = screen_height or render.GetHeight()
	local d = 4 * screen_height / (8 * math.tan(0.5 * cam_fov))
	local fwd = cam_ang:GetForward()
	local rgt = -cam_ang:GetRight()
	local upw = cam_ang:GetUp()
	local dir = (
			fwd * d
		) + (
			rgt * (
				0.5 * screen_width - screen_pos.x
			)
		) + (
			upw * (
				0.5 * screen_height - screen_pos.y
			)
		)
	dir:Normalize()
	return dir
end

function math3d.WorldPositionToScreen(position, cam_pos, cam_ang, screen_width, screen_height, cam_fov)
	cam_pos = cam_pos or cam:GetPosition()
	cam_ang = cam_ang or cam:GetAngles()
	screen_width = screen_width or render.GetWidth()
	screen_height = screen_height or render.GetHeight()
	cam_fov = cam_fov or cam:GetFOV()
	local dir = cam_pos - position
	dir:Normalize()
	local d = 4 * screen_height / (8 * math.tan(0.5 * cam_fov))
	local fdp = cam_ang:GetForward():GetDot(dir)

	if fdp == 0 then return Vec2(0, 0), -1 end

	local proj = dir * (d / fdp)
	local x = 0.5 * screen_width + cam_ang:GetRight():GetDot(proj)
	local y = 0.5 * screen_height - cam_ang:GetUp():GetDot(proj)
	local vis

	if fdp < 0 then
		vis = 1
	elseif x < 0 or x > screen_width or y < 0 or y > screen_height then
		vis = 0
	else
		vis = -1
	end

	return Vec2(x, y), vis
end

do
	local EPSILON = 1E-12

	function math3d.SimpleLineIntersectAABB(from, to, min, max)
		local d = (to - from) * 0.5
		local e = (max - min) * 0.5
		local c = from + d - (min + max) * 0.5
		local ad = Vec3(math.abs(d.x), math.abs(d.y), math.abs(d.z))

		if math.abs(c.x) > e.x + ad.x then return false end

		if math.abs(c.y) > e.y + ad.y then return false end

		if math.abs(c.z) > e.z + ad.z then return false end

		if math.abs(d.y * c.z - d.z * c.y) > e.y * ad.z + e.z * ad.y + EPSILON then
			return false
		end

		if math.abs(d.z * c.x - d.x * c.z) > e.z * ad.x + e.x * ad.z + EPSILON then
			return false
		end

		if math.abs(d.x * c.y - d.y * c.x) > e.x * ad.y + e.y * ad.x + EPSILON then
			return false
		end

		return true
	end
end

return math3d
