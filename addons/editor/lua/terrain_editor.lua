local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Slider = react.Element(import("goluwa/render2d/ui/elements/slider.lua"))
local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local TerrainComponent = import("goluwa/entities/components/terrain.lua")
local ScatterPlacements = import("goluwa/entities/components/scatter_placements.lua")
local players = import("lua/players.lua")
local editor_history = import("lua/editor_history.lua")
local terrain_editor = {}
local LISTENER = "terrain_editor"
local CIRCLE_SEGMENTS = 40
local UPLOAD_INTERVAL = 0.08
local MAX_RAY = 2000
local SCULPT_SPEED = 10
local BLEND_SPEED = 10
local PAINT_THRESHOLD = 0.25
local SCATTER_TRIES_PER_SECOND = 40
local brush_color = Color(1, 0.8, 0.3, 1)
local erase_color = Color(1, 0.35, 0.3, 1)
local TOOLS = {
	terrain = {"none", "raise", "lower", "smooth", "flatten", "paint"},
	scatter = {"none", "paint", "erase"},
}
local state = {
	kind = nil,
	component = nil,
	tool = "none",
	radius = 8,
	strength = 0.5,
	layer = 1,
	spacing = 3,
	scale_min = 0.8,
	scale_max = 1.2,
	align = 0,
	hit = nil,
	stroke = nil,
	window = nil,
}
terrain_editor.state = state

local function changed()
	event.Call("TerrainEditorChanged")
end

local function is_ui_hovering()
	local hovered = MouseInput.GetHoveredObject()
	return hovered:IsValid() and hovered ~= Panel.World
end

local function height_above(data, x, y, z)
	return y - HeightmapSource.SampleHeight(data, x, z)
end

-- distance along the ray to a heightmap terrain's surface, nil when it does not hit within MAX_RAY
local function march_terrain(data, origin, direction)
	local ox, oy, oz = origin.x, origin.y, origin.z
	local dx, dy, dz = direction.x, direction.y, direction.z

	if height_above(data, ox, oy, oz) < 0 then return end

	local previous = 0
	local t = 0

	while t < MAX_RAY do
		t = t + math.max(0.25, t * 0.01)

		if height_above(data, ox + dx * t, oy + dy * t, oz + dz * t) < 0 then
			local a, b = previous, t

			for _ = 1, 16 do
				local m = (a + b) / 2

				if height_above(data, ox + dx * m, oy + dy * m, oz + dz * m) < 0 then
					b = m
				else
					a = m
				end
			end

			return b
		end

		previous = t
	end
end

local function is_brush_target(entity)
	local owner = entity.VisualOwner and entity.VisualOwner.Owner or entity
	local player = players.GetLocal()
	return not player or owner ~= player and not owner:ContainsParent(player)
end

-- the nearest surface: any visual or any terrain
local function cast_surface(origin, direction)
	raycast.SetLODCamera(origin)
	local hit = raycast.CastClosestSolid(origin, direction, MAX_RAY, is_brush_target)
	raycast.SetLODCamera(nil)
	local best = hit and hit.distance
	local normal = hit and hit.normal
	local hit_data

	for terrain in pairs(TerrainComponent.Built) do
		local data = terrain:GetData()
		local t = march_terrain(data, origin, direction)

		if t and (not best or t < best) then best, hit_data = t, data end
	end

	if not best then return end

	local position = origin + direction * best

	if hit_data then
		local e = 0.5
		local x, z = position.x, position.z
		normal = Vec3(
			HeightmapSource.SampleHeight(hit_data, x - e, z) - HeightmapSource.SampleHeight(hit_data, x + e, z),
			2 * e,
			HeightmapSource.SampleHeight(hit_data, x, z - e) - HeightmapSource.SampleHeight(hit_data, x, z + e)
		):GetNormalized()
	end

	return position, normal
end

terrain_editor.CastSurface = cast_surface

local function get_mouse_ray()
	local cam = render3d.GetCamera()
	local width, height = render2d.GetSize()
	return cam:GetPosition(), cam:ScreenToWorldDirection(system.GetWindow():GetMousePosition(), width, height)
end

local function find_hit()
	local origin, direction = get_mouse_ray()

	if state.kind == "terrain" then
		local t = march_terrain(state.component:GetData(), origin, direction)
		return t and origin + direction * t
	end

	return (cast_surface(origin, direction))
end

local function grow_dirty(stroke, min_x, min_z, max_x, max_z)
	local dirty = stroke.dirty

	if not dirty then
		stroke.dirty = {min_x, min_z, max_x, max_z}
		return
	end

	dirty[1], dirty[2] = math.min(dirty[1], min_x), math.min(dirty[2], min_z)
	dirty[3], dirty[4] = math.max(dirty[3], max_x), math.max(dirty[4], max_z)
