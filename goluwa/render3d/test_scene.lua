local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local test_scene = library()
local root

function test_scene.GetRoot()
	if not root or not root:IsValid() then
		root = Entity.New{Name = "test_scene"}
		root:AddComponent("transform")
	end

	return root
end

function test_scene.GetNumber(name, default)
	local value = os.getenv(name)

	if value == nil or value == "" then return default end

	return tonumber(value) or error(name .. " is not a number: " .. value)
end

function test_scene.GetString(name, default)
	local value = os.getenv(name)

	if value == nil or value == "" then return default end

	return value
end

function test_scene.Reset(config)
	config = config or {}

	if root and root:IsValid() then root:Remove() end

	root = nil
	render3d.SetOceanEnabled(false)
	local sun = config.sun or {elevation = 45, azimuth = 30}

	if sun.elevation then
		local elevation = math.rad(sun.elevation)
		local azimuth = math.rad(sun.azimuth or 0)
		sun = Vec3(
			-math.sin(azimuth) * math.cos(elevation),
			math.sin(elevation),
			-math.cos(azimuth) * math.cos(elevation)
		)
	end

	weather.SetSunDirection(sun)
	weather.SetCloudLayers(config.clouds or {})
	weather.SetRain(0)
	weather.SetSnow(0)
	weather.SetWetness(0)

	if config.visibility then weather.SetVisibility(config.visibility) end
end

function test_scene.Matte(value, roughness)
	if type(value) == "number" then value = Color(value, value, value, 1) end

	return shapes.Material{Color = value, Roughness = roughness or 0.9, Metallic = 0}
end

function test_scene.Box(config)
	config = config or {}
	local entity, body = shapes.Box{
		Name = config.name,
		Position = config.pos,
		Rotation = config.rotation,
		Size = config.size,
		Material = config.material or test_scene.Matte(0.5),
		Collision = config.collision or false,
		RigidBody = config.collision and config.rigid_body or false,
	}

	if entity.visual then entity.visual:SetCullDistance(0) end

	test_scene.GetRoot():AddChild(entity)
	return entity, body
end

function test_scene.Ground(config)
	config = config or {}
	local size = config.size or 400
	return test_scene.Box{
		name = "ground",
		pos = Vec3(0, (config.top or 0) - 0.5, 0),
		size = Vec3(size, 1, size),
		material = config.material or test_scene.Matte(0.4),
		collision = config.collision,
	}
end

function test_scene.Room(config)
	local pos = config.pos or Vec3(0, 0, 0)
	local size = config.size
	local t = config.thickness or 0.4
	local material = config.material or test_scene.Matte(0.5)
	local openings = {}

	for _, opening in ipairs(config.openings or {}) do
		openings[opening.wall] = opening
	end

	local function box(name, offset, extent)
		test_scene.Box{
			name = "room_" .. name,
			pos = pos + offset,
			size = extent,
			material = material,
			collision = config.collision,
		}
	end

	box("floor", Vec3(0, -t / 2, 0), Vec3(size.x + 2 * t, t, size.z + 2 * t))
	box("roof", Vec3(0, size.y + t / 2, 0), Vec3(size.x + 2 * t, t, size.z + 2 * t))

	for _, wall in ipairs{"+z", "-z", "+x", "-x"} do
		local sign = wall:sub(1, 1) == "+" and 1 or -1
		local along_x = wall:sub(2, 2) == "z"
		local width = along_x and size.x + 2 * t or size.z
		local distance = (along_x and size.z or size.x) / 2 + t / 2
		local height = size.y
		local rects = {}
		local opening = openings[wall]

		if not opening then
			rects[1] = {0, height / 2, width, height}
		else
			local low = opening.y - opening.height / 2
			local high = opening.y + opening.height / 2
			local left = opening.x - opening.width / 2
			local right = opening.x + opening.width / 2

			if low > 0 then rects[#rects + 1] = {0, low / 2, width, low} end

			if high < height then
				rects[#rects + 1] = {0, (high + height) / 2, width, height - high}
			end

			if left > -width / 2 then
				rects[#rects + 1] = {(left - width / 2) / 2, opening.y, left + width / 2, opening.height}
			end

			if right < width / 2 then
				rects[#rects + 1] = {(right + width / 2) / 2, opening.y, width / 2 - right, opening.height}
			end
		end

		for i, rect in ipairs(rects) do
			local across, up, extent, tall = rect[1], rect[2], rect[3], rect[4]

			if along_x then
				box(wall .. i, Vec3(across, up, sign * distance), Vec3(extent, tall, t))
			else
				box(wall .. i, Vec3(sign * distance, up, across), Vec3(t, tall, extent))
			end
		end
	end
end

function test_scene.Mirror(config)
	local normal = config.normal or Vec3(0, 0, 1)
	local size = config.size or {1, 1}
	local entity = shapes.Polygon{
		Name = config.name or "mirror",
		Position = config.pos,
		Polygon = function(poly)
			shapes.BuildPlane(poly, Vec3(0, 0, 0), normal, size[1] / 2, size[2] / 2)
		end,
		Material = {
			Color = Color(1, 1, 1, 1),
			MetallicMultiplier = 1,
			RoughnessMultiplier = 0.02,
			DoubleSided = true,
		},
		Collision = false,
		RigidBody = false,
	}

	if entity.visual then entity.visual:SetCullDistance(0) end

	test_scene.GetRoot():AddChild(entity)
	return entity
end

function test_scene.WhenReady(cb)
	if scene_bvh.readied then
		cb()
		return
	end

	event.AddListener("BVHSceneReady", {}, function()
		cb()
		return event.destroy_tag
	end)
end

function test_scene.Run(config)
	local views = config.views
	local properties = {}

	for i, view in ipairs(views) do
		assert(view.ev ~= nil, "view " .. i .. " needs an ev, a number or \"auto\"")
		local ang = view.ang or {0, 0, 0}
		local pitch = math.clamp(ang[1], -89, 89)
		properties[i] = {
			Position = view.pos,
			Rotation = QuatDeg3(pitch, ang[2], ang[3] or 0),
			ExposureLock = view.ev ~= "auto" and view.ev or false,
		}

		if view.fov then properties[i].FOV = math.rad(view.fov) end

		if view.local_exposure then
			properties[i].LocalExposure = view.local_exposure
		end
	end

	test_scene.WhenReady(function()
		Shot.Sequence(
			properties,
			function(texture, info, i)
				if config.each then
					config.each(texture, info, views[i], i)
				else
					logf(
						"[test_scene] saved %s\n",
						texture:SaveWithoutAlpha("tmp/shots/" .. (views[i].name or i) .. ".png")
					)
				end
			end,
			{
				settle = config.settle,
				converge = config.converge,
				max_settle = config.max_settle,
			},
			function()
				system.ShutDown(0)
			end
		)
	end)
end

return test_scene
