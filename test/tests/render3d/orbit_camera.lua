local T = import("test/environment.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function ndc(camera, point)
	local pv = camera:BuildViewMatrix():GetMultiplied(camera:BuildProjectionMatrix())
	local clip = pv:MultiplyVector(point.x, point.y, point.z, 1)
	return clip.m00 / clip.m03, clip.m01 / clip.m03
end

local function create(radius, aspect)
	local camera = Camera3D.New()
	local orbit = OrbitCamera.New(camera)
	orbit:Fit(Vec3(2, 1, -3), radius or 1, aspect or 1)
	orbit:Apply()
	return orbit, camera
end

T.Test("Orbit camera fit looks at the center with the sphere inside the view", function()
	local orbit, camera = create(2, 1)
	local x, y = ndc(camera, Vec3(2, 1, -3))
	T(math.abs(x) < 1e-4)["=="](true)
	T(math.abs(y) < 1e-4)["=="](true)
	-- a point on the sphere's side, perpendicular to the view, stays inside the view
	local right = camera:GetRotation():GetRight()
	local edge_x = ndc(camera, Vec3(2, 1, -3) + right * 2)
	T(edge_x > 0.5 and edge_x < 1)["=="](true)
end)

T.Test("Orbit camera fit is limited by the width of a narrow view", function()
	local _, wide = create(1, 2)
	local _, narrow = create(1, 0.5)
	local wide_distance = (wide:GetPosition() - Vec3(2, 1, -3)):GetLength()
	local narrow_distance = (narrow:GetPosition() - Vec3(2, 1, -3)):GetLength()
	T(narrow_distance > wide_distance)["=="](true)
end)

T.Test("Orbit camera view follows the mouse, dragging to the right moves what is behind the model to the right", function()
	local orbit, camera = create()
	-- something far away in the middle of the view, like the sky
	local far = camera:GetPosition() + camera:GetRotation():GetForward() * 1000
	T(math.abs(ndc(camera, far)) < 1e-3)["=="](true)
	orbit:Rotate(60, 0)
	orbit:Apply()
	T(ndc(camera, far) > 0.1)["=="](true)
	orbit:Rotate(-120, 0)
	orbit:Apply()
	T(ndc(camera, far) < -0.1)["=="](true)
end)

T.Test("Orbit camera dragging down moves the view down and the pitch stops short of the poles", function()
	local orbit, camera = create()
	local far = camera:GetPosition() + camera:GetRotation():GetForward() * 1000
	local height = camera:GetPosition().y
	orbit:Rotate(0, 30)
	orbit:Apply()
	-- the camera looks up from lower, the projection's y points down the screen
	local _, y = ndc(camera, far)
	T(y > 0.1)["=="](true)
	T(camera:GetPosition().y < height)["=="](true)
	orbit:Rotate(0, 6000)
	T(orbit:GetPitch() <= 1.5)["=="](true)
	orbit:Rotate(0, -12000)
	T(orbit:GetPitch() >= -1.5)["=="](true)
end)

T.Test("Orbit camera view offset is the way from the target to the camera and needs no camera", function()
	local orbit, camera = create()

	for _, angles in ipairs{{0.3, -0.5}, {2.5, 0.2}, {-1.2, 1.1}, {math.pi / 4, -0.6155}} do
		orbit.Yaw, orbit.Pitch = angles[1], angles[2]
		orbit:Apply()
		local expected = (camera:GetPosition() - orbit:GetTarget()):GetNormalized()
		local offset = orbit:GetViewOffset()
		T(math.abs(offset.x - expected.x) < 1e-4)["=="](true)
		T(math.abs(offset.y - expected.y) < 1e-4)["=="](true)
		T(math.abs(offset.z - expected.z) < 1e-4)["=="](true)
	end

	local alone = OrbitCamera.New()
	alone:Rotate(25, -10)
	T(alone:GetYaw() > OrbitCamera.New():GetYaw())["=="](true)
	T(alone:GetViewOffset():GetLength() > 0.999)["=="](true)
end)

T.Test("Orbit camera zoom is limited and reset returns to the fit", function()
	local orbit, camera = create(1, 1)
	local fitted = orbit:GetDistance()
	orbit:Rotate(40, 20)
	orbit:Zoom(-100)
	T(orbit:GetDistance() >= 0.2)["=="](true)
	orbit:Zoom(1000)
	T(orbit:GetDistance() <= 50)["=="](true)
	orbit:Pan(30, 10, 600)
	orbit:Reset()
	orbit:Apply()
	T(orbit:GetDistance())["=="](fitted)
	local x, y = ndc(camera, Vec3(2, 1, -3))
	T(math.abs(x) < 1e-4 and math.abs(y) < 1e-4)["=="](true)
end)

T.Test("Orbit camera panning drags the model along with the mouse", function()
	local orbit, camera = create()
	orbit:Pan(100, 0, 600)
	orbit:Apply()
	T(ndc(camera, Vec3(2, 1, -3)) > 0)["=="](true)
	orbit:Reset()
	orbit:Pan(0, 100, 600)
	orbit:Apply()
	-- the projection's y points down the screen
	local _, y = ndc(camera, Vec3(2, 1, -3))
	T(y > 0)["=="](true)
end)
