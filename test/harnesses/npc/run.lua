-- spawns npcs on gm_construct and reports how they move. env: NPC_COUNT, NPC_SECONDS, NPC_SHOT=path.png (a shot at the end),
-- NPC_FOLLOW=1 (the shot looks at that npc from NPC_DISTANCE meters away, the default is an overview of all of them)
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
local npcs = import("lua/npcs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Quat = import("goluwa/structs/quat.lua")
local COUNT = tonumber(os.getenv("NPC_COUNT")) or 8
local FOLLOW = tonumber(os.getenv("NPC_FOLLOW"))
local DISTANCE = tonumber(os.getenv("NPC_DISTANCE")) or 4
local shooting
local SECONDS = tonumber(os.getenv("NPC_SECONDS")) or 20
local names = npcs.GetNames()
commands.RunString("map gm_construct")

if os.getenv("NPC_DEBUG") then
	commands.RunString("nav_show")
	commands.RunString("npc_show_paths")
end
local spawned = {}
local started, loaded_at, last_report
local frame_sum, frame_count, last_time = 0, 0, nil

event.AddListener("Update", "npc_harness", function()
	local now = system.GetElapsedTime()

	if started and now - started > 5 then
		local time = system.GetTime()

		if last_time then
			frame_sum, frame_count = frame_sum + time - last_time, frame_count + 1
		end

		last_time = time
	end

	if not started then
		if scene_loading.IsLoading() or not nav_mesh.GetMesh() then return end

		loaded_at = loaded_at or now

		if now - loaded_at < 1 then return end

		started = now
		local mesh = nav_mesh.GetMesh()
		local center = SpawnPoint.Pick():GetPlacement(0)

		for i = 1, COUNT do
			local position = mesh:GetRandomPoint(center, 30)
			spawned[i] = npcs.Spawn(names[(i - 1) % #names + 1], position + Vec3(0, 0.05, 0), math.randomf(-math.pi, math.pi))
			spawned[i].start = position
			spawned[i].arrived, spawned[i].failed = 0, 0
			spawned[i]:AddLocalListener("OnNPCArrived", function()
				spawned[i].arrived = spawned[i].arrived + 1
			end)
			spawned[i]:AddLocalListener("OnNPCPathFailed", function()
				spawned[i].failed = spawned[i].failed + 1
			end)
		end

		print("spawned", #spawned)
		return
	end

	if os.getenv("NPC_QUIET") then last_report = now end

	if not last_report or now - last_report >= 2 then
		last_report = now

		for i, entity in ipairs(spawned) do
			local npc = entity.npc
			local p = entity.transform:GetPosition()
			local mesh = nav_mesh.GetMesh()
			local area = mesh:GetAreaAt(p)
			print(
				string.format(
					"[npc] %-16s %6.1f %6.1f %6.1f moved %5.1f goal %s area %s grounded %s turning %s fwd %.2f side %.2f vel %.2f stuck %d seq %s",
					entity:GetName(),
					p.x,
					p.y,
					p.z,
					p:Distance(entity.start),
					npc:GetGoal() and string.format("%.0f,%.0f", npc:GetGoal().x, npc:GetGoal().z) or "-",
					area and area.Id or "off-mesh",
					tostring(entity.rigid_body:GetGrounded()),
					tostring(npc.turning),
					npc.cmd.forward,
					npc.cmd.side,
					entity.rigid_body:GetVelocity():GetLength(),
					npc.stuck_failures,
					entity.animator and (entity.animator.Sequence .. (entity.animator.skeleton and "" or " (no skeleton)")) .. " visual " .. tostring(entity.visual and entity.visual:IsLoading()) .. "/" .. tostring(entity.visual and entity.visual.Skeleton ~= nil) .. "/" .. tostring(entity.visual and entity.visual.Visible) or "-"
				)
			)
		end
	end

	if now - started < SECONDS then return end

	local arrived, failed, off_mesh, far = 0, 0, 0, 0

	for _, entity in ipairs(spawned) do
		arrived, failed = arrived + entity.arrived, failed + entity.failed

		if entity.npc.far then far = far + 1 end

		if not nav_mesh.GetMesh():GetAreaAt(entity.transform:GetPosition(), 2) then
			off_mesh = off_mesh + 1
			local p = entity.transform:GetPosition()
			local area, x, y, z = nav_mesh.GetMesh():GetNearestArea(p, 10)
			print(string.format("[npc] off mesh: %s at %.1f %.1f %.1f far %s goal %s nearest area %s at %.1f %.1f %.1f lost %s", entity:GetName(), p.x, p.y, p.z, tostring(entity.npc.far), tostring(entity.npc:GetGoal() ~= nil), area and area.Id or "none", x, y, z, tostring(entity.npc.lost_since)))
		end
	end

	if _G.NPC_COST then _G.NPC_COST() end

	print(string.format("[npc] average frame %.2f ms over %d frames", frame_sum / math.max(frame_count, 1) * 1000, frame_count))
	print(string.format("[npc] summary: %d arrivals, %d failed paths, %d npcs off the mesh of %d, %d far", arrived, failed, off_mesh, #spawned, far))

	local path = os.getenv("NPC_SHOT")

	if not path then os.exit(0) end

	if shooting then return end

	shooting = true
	local view

	if FOLLOW then
		local target = spawned[FOLLOW]
		local position = target.transform:GetPosition()
		local forward = target.transform:GetRotation():GetForward()
		local right = target.transform:GetRotation():GetRight()
		local eye = position + forward * DISTANCE * 0.8 + right * DISTANCE * 0.5 + Vec3(0, 1.2, 0)
		local direction = (position + Vec3(0, 0.9, 0) - eye):GetNormalized()
		view = {
			Position = eye,
			Rotation = Quat():SetAngles(Ang3(math.asin(direction.y), math.atan2(-direction.x, -direction.z), 0)),
			FOV = 1.1,
		}
	else
		local sum = Vec3()

		for _, entity in ipairs(spawned) do
			sum = sum + entity.transform:GetPosition()
		end

		local center = sum / #spawned
		view = {
			Position = center + Vec3(0, 14, 16),
			Rotation = Quat():SetAngles(Ang3(-0.7, 0, 0)),
			FOV = 1.2,
		}
	end

	Shot.Capture(view, function(texture)
		print("shot", texture:SaveWithoutAlpha(path))
		os.exit(0)
	end, {settle = 2})
end)
