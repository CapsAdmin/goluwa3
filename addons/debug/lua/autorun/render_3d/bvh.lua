local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local system = import("goluwa/system.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Color = import("goluwa/structs/color.lua")
local show_bvh_debug = false
local BVH_MODES = {"all", "leaves", "top"}
local current_bvh_mode = "all"
local bvh_max_depth = 30
local bvh_max_boxes = 4000
local bvh_min_extent = 0
local drawn_bvh_ids = {}

local function is_shift_down()
	return input.IsKeyDown("left_shift") or
		input.IsKeyDown("right_shift") or
		input.IsKeyDown("shift")
end

local function is_control_down()
	return input.IsKeyDown("left_control") or
		input.IsKeyDown("left_super") or
		input.IsKeyDown("right_control") or
		input.IsKeyDown("control")
end

-- depth 0 (root) is warm red, deep nodes fade toward cyan
local function depth_color(depth)
	local t = math.clamp(depth / 24.0, 0.0, 1.0)
	local r = 1.0 - t
	local b = t
	return {r, 0.35 + 0.4 * t, b, 0.85}
end

local function node_extent(node)
	local ex = node.bounds_max[0] - node.bounds_min[0]
	local ey = node.bounds_max[1] - node.bounds_min[1]
	local ez = node.bounds_max[2] - node.bounds_min[2]
	return math.max(ex, ey, ez)
end

-- walk the tree iteratively and draw a wire box per node that passes the
-- current mode and filter. returns the set of ids drawn this frame
local function draw_bvh_nodes()
	local nodes = scene_bvh.debug_nodes
	local node_count = scene_bvh.debug_node_count

	if not nodes or not node_count or node_count <= 0 then return {} end

	local drawn = {}
	local drawn_count = 0
	local stack = {{0, 0}}
	local stack_size = 1

	while stack_size > 0 do
		local frame = stack[stack_size]
		stack_size = stack_size - 1
		local index = frame[1]
		local depth = frame[2]

		if index >= node_count then continue end

		if depth > bvh_max_depth then continue end

		local node = nodes[index]
		local count = node.count
		local is_leaf = count > 0
		local alive = node.bounds_min[0] <= node.bounds_max[0]
		local should_draw = false

		if current_bvh_mode == "all" then
			should_draw = true
		elseif current_bvh_mode == "leaves" then
			should_draw = is_leaf
		elseif current_bvh_mode == "top" then
			should_draw = depth <= 2
		end

		if alive and should_draw and drawn_count < bvh_max_boxes then
			if node_extent(node) >= bvh_min_extent then
				local id = "bvh_debug_node_" .. current_bvh_mode .. "_" .. tostring(index)
				debug_draw.DrawWireAABB{
					id = id,
					aabb = {
						min_x = node.bounds_min[0],
						min_y = node.bounds_min[1],
						min_z = node.bounds_min[2],
						max_x = node.bounds_max[0],
						max_y = node.bounds_max[1],
						max_z = node.bounds_max[2],
					},
					color = depth_color(depth),
					width = 1,
				}
				drawn[#drawn + 1] = id
				drawn_count = drawn_count + 1
			end
		end

		-- count == 0 means the node has children at left_first / left_first+1.
		-- top-tree leaves point at a real child root (with a dead sentinel
		-- beside it), so only descend into children whose bounds are alive
		if count == 0 and drawn_count < bvh_max_boxes then
			local left = node.left_first

			for offset = 0, 1 do
				local child_index = left + offset

				if
					child_index < node_count and
					nodes[child_index].bounds_min[0] <= nodes[child_index].bounds_max[0]
				then
					stack[#stack + 1] = {child_index, depth + 1}
					stack_size = stack_size + 1
				end
			end
		end
	end

	return drawn
end

local function prune_bvh_nodes(drawn)
	local keep = {}

	for _, id in ipairs(drawn) do
		keep[id] = true
	end

	for _, id in ipairs(drawn_bvh_ids) do
		if not keep[id] then debug_draw.Remove(id) end
	end

	drawn_bvh_ids = drawn
end

local function clear_bvh_nodes()
	for _, id in ipairs(drawn_bvh_ids) do
		debug_draw.Remove(id)
	end

	drawn_bvh_ids = {}
end

local function draw_bvh_stats(x, y)
	local ready = scene_bvh.IsReady()
	local node_count = scene_bvh.node_count or 0
	local triangle_count = scene_bvh.triangle_count or 0
	local build_time = scene_bvh.build_time or 0
	local version = scene_bvh.version or 0
	local top_lazy = scene_bvh.top_lazy_count or 0
	local dirty = scene_bvh.dirty_since
	local now = system.GetElapsedTime()
	local block_height = 176
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.55)
	render2d.DrawRoundedRect(x, y, 340, block_height, 6)
	local white = Color(1, 1, 1, 1)
	render2d.DrawText{
		text = string.format("Scene BVH: %s", ready and "built" or "empty"),
		x = x + 8,
		y = y + 8,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Triangles: %d  Nodes: %d  Version: %d",
			triangle_count,
			node_count,
			version
		),
		x = x + 8,
		y = y + 28,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format("Build time: %.2fs  Top lazy: %d", build_time, top_lazy),
		x = x + 8,
		y = y + 48,
		foreground_color = white,
	}
	local dirty_text = "no"

	if dirty then dirty_text = ("yes (%.2fs)"):format(now - dirty) end

	render2d.DrawText{
		text = "Dirty: " .. dirty_text,
		x = x + 8,
		y = y + 68,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Mode: %s  Max depth: %d  Max boxes: %d  Min extent: %.2f",
			current_bvh_mode,
			bvh_max_depth,
			bvh_max_boxes,
			bvh_min_extent
		),
		x = x + 8,
		y = y + 88,
		foreground_color = white,
	}
	render2d.DrawText{
		text = string.format(
			"Drawn boxes: %d%s",
			#drawn_bvh_ids,
			#drawn_bvh_ids >= bvh_max_boxes and " (capped)" or ""
		),
		x = x + 8,
		y = y + 108,
		foreground_color = white,
	}
	render2d.DrawText{
		text = "Box color = tree depth (red root -> cyan deep)",
		x = x + 8,
		y = y + 128,
		foreground_color = white,
	}
	render2d.DrawText{
		text = "F1: toggle  Shift+F1: mode  Ctrl+F1: rebuild",
		x = x + 8,
		y = y + 148,
		foreground_color = white,
	}