end

local function flush_terrain(stroke)
	local dirty = stroke.dirty

	if not dirty then return end

	stroke.dirty = nil
	state.component:UpdateRegion(dirty[1], dirty[2], dirty[3], dirty[4])
end

do
	local scratch = ffi.typeof("uint16_t[?]")

	-- sculpt or paint the samples under a circle; editable terrains map world x to columns and z to rows
	local function apply_terrain(stroke, center, dt)
		local terrain = state.component
		local data = terrain:GetData()
		local samples = data.height.samples
		local indices = data.indices.samples
		local resolution = data.height.width
		local per_meter = resolution / data.size
		local cx = (center.x - data.origin[1]) * per_meter
		local cz = (center.z - data.origin[2]) * per_meter
		local r = math.max(state.radius * per_meter, 1)
		local x0 = math.clamp(math.floor(cx - r), 0, resolution - 1)
		local x1 = math.clamp(math.ceil(cx + r), 0, resolution - 1)
		local z0 = math.clamp(math.floor(cz - r), 0, resolution - 1)
		local z1 = math.clamp(math.ceil(cz + r), 0, resolution - 1)
		local raw_per_meter = 65535 / (data.max_height - (data.min_height or 0))
		local tool = state.tool
		local blend = math.min(1, state.strength * dt * BLEND_SPEED)
		local lift = state.strength * dt * SCULPT_SPEED * raw_per_meter
		local source = samples

		if tool == "smooth" then
			source = scratch(resolution * resolution)
			ffi.copy(source, samples, resolution * resolution * 2)
		end

		for z = z0, z1 do
			for x = x0, x1 do
				local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2) / r

				if d < 1 then
					local w = 1 - d
					w = w * w * (3 - 2 * w)
					local i = z * resolution + x

					if tool == "paint" then
						if w > PAINT_THRESHOLD then indices[i] = state.layer end
					else
						local h = samples[i]

						if tool == "raise" then
							h = h + lift * w
						elseif tool == "lower" then
							h = h - lift * w
						elseif tool == "flatten" then
							h = h + (stroke.flatten - h) * blend * w
						elseif tool == "smooth" then
							local sum, count = 0, 0

							for oz = -1, 1 do
								for ox = -1, 1 do
									local sx, sz = x + ox, z + oz

									if sx >= 0 and sx < resolution and sz >= 0 and sz < resolution then
										sum = sum + source[sz * resolution + sx]
										count = count + 1
									end
								end
							end

							h = h + (sum / count - h) * blend * w
						end

						samples[i] = math.clamp(math.floor(h + 0.5), 0, 65535)
					end
				end
			end
		end

		local spacing = 1 / per_meter
		grow_dirty(
			stroke,
			data.origin[1] + (x0 - 1) * spacing,
			data.origin[2] + (z0 - 1) * spacing,
			data.origin[1] + (x1 + 1) * spacing,
			data.origin[2] + (z1 + 1) * spacing
		)
	end

	terrain_editor.ApplyTerrain = apply_terrain
end

