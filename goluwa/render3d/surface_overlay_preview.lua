local ffi = require("ffi")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local preview = {}
preview.SIZE = 300
preview.MIN_SIZE = 16
preview.SHAPES = {"sphere", "box", "kleiner"}
preview.MODEL_PATH = "models/player/kleiner.mdl"
preview.PADDING = 1.1
preview.FOV = 50
preview.SCALE = 2
preview.LOOK_SENSITIVITY = 0.005
preview.FLY_SPEED = 1.5
preview.ZOOM_STEP = 0.5
local START_YAW = 0.6
local START_PITCH = -0.45
preview.EXPOSURE_GAIN_EV = 4
preview.EMISSIVE_SCALE = 1 / 40000
local MAIN = [[
	void main() {
		vec3 normal = normalize(in_normal);
		Surface s;
		default_surface_features(s);
		s.world_pos = in_position;
		s.V = normalize(preview_data.camera_position.xyz - in_position);
		s.N = normal;
		s.geometric_N = normal;
		float checker = mod(floor(in_uv.x * 8.0) + floor(in_uv.y * 8.0), 2.0);
		s.albedo = vec3(mix(0.5, 0.8, checker));
		s.metallic = 0.0;
		s.roughness_alpha = 0.16;
		s.ao = 1.0;

		OverlayContext c;
		c.P = in_effect_position;
		c.N = normalize(in_effect_normal);
		c.V = s.V;
		c.world_pos = in_position;
		c.center = preview_data.bounds.xyz;
		c.radius = max(preview_data.bounds.w, 1e-3);
		c.height = clamp((in_position.y - (c.center.y - c.radius)) / (c.radius * 2.0), 0.0, 1.0);
		c.ndv = abs(dot(s.N, c.V));

		OverlayLayer l;
		l.kind = KIND_INDEX;
		l.start = preview_data.start;
		l.duration = preview_data.duration;
		l.fade_in = preview_data.fade_in;
		l.fade_out = preview_data.fade_out;
		l.intensity = preview_data.intensity;
		l.scale = preview_data.scale;
		l.speed = preview_data.speed;
		l.daylight = preview_data.daylight;
		l.hold = preview_data.hold;
		l.color_a = preview_data.color_a;
		l.color_b = preview_data.color_b;
		l.params = preview_data.params;
		l.uv_space = 0;
		l.uv_scale = vec2(0.0);

		SurfaceWeather w = SurfaceWeather(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0);
		overlay_apply_layer(s, w, l, c, EXPOSURE_GAIN_EV, in_uv);

		vec3 light = normalize(preview_data.light_direction.xyz);
		vec3 half_vector = normalize(light + s.V);
		float alpha = max(s.roughness_alpha, 0.02);
		float specular = pow(max(dot(s.N, half_vector), 0.0), 2.0 / alpha - 2.0) * (1.0 - alpha) * 0.5;
		float diffuse = max(dot(s.N, light), 0.0) + 0.15 * (0.5 + 0.5 * s.N.y);
		vec3 f0 = mix(vec3(0.04), s.albedo, s.metallic);
		vec3 color = (s.albedo * (1.0 - s.metallic) * diffuse + f0 * specular) * s.ao + s.emissive * PREVIEW_EMISSIVE_SCALE;
		set_color(vec4(1.0 - exp(-color), 1.0));
	}
]]
local frame = {world = Matrix44()}
local pipelines = {}
local framebuffer
local framebuffer_width, framebuffer_height
local meshes = {}
local model_state = {}
local camera

local function write_block(self, block)
	local layer = frame.layer
	block.overlay_noise_tex = self:GetTextureIndex(frame.noise)
	block.overlay_exposure_tex = -1
	block.overlay_time = frame.time
	block.start = 0
	block.duration = 0
	block.fade_in = 0
	block.fade_out = 0
	block.intensity = 0
	block.scale = 1
	block.speed = 1
	block.daylight = 1
	block.hold = -1

	if layer then
		block.start = layer.start
		block.duration = layer.duration
		block.fade_in = layer.fade_in
		block.fade_out = layer.fade_out
		block.intensity = layer.intensity
		block.scale = layer.scale
		block.speed = layer.speed
		block.daylight = layer.daylight
		block.hold = layer.hold

		for i = 0, 3 do
			block.color_a[i] = layer.color_a[i]
			block.color_b[i] = layer.color_b[i]
			block.params[i] = layer.params[i]
		end
	end

	local position = frame.camera_position
	local light = frame.light
	block.camera_position[0], block.camera_position[1], block.camera_position[2] = position.x, position.y, position.z
	block.light_direction[0], block.light_direction[1], block.light_direction[2] = light.x, light.y, light.z
	local center = frame.center
	block.bounds[0], block.bounds[1], block.bounds[2], block.bounds[3] = center.x, center.y, center.z, frame.radius
	return block