end

event.AddListener("Draw3DGeometry", "bvh_debug_draw", function(cmd, dt)
	if not show_bvh_debug then return end

	prune_bvh_nodes(draw_bvh_nodes())
end)

event.AddListener("Draw2D", "bvh_debug_panel", function(cmd, dt)
	if not show_bvh_debug then return end

	draw_bvh_stats(10, 10)
end)

event.AddListener("KeyInput", "bvh_debug_toggle", function(key, press)
	if not press or key ~= "f1" then return end

	if is_control_down() then
		scene_bvh.Build()
		print("BVH debug: forced rebuild")
		return
	end

	if is_shift_down() then
		local i = 1

		for idx, mode in ipairs(BVH_MODES) do
			if mode == current_bvh_mode then
				i = idx

				break
			end
		end

		current_bvh_mode = BVH_MODES[(i % #BVH_MODES) + 1]
		show_bvh_debug = true
		clear_bvh_nodes()
		print("BVH debug mode: " .. current_bvh_mode)
		return
	end

	show_bvh_debug = not show_bvh_debug

	if not show_bvh_debug then clear_bvh_nodes() end

	print("BVH debug: " .. (show_bvh_debug and "ON" or "OFF"))
end)

commands.Add("scene_bvh_debug=number|nil", function(max_boxes)
	show_bvh_debug = true

	if max_boxes then bvh_max_boxes = math.max(math.floor(max_boxes), 1) end

	clear_bvh_nodes()
	print(
		"BVH debug: ON mode=" .. current_bvh_mode .. " max_boxes=" .. tostring(bvh_max_boxes)
	)
end)

commands.Add("scene_bvh_debug_mode=string[1]", function(mode)
	local valid = true

	for _, m in ipairs(BVH_MODES) do
		if m == mode then valid = false end
	end

	if not valid then
		print("BVH debug: unknown mode '" .. tostring(mode) .. "' (all|leaves|top)")
		return
	end

	current_bvh_mode = mode
	clear_bvh_nodes()
	print("BVH debug mode: " .. mode)
end)

commands.Add("scene_bvh_debug_off", function()
	show_bvh_debug = false
	clear_bvh_nodes()
	print("BVH debug: OFF")
end)