local function read_records(component)
	local size = ScatterPlacements.RECORD_SIZE
	local count = math.floor(#component.Records / size)
	local records = {}
	local array = ffi.cast(ffi.typeof("$ *", ScatterPlacements.Record), component.Records)

	for i = 0, count - 1 do
		local r = array[i]
		records[#records + 1] = {r.x, r.y, r.z, r.scale, r.yaw, r.nx, r.ny, r.nz}
	end

	return records
end

local function write_records(component, records)
	local array = ScatterPlacements.RecordArray(#records)

	for i, r in ipairs(records) do
		local out = array[i - 1]
		out.x, out.y, out.z, out.scale, out.yaw, out.nx, out.ny, out.nz = r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]
	end

	component:SetRecords(ffi.string(array, #records * ScatterPlacements.RECORD_SIZE))
end

local function apply_scatter(stroke, center, dt)
	local records = stroke.records
	local radius = state.radius

	if state.tool == "erase" then
		local kept = {}

		for _, r in ipairs(records) do
			if (r[1] - center.x) ^ 2 + (r[3] - center.z) ^ 2 > radius * radius then
				kept[#kept + 1] = r
			end
		end

		if #kept ~= #records then
			stroke.records = kept
			stroke.dirty = true
		end

		return
	end

	stroke.budget = stroke.budget + SCATTER_TRIES_PER_SECOND * state.strength * dt

	while stroke.budget >= 1 do
		stroke.budget = stroke.budget - 1
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * radius
		local x = center.x + math.cos(angle) * distance
		local z = center.z + math.sin(angle) * distance
		local spacing = state.spacing
		local free = true

		for _, r in ipairs(records) do
			if (r[1] - x) ^ 2 + (r[3] - z) ^ 2 < spacing * spacing then
				free = false

				break
			end
		end

		if free then
			local position, normal = cast_surface(Vec3(x, center.y + radius + 50, z), Vec3(0, -1, 0))

			if position then
				normal = (Vec3(0, 1, 0) + (normal - Vec3(0, 1, 0)) * state.align):GetNormalized()
				records[#records + 1] = {
					position.x,
					position.y,
					position.z,
					math.lerp(math.random(), state.scale_min, state.scale_max),
					math.random() * math.pi * 2,
					normal.x,
					normal.y,
					normal.z,
				}
				stroke.dirty = true
			end
		end
	end
end

local function begin_stroke()
	local stroke = {time = 0}

	if state.kind == "terrain" then
		local data = state.component:GetData()
		local u, v = HeightmapSource.ToMap(data, state.hit.x, state.hit.z)
		local resolution = data.height.width
		local column = math.clamp(math.floor(u * resolution + 0.5), 0, resolution - 1)
		local row = math.clamp(math.floor(v * resolution + 0.5), 0, resolution - 1)
		stroke.flatten = data.height.samples[row * resolution + column]
	else
		stroke.records = read_records(state.component)
		stroke.old_records = state.component.Records
		stroke.budget = 1
	end

	state.stroke = stroke
end

local function end_stroke()
	local stroke = state.stroke
	state.stroke = nil
	local component = state.component
	local name = component.Owner:GetName()

	if state.kind == "terrain" then
		flush_terrain(stroke)
		local old_heights, old_layers = component:CommitMaps()
		editor_history.Begin(state.tool .. " " .. name)
		editor_history.RecordProperty(component, {var_name = "Heights"}, old_heights, component.Heights)
		editor_history.RecordProperty(component, {var_name = "LayerMap"}, old_layers, component.LayerMap)
		editor_history.End()
		return
	end

	write_records(component, stroke.records)
	editor_history.RecordProperty(
		component,
		{var_name = "Records"},
		stroke.old_records,
		component.Records
	)
end

local function draw_brush(center)
	local color = state.tool == "erase" and erase_color or brush_color
	local data = state.kind == "terrain" and state.component:GetData()
	local previous

	for i = 0, CIRCLE_SEGMENTS do
		local angle = i / CIRCLE_SEGMENTS * math.pi * 2
		local x = center.x + math.cos(angle) * state.radius
		local z = center.z + math.sin(angle) * state.radius
		local y = data and HeightmapSource.SampleHeight(data, x, z) or center.y
		local point = Vec3(x, y + 0.1, z)

		if previous then
			debug_draw.DrawLine{
				id = LISTENER .. i,
				from = previous,
				to = point,
				color = color,
				width = 2,
				time = 0.1,
				ignore_z = true,
			}
		end

		previous = point
	end
end

local function update(dt)
	if not state.component then return end

	if not state.component:IsValid() then
		terrain_editor.SetEntity(nil)
		return
	end

	if state.tool == "none" then
		state.hit = nil
		return
	end

	if not state.stroke and is_ui_hovering() then
		state.hit = nil
		return
	end

	state.hit = find_hit()

	if not state.hit then return end

	draw_brush(state.hit)
	local stroke = state.stroke

	if not stroke then return end

	stroke.time = stroke.time + dt

	if state.kind == "terrain" then
		terrain_editor.ApplyTerrain(stroke, state.hit, dt)

		if stroke.time >= UPLOAD_INTERVAL then
			stroke.time = 0
			flush_terrain(stroke)
		end

		return
	end

	apply_scatter(stroke, state.hit, dt)

	if stroke.dirty and stroke.time >= UPLOAD_INTERVAL then
		stroke.time = 0
		stroke.dirty = false
		write_records(state.component, stroke.records)
	end
end

local function mouse_input(window, button, press)
	if button ~= "button_1" or not state.component then return end

	if not press then
		if not state.stroke then return end

		end_stroke()
		return true
	end

	if state.tool == "none" or not state.hit or is_ui_hovering() then return end

	if state.kind == "terrain" and not state.component:IsEditable() then return end

	begin_stroke()
	return true
end

local function slider_row(label, value, min, max, set, format)
	return Row{Key = label, layout = {GrowWidth = 1, ChildGap = "S", AlignmentY = "center"}}{
		Text{Text = string.format("%s " .. (format or "%.1f"), label, value), layout = {MinSize = Vec2(110, 0)}},
		Slider{
			Tooltip = label,
			Mode = "horizontal",
			Min = min,
			Max = max,
			Value = value,
			OnChange = set,
			layout = {MinSize = Vec2(160, 16), MaxSize = Vec2(0, 16), GrowWidth = 1, FitWidth = false},
		},
	}
end

local ToolWindow = react.Component(
	|props|-> do
		local _, set_version = react.UseState(0)
		react.UseEvent("TerrainEditorChanged", ||->set_version(|version|->version + 1))
		local editable = react.UsePoll(||->state.kind ~= "terrain" or state.component:IsEditable(), 0.2)
		react.UsePoll(||->state.kind == "scatter" and #state.component.Records .. state.component.Model or "", 0.2)
		local kind = state.kind

		if not kind then return nil end

		local function setter(key)
			return function(value)
				state[key] = value
				changed()
			end
		end

		local tools = {}

		for _, tool in ipairs(TOOLS[kind]) do
			tools[#tools + 1] = Button{
				Key = tool,
				Text = tool,
				Mode = "outline",
				Active = state.tool == tool,
				OnClick = ||->terrain_editor.SetTool(tool),
			}
		end

		local rows = {
			Row{Key = "tools", layout = {GrowWidth = 1, ChildGap = "XS", Wrap = true}}{tools},
			slider_row("radius", state.radius, 1, 64, setter("radius")),
			slider_row("strength", state.strength, 0.05, 1, setter("strength"), "%.2f"),
		}

		if kind == "terrain" then
			local layers = {}

			for i = 1, 4 do
				local name = state.component["Layer" .. i]

				if name ~= "" then
					layers[#layers + 1] = Button{
						Key = "layer" .. i,
						Text = i .. " " .. name,
						Mode = "outline",
						Active = state.layer == i,
						OnClick = ||-> do
							state.layer = i
							terrain_editor.SetTool("paint")
						end,
					}
				end
			end

			rows[#rows + 1] = Text{Key = "layers_label", Text = "paint layer"}
			rows[#rows + 1] = Row{Key = "layers", layout = {GrowWidth = 1, ChildGap = "XS", Wrap = true}}{layers}

			if not editable then
				rows[#rows + 1] = Text{Key = "readonly", Text = "this terrain's data is not in the scene, it can not be edited"}
			end
		else
			rows[#rows + 1] = slider_row("spacing", state.spacing, 0.25, 20, setter("spacing"))
			rows[#rows + 1] = slider_row("scale min", state.scale_min, 0.1, 3, setter("scale_min"), "%.2f")
			rows[#rows + 1] = slider_row("scale max", state.scale_max, 0.1, 3, setter("scale_max"), "%.2f")
			rows[#rows + 1] = slider_row("align", state.align, 0, 1, setter("align"), "%.2f")
			rows[#rows + 1] = Text{
				Key = "count",
				Text = math.floor(#state.component.Records / ScatterPlacements.RECORD_SIZE) .. " instances" .. (
						state.component.Model == "" and
						", pick a Model first" or
						""
					),
			}
		end

		return Window{
			Title = kind == "terrain" and "TERRAIN" or "SCATTER",
			Name = "terrain_editor",
			Size = Vec2(360, kind == "terrain" and 230 or 290),
			Position = Vec2(Panel.World.transform:GetSize().x - 380, 80),
			Padding = "S",
			OnClose = |self|-> do
				terrain_editor.SetTool("none")
				self:Remove()
			end,
		}{
			Column{layout = {GrowWidth = 1, ChildGap = "S", AlignmentX = "stretch"}}{rows},
		}
	end
)

function terrain_editor.SetTool(tool)
	state.tool = tool
	import("lua/gizmo.lua").SetHidden(tool ~= "none")
	changed()
end

function terrain_editor.SetEntity(entity)
	local component = entity and (entity.terrain or entity.scatter_placements) or nil

	if component == state.component then return end

	if state.stroke then end_stroke() end

	state.component = component
	state.kind = component and (component.Type == "terrain" and "terrain" or "scatter") or nil
	state.hit = nil

	if state.tool ~= "none" then
		state.tool = "none"
		import("lua/gizmo.lua").SetHidden(false)
	end

	if state.window and state.window:IsValid() then state.window:Remove() end

	state.window = component and react.OpenWindow("TerrainEditorWindow", ToolWindow, {}) or nil
	changed()
end

function terrain_editor.IsBusy()
	return state.stroke ~= nil or state.hit ~= nil
end

event.AddListener("Update", LISTENER, update)
event.AddListener("WindowMouseInput", LISTENER, mouse_input, {priority = 100})
return terrain_editor