end

local function draw_meshes(pipeline)
	local cmd = frame.cmd
	local material = render3d.GetMaterial()
	render3d.SetWorldMatrix(frame.world)

	for _, polygon in ipairs(frame.meshes) do
		render3d.SetCurrentPolygon3D(polygon)
		pipeline:UploadConstants()
		cmd:SetCullMode(material:GetCullMode())
		cmd:SetColorBlendEnable(0, false)
		polygon:Draw()
	end
end

local function create_pipeline(name)
	local glsl, index = surface_overlays.GetPreviewGLSL(name)
	local shader = "#define BLOCK preview_data\n" .. surface_features.GetSurfaceGLSL() .. surface_features.GetDefaultFunctionGLSL() .. glsl .. MAIN:gsub("KIND_INDEX", tostring(index)):gsub("EXPOSURE_GAIN_EV", string.format("%.1f", preview.EXPOSURE_GAIN_EV)):gsub("PREVIEW_EMISSIVE_SCALE", string.format("%.9f", preview.EMISSIVE_SCALE))
	return EasyPipeline.New{
		name = "surface_overlay_preview",
		dont_create_framebuffers = true,
		ColorFormat = {{"r8g8b8a8_srgb", {"color", "rgba"}}},
		DepthFormat = "d32_sfloat",
		RasterizationSamples = "1",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			instance_overlay = true,
			instance_overlay_expr = "1.0",
			effect_space = true,
		},
		fragment = {
			uniform_buffers = {
				{
					name = "preview_data",
					block = {
						{"overlay_noise_tex", "int"},
						{"overlay_exposure_tex", "int"},
						{"overlay_time", "float"},
						{"start", "float"},
						{"duration", "float"},
						{"fade_in", "float"},
						{"fade_out", "float"},
						{"intensity", "float"},
						{"scale", "float"},
						{"speed", "float"},
						{"daylight", "float"},
						{"hold", "float"},
						{"color_a", "vec4"},
						{"color_b", "vec4"},
						{"params", "vec4"},
						{"camera_position", "vec4"},
						{"light_direction", "vec4"},
						{"bounds", "vec4"},
					},
					write = write_block,
				},
			},
			shader = shader,
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "greater_or_equal",
		Blend = false,
		ColorWriteMask = "rgba",
		on_draw = draw_meshes,
	}
end

local function get_pipeline(name)
	local signature = surface_overlays.GetSignature(name)
	local entry = pipelines[name]

	if entry and entry.signature == signature then return entry.pipeline end

	local pipeline = create_pipeline(name)

	if entry then entry.pipeline:Remove() end

	pipelines[name] = {signature = signature, pipeline = pipeline}
	return pipeline
end

local function build_mesh(build)
	local polygon = Polygon3D.New()
	build(polygon)
	polygon:BuildBoundingBox()
	polygon:Upload()
	return {polygon}
end

local function load_model()
	if model_state.loading or model_state.meshes or model_state.error then return end

	model_state.loading = true

	model_loader.LoadModel(
		preview.MODEL_PATH,
		function(data)
			local out = {}

			for _, entry in ipairs(data) do
				local polygon = entry.mesh

				if (polygon.LODLevel or 0) == 0 then
					if not polygon.mesh then polygon:Upload() end

					out[#out + 1] = polygon
				end
			end

			model_state.loading = nil
			model_state.meshes = out
		end,
		nil,
		function(message)
			model_state.loading = nil
			model_state.error = message
		end
	)
end

function preview.GetMeshes(shape)
	if shape == "sphere" then
		meshes.sphere = meshes.sphere or
			build_mesh(function(polygon)
				shapes.BuildSphere(polygon, 0.5, 48, 32, 1)
			end)
		return meshes.sphere
	elseif shape == "box" then
		meshes.box = meshes.box or
			build_mesh(function(polygon)
				shapes.BuildCube(polygon, 1, 1, 4)
			end)
		return meshes.box
	end

	load_model()
	return model_state.meshes
end

function preview.GetShapeStatus(shape)
	if shape ~= "kleiner" then return end

	if model_state.error then
		return "could not load " .. preview.MODEL_PATH .. ": " .. model_state.error
	end

	if not model_state.meshes then return "loading " .. preview.MODEL_PATH end
end

local fit_cache = setmetatable({}, {__mode = "k"})

local function get_fit(polygons)
	local fit = fit_cache[polygons]

	if fit then return fit end

	local min_x, min_y, min_z, max_x, max_y, max_z = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge

	for _, polygon in ipairs(polygons) do
		local aabb = polygon.AABB
		min_x, min_y, min_z = math.min(min_x, aabb.min_x), math.min(min_y, aabb.min_y), math.min(min_z, aabb.min_z)
		max_x, max_y, max_z = math.max(max_x, aabb.max_x), math.max(max_y, aabb.max_y), math.max(max_z, aabb.max_z)
	end

	local center = Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2)
	local radius_squared = 0
	local has_vertices = false

	for _, polygon in ipairs(polygons) do
		for _, vertex in ipairs(polygon.Vertices) do
			has_vertices = true
			radius_squared = math.max(radius_squared, (vertex.pos - center):GetLengthSquared())
		end
	end

	if not has_vertices then
		radius_squared = ((max_x - min_x) ^ 2 + (max_y - min_y) ^ 2 + (max_z - min_z) ^ 2) / 4
	end

	fit = {center = center, radius = math.sqrt(radius_squared)}
	fit_cache[polygons] = fit
	return fit
