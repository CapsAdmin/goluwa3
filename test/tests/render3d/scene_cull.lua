local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ffi = require("ffi")
local cube

local function get_cube()
	if not cube then
		cube = Polygon3D.New()
		shapes.BuildCube(cube, 1)
		cube:BuildBoundingBox()
		cube:Upload()
	end

	return cube
end

local function configure_camera()
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	return camera
end

local function spawn(position, scale, polygon3d, material)
	local entity = Entity.New{Name = "scene_cull_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	entity.transform:SetScale(Vec3(scale, scale, scale))
	local visual = entity:AddComponent("visual")
	local primitive = Entity.New{Name = "scene_cull_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d or get_cube())
	visual_primitive:SetMaterial(material or Material.New())
	visual:BuildAABB()
	visual:SetUseOcclusionCulling(false)
	return entity
end

local function get_ids(entity)
	local ids = {}

	for i, item in ipairs(entity.visual.scene_instances or {}) do
		ids[i] = item.id
	end

	return ids
end

local function draw_frames(draw, count)
	for _ = 1, count or 4 do
		draw()
	end
end

local function is_drawn(result, entity)
	for _, id in ipairs(get_ids(entity)) do
		if result.by_id[id] then return true end
	end

	return false
end

local function box_inside(planes, aabb)
	for i = 0, 5 do
		local a, b, c, d = planes[i * 4], planes[i * 4 + 1], planes[i * 4 + 2], planes[i * 4 + 3]
		local x = a > 0 and aabb.max_x or aabb.min_x
		local y = b > 0 and aabb.max_y or aabb.min_y
		local z = c > 0 and aabb.max_z or aabb.min_z

		if a * x + b * y + c * z + d < 0 then return false end
	end

	return true
end

T.Test3D("Graphics render3d the main view cull keeps what the frustum holds and nothing else", function(draw)
	local camera = configure_camera()
	local entities = {}
	local seed = 7

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	for i = 1, 60 do
		entities[i] = spawn(
			Vec3((random() - 0.5) * 240, (random() - 0.5) * 240, -random() * 200 + 40),
			1 + random() * 2
		)
	end

	draw_frames(draw)
	local result = scene_draw.ReadBackCull(0)
	local planes = ffi.new("float[24]")
	gpu_culling.ExtractFrustumPlanes(camera:BuildViewMatrix() * camera:BuildProjectionMatrix(), planes, 1)
	local expected_visible = 0
	local mismatches = {}

	for i, entity in ipairs(entities) do
		local inside = box_inside(planes, entity.visual:GetWorldAABB())
		local drawn = is_drawn(result, entity)

		if inside then expected_visible = expected_visible + 1 end

		if inside ~= drawn then
			local aabb = entity.visual:GetWorldAABB()
			mismatches[#mismatches + 1] = string.format(
				"%d inside=%s drawn=%s box=%.1f,%.1f,%.1f..%.1f,%.1f,%.1f",
				i,
				tostring(inside),
				tostring(drawn),
				aabb.min_x,
				aabb.min_y,
				aabb.min_z,
				aabb.max_x,
				aabb.max_y,
				aabb.max_z
			)
		end
	end

	-- some of them must be in and some out, or this tests nothing
	T(expected_visible > 5 and expected_visible < 55)["=="](true)
	T(table.concat(mismatches, "\n"))["=="]("")

	for _, entity in ipairs(entities) do
		entity:Remove()
	end
end)

T.Test3D("Graphics render3d the main view cull honors the cull distance and the size on screen", function(draw)
	configure_camera()
	local near_limited = spawn(Vec3(0, 0, -3), 1)
	near_limited.visual:SetCullDistance(5)
	local far_limited = spawn(Vec3(3, 0, -10), 1)
	far_limited.visual:SetCullDistance(5)
	local tiny = spawn(Vec3(0, 0, -90), 0.005)
	local small_near = spawn(Vec3(0, 0, -2), 0.005)
	local big_far = spawn(Vec3(-3, 0, -90), 3)
	draw_frames(draw)
	local result = scene_draw.ReadBackCull(0)
	T(is_drawn(result, near_limited))["=="](true)
	T(is_drawn(result, far_limited))["=="](false)
	T(is_drawn(result, tiny))["=="](false)
	T(is_drawn(result, small_near))["=="](true)
	T(is_drawn(result, big_far))["=="](true)
	near_limited:Remove()
	far_limited:Remove()
	tiny:Remove()
	small_near:Remove()
	big_far:Remove()
end)

T.Test3D("Graphics render3d the main view cull picks one level of detail and fades the two that overlap", function(draw)
	configure_camera()
	local RADII_PER_UNIT = 1 / math.sqrt(3)

	local function spawn_lod(distance)
		local entity = Entity.New{Name = "scene_cull_lod"}
		entity:AddComponent("transform")
		entity.transform:SetPosition(Vec3(0, 0, -distance))
		local visual = entity:AddComponent("visual")
		local coarse = Polygon3D.New()
		shapes.BuildCube(coarse, 1)
		coarse:BuildBoundingBox()
		coarse:Upload()
		coarse:SetLODLevel(1)
		coarse:SetLODDistance(10)

		for i, polygon in ipairs{get_cube(), coarse} do
			local primitive = Entity.New{Name = "scene_cull_lod_primitive" .. i, Parent = entity}
			primitive:AddComponent("transform")
			primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
			primitive.visual_primitive:SetMaterial(Material.New())
		end

		visual:BuildAABB()
		visual:SetUseOcclusionCulling(false)
		return entity
	end

	local function levels(entity, result)
		local drawn = {}

		for i, item in ipairs(entity.visual.scene_instances) do
			if result.by_id[item.id] then
				drawn[#drawn + 1] = {level = item.level, fade = result.by_id[item.id].fade}
			end
		end

		return drawn
	end

	local entity = spawn_lod(8)
	draw_frames(draw)
	local near = levels(entity, scene_draw.ReadBackCull(0))
	T(#near)["=="](1)
	T(near[1].level)["=="](0)
	T(near[1].fade)["=="](0)
	entity.transform:SetPosition(Vec3(0, 0, -40))
	draw_frames(draw)
	local far = levels(entity, scene_draw.ReadBackCull(0))
	T(#far)["=="](1)
	T(far[1].level)["=="](1)
	entity.transform:SetPosition(Vec3(0, 0, -10 / RADII_PER_UNIT))
	draw_frames(draw)
	local between = levels(entity, scene_draw.ReadBackCull(0))
	T(#between)["=="](2)
	T(between[1].fade * between[2].fade < 0 or
		between[1].fade == 0 or
		between[2].fade == 0)["=="](true)
	pvars.SetSession("lod_level", 1)
	draw_frames(draw)
	local forced = levels(entity, scene_draw.ReadBackCull(0))
	pvars.SetSession("lod_level", -1)
	T(#forced)["=="](1)
	T(forced[1].level)["=="](1)
	entity:Remove()
end)

T.Test3D("Graphics render3d the main view cull hides what the depth of the last frame hides", function(draw)
	configure_camera()
	Visual.Library.SetOcclusionCulling(true)
	local occluder = spawn(Vec3(0, 0, -5), 1)
	occluder.transform:SetScale(Vec3(8, 8, 1))
	local hidden = spawn(Vec3(0, 0, -12), 1)
	hidden.visual:SetUseOcclusionCulling(true)
	local beside = spawn(Vec3(30, 0, -12), 1)
	beside.visual:SetUseOcclusionCulling(true)
	local plain = spawn(Vec3(0, 0, -14), 1)
	-- the depth pyramid is of the frame before, so it takes a few
	draw_frames(draw, 8)
	local result = scene_draw.ReadBackCull(0)
	T(is_drawn(result, occluder))["=="](true)
	T(is_drawn(result, hidden))["=="](false)
	T(is_drawn(result, plain))["=="](true)
	Visual.Library.SetOcclusionCulling(false)
	draw_frames(draw, 8)
	T(is_drawn(scene_draw.ReadBackCull(0), hidden))["=="](true)
	occluder:Remove()
	hidden:Remove()
	beside:Remove()
	plain:Remove()
end)

T.Test3D("Graphics render3d a shadow cull keeps what is in the box of the cascade and big enough in its view", function(draw)
	configure_camera()
	local inside = spawn(Vec3(0, 0, -5), 1)
	local side = spawn(Vec3(30, 0, -5), 1)
	local above = spawn(Vec3(0, 40, -5), 1)
	local behind_far = spawn(Vec3(0, 0, -100), 1)
	local tiny = spawn(Vec3(2, 2, -5), 0.01)
	local before_near = spawn(Vec3(0, 0, 50), 1)
	local no_shadow = spawn(Vec3(-3, 0, -5), 1)
	no_shadow.visual:SetCastShadows(false)
	draw_frames(draw)
	local planes = ffi.new("float[24]")

	local function set(i, x, y, z, d)
		planes[i * 4], planes[i * 4 + 1], planes[i * 4 + 2], planes[i * 4 + 3] = x, y, z, d
	end

	set(0, 1, 0, 0, 10)
	set(1, -1, 0, 0, 10)
	set(2, 0, 1, 0, 10)
	set(3, 0, -1, 0, 10)
	set(4, 0, 0, -1, 1000)
	set(5, 0, 0, 1, 30)
	local buffers = scene_draw.NewShadowBuffers()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local count = scene_draw.CullShadow(cmd, buffers, planes, Vec3(0, 0, 0), 1, Matrix44())
	cmd:End()
	render.SubmitAndWait(cmd)
	local result = scene_draw.ReadBackShadowCull(buffers, count)
	T(is_drawn(result, inside))["=="](true)
	T(is_drawn(result, side))["=="](false)
	T(is_drawn(result, above))["=="](false)
	T(is_drawn(result, behind_far))["=="](false)
	T(is_drawn(result, tiny))["=="](false)
	T(is_drawn(result, before_near))["=="](true)
	T(is_drawn(result, no_shadow))["=="](false)
	scene_draw.RemoveShadowBuffers(buffers)
	cmd:Remove()

	for _, entity in ipairs{inside, side, above, behind_far, tiny, before_near, no_shadow} do
		entity:Remove()
	end
end)

T.Test3D("Graphics render3d the main view cull tests the box of each part of a visual, not of all of them", function(draw)
	configure_camera()
	local entity = Entity.New{Name = "scene_cull_parts"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -10))
	local visual = entity:AddComponent("visual")
	local parts = {}

	for i, x in ipairs{0, -60} do
		local primitive = Entity.New{Name = "scene_cull_part" .. i, Parent = entity}
		primitive:AddComponent("transform")
		primitive.transform:SetPosition(Vec3(x, 0, 0))
		local visual_primitive = primitive:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(get_cube())
		visual_primitive:SetMaterial(Material.New())
		parts[i] = primitive
	end

	visual:BuildAABB()
	visual:SetUseOcclusionCulling(false)
	draw_frames(draw)
	local result = scene_draw.ReadBackCull(0)
	local drawn = {}

	for _, item in ipairs(visual.scene_instances) do
		drawn[item.entry.entity] = result.by_id[item.id] ~= nil
	end

	T(drawn[parts[1]])["=="](true)
	T(drawn[parts[2]])["=="](false)
	entity:Remove()
end)

T.Test3D("Graphics render3d the visibility estimate sees a row in front of another and not the one behind it", function(draw)
	if not render.GetDevice().ray_query_supported then return end

	local visibility = import("goluwa/render3d/scene/visibility.lua")
	configure_camera()
	local occluder = spawn(Vec3(0, 0, -5), 1)
	occluder.transform:SetScale(Vec3(8, 8, 1))
	local behind = spawn(Vec3(0, 0, -12), 1)
	local aside = spawn(Vec3(0, 0, -5), 1)
	aside.transform:SetPosition(Vec3(6, 0, -12))
	draw_frames(draw)
	local result = visibility.Estimate(64)
	local by_entity = {}

	for _, entity in ipairs{occluder, behind, aside} do
		by_entity[entity] = result.by_id[get_ids(entity)[1]]
	end

	T(by_entity[occluder] ~= nil and by_entity[behind] ~= nil)["=="](true)
	T(by_entity[occluder].self > 0)["=="](true)
	T(by_entity[behind].self)["=="](0)
	T(by_entity[behind].other > 0)["=="](true)
	occluder:Remove()
	behind:Remove()
	aside:Remove()
end)