end

local view = {position = Vec3(), yaw = START_YAW, pitch = START_PITCH}
local view_polygons
local rotation = Quat()

local function update_rotation()
	rotation:Identity()
	rotation:RotateYaw(view.yaw)
	rotation:RotatePitch(view.pitch)
end

local function reset_view(fit)
	view.yaw, view.pitch = START_YAW, START_PITCH
	update_rotation()
	view.position = fit.center - rotation:GetForward() * (
			fit.radius / math.sin(math.rad(preview.FOV) / 2) * preview.PADDING
		)
end

function preview.GetView()
	return view.position, view.yaw, view.pitch
end

function preview.Look(dx, dy)
	view.yaw = view.yaw - dx * preview.LOOK_SENSITIVITY
	view.pitch = math.clamp(view.pitch - dy * preview.LOOK_SENSITIVITY, -1.5, 1.5)
end

function preview.Move(forward, right, up, seconds)
	local fit = view_polygons and get_fit(view_polygons)

	if not fit then return end

	update_rotation()
	local step = fit.radius * preview.FLY_SPEED * seconds
	view.position = view.position + (
			rotation:GetForward() * forward + rotation:GetRight() * right + Vec3(0, up, 0)
		) * step
end

function preview.Zoom(steps)
	local fit = view_polygons and get_fit(view_polygons)

	if not fit then return end

	update_rotation()
	view.position = view.position + rotation:GetForward() * (steps * fit.radius * preview.ZOOM_STEP)
end

local function configure_camera(polygons, width, height)
	local fit = get_fit(polygons)

	if view_polygons ~= polygons then
		view_polygons = polygons
		reset_view(fit)
	end

	update_rotation()
	camera = camera or Camera3D.New()
	camera:SetViewport(Rect(0, 0, width, height))
	camera:SetOrthoMode(false)
	camera:SetFOV(math.rad(preview.FOV))
	camera:SetNearZ(fit.radius * 0.02)
	camera:SetFarZ(fit.radius * 100)
	camera:SetPosition(view.position)
	camera:SetRotation(rotation)
	return fit, rotation:GetForward(), rotation:GetRight()
end

local function draw_frame()
	render3d.PushCamera(camera)
	frame.pushed = true
	frame.pipeline:Draw(frame.cmd, framebuffer)
end

function preview.Render(width, height, shape, name, layer, time)
	local polygons = preview.GetMeshes(shape) or preview.GetMeshes("sphere")
	width, height = width * preview.SCALE, height * preview.SCALE

	if not framebuffer or framebuffer_width ~= width or framebuffer_height ~= height then
		if framebuffer then framebuffer:Remove() end

		framebuffer = Framebuffer.New{
			width = width,
			height = height,
			format = "r8g8b8a8_srgb",
			depth = true,
			depth_clear = 0.0,
			clear_color = {0.012, 0.015, 0.025, 1},
		}
		framebuffer_width, framebuffer_height = width, height
	end

	local pipeline = get_pipeline(name)
	frame.cmd = framebuffer:GetCommandBuffer()
	local fit, forward, right = configure_camera(polygons, width, height)
	frame.meshes = polygons
	frame.layer = layer
	frame.time = time
	frame.noise = surface_conditions.GetNoiseTexture()
	frame.center = fit.center
	frame.radius = fit.radius
	frame.camera_position = view.position
	frame.light = (Vec3(0, 0.6, 0) + right * 0.5 - forward):GetNormalized()
	frame.pipeline = pipeline
	frame.pushed = false
	local previous_world = render3d.GetWorldMatrix()
	local previous_material = render3d.GetMaterial()
	local ok, err = xpcall(draw_frame, debug.traceback)

	if frame.pushed then render3d.PopCamera() end

	render3d.SetWorldMatrix(previous_world)
	render3d.SetCurrentPolygon3D(nil)
	render3d.SetMaterial(previous_material)
	frame.meshes = nil

	if not ok then error(err, 0) end

	return framebuffer:GetColorTexture()
end

function preview.Check(name)
	local ok, err = pcall(get_pipeline, name)

	if not ok then return surface_overlays.ParseError(tostring(err)) end
end

return preview
