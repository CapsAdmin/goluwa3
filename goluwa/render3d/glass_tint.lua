local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local glass_tint = library()
-- What the sun's light is left with after the glass it passes through. A pane
-- dithers the shadow maps by its colour multiplier alone, a grey shadow without
-- the albedo texture, and the probe rays would hit it as a solid. So while this
-- is on, glass casts nothing in the shadow maps (Material.GlassCastsShadow) and
-- is drawn from the sun into maps of its own instead: what the face of it
-- nearest the sun lets through, and how far from the sun that is. A surface
-- behind that depth gets the sun's light multiplied by it, in colour when it is
-- tinted (r_glass_tint).
-- There is a map per shadow cascade and one for the inset, drawn with the
-- cascade's own light space matrix so it lines up with its shadow map, and
-- one fitted to all the glass in the scene, which the probes' shade pass takes
-- the sun's light through glass from. With r_glass_sun on their sun rays go
-- through glass at all.
-- It covers the sun only, and a surface between two panes is not lit through them.
glass_tint.SIZE = 1024
-- slot 0 is the map of all the glass, 1 to 4 the cascades, 5 the inset
glass_tint.SLOT_NAMES = {
	[0] = "glass_tint",
	"glass_tint_c1",
	"glass_tint_c2",
	"glass_tint_c3",
	"glass_tint_c4",
	"glass_tint_inset",
}
local INSET_SLOT = 5
pvars.StartGroup("glass_tint", {store = false})
local tinted = pvars.Setup2{
	key = "r_glass_tint",
	default = false,
	friendly = "glass light tint",
	help = "the sun's light takes on the colour of the glass it passes through",
}
local through = pvars.Setup2{
	key = "r_glass_sun",
	default = true,
	friendly = "sun through glass",
	help = "the sun goes through glass, to the gi probes and by the albedo of the glass instead of the shadow maps' dither",
}
pvars.EndGroup()
glass_tint.block = {
	{"glass_tint_matrix", "mat4"},
	{"glass_tint_tex", "int"},
	{"glass_tint_depth_tex", "int"},
	{"glass_tint_bias", "float"},
	{"glass_tint_hue", "float"},
}
glass_tint.cascade_block = {
	{"glass_tint_cascade_tex", "int", 4},
	{"glass_tint_cascade_depth_tex", "int", 4},
	{"glass_tint_inset_tex", "int"},
	{"glass_tint_inset_depth_tex", "int"},
	{"glass_tint_hue", "float"},
	{"glass_tint_active", "float"},
}
local state = {
	active = false,
	view = Matrix44(),
	projection = Matrix44(),
	light_space = Matrix44(),
	bias = 0,
	draw_count = 0,
	size_x = 0,
	size_y = 0,
	size_z = 0,
}
-- per slot, what is drawn into it this frame and with which matrix
local slot_draws = {}
local slot_matrices = {}
glass_tint.draws = {}

-- whether the maps are drawn at all, which takes a renderer that has the passes
function glass_tint.IsEnabled()
	-- materials are made before the renderer is
	return (
			tinted:Get() or
			through:Get()
		) and
		render3d.pipelines ~= nil and
		render3d.IsPassEnabled("glass_tint")
end

function glass_tint.IsTinted()
	return tinted:Get()
end

-- whether the probes' sun rays go through glass
function glass_tint.IsSunThrough()
	return glass_tint.IsEnabled()
end

function glass_tint.IsActive()
	return state.active
end

Material.GlassCastsShadow = function()
	return not glass_tint.IsEnabled()
end

-- the world space corners of the aabb of each draw, flat
local function build_corners(draws)
	for _, draw in ipairs(draws) do
		local aabb = draw.entry.source_aabb
		local corners = {}

		for i = 0, 7 do
			local x, y, z = draw.world_matrix:TransformVectorUnpacked(
				i % 2 == 0 and aabb.min_x or aabb.max_x,
				math.floor(i / 2) % 2 == 0 and aabb.min_y or aabb.max_y,
				i < 4 and aabb.min_z or aabb.max_z
			)
			corners[i * 3 + 1], corners[i * 3 + 2], corners[i * 3 + 3] = x, y, z
		end

		draw.corners = corners
	end
end

-- fits the map of all the glass to draws, from the sun
local function fit_all(draws)
	state.active = false

	if #draws == 0 then return false end

	local sun = directional_shadows.GetPrimarySun(render3d.GetLights())

	if not sun then return false end

	local rotation = sun.Owner.transform:GetRotation()
	local world_to_light = rotation:GetConjugated():GetMatrix()
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, draw in ipairs(draws) do
		local corners = draw.corners

		for i = 0, 7 do
			local x, y, z = world_to_light:TransformVectorUnpacked(corners[i * 3 + 1], corners[i * 3 + 2], corners[i * 3 + 3])
			min_x, max_x = math.min(min_x, x), math.max(max_x, x)
			min_y, max_y = math.min(min_y, y), math.max(max_y, y)
			min_z, max_z = math.min(min_z, z), math.max(max_z, z)
		end
	end

	-- the light looks down -z, see ShadowMap:UpdateCascadeLightMatrices. the
	-- y flip of Ortho leaves the offset alone, so the box is centred
	local pad = 0.25
	local center = rotation:GetMatrix():TransformVector(Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2))
	local half_x, half_y, half_z = (max_x - min_x) / 2 + pad, (max_y - min_y) / 2 + pad, (max_z - min_z) / 2 + 1
	state.view = Matrix44()
	state.view:Translate(-center.x, -center.y, -center.z)
	state.view:Multiply(world_to_light)
	state.projection = Matrix44()
	state.projection:Ortho(-half_x, half_x, -half_y, half_y, -half_z, half_z, true)
	state.light_space = state.view * state.projection
	state.bias = 0.05 / (half_z * 2)
	state.draw_count = #draws
	state.size_x, state.size_y, state.size_z = half_x * 2, half_y * 2, half_z * 2
	state.active = true
	return true
end

-- the draws a cascade's matrix can see
local function cull(matrix, draws)
	local visible = {}

	for _, draw in ipairs(draws) do
		local corners = draw.corners
		local min_x, max_x = math.huge, -math.huge
		local min_y, max_y = math.huge, -math.huge

		for i = 0, 7 do
			local x, y = matrix:TransformVectorUnpacked(corners[i * 3 + 1], corners[i * 3 + 2], corners[i * 3 + 3])
			min_x, max_x = math.min(min_x, x), math.max(max_x, x)
			min_y, max_y = math.min(min_y, y), math.max(max_y, y)
		end

		if not (max_x < -1 or min_x > 1 or max_y < -1 or min_y > 1) then
			visible[#visible + 1] = draw
		end
	end

	return visible
end

-- the slots the sun's shadow maps fill in the shadow block, in its order, see
-- directional_shadows.WriteFogShadowBlock
local function fit_cascades(draws)
	local sun = directional_shadows.GetPrimarySun(render3d.GetLights())

	if not sun then return end

	local slot = 1

	for _, shadow_map in ipairs(ShadowMap.GetActiveMaps()) do
		if shadow_map.enabled and shadow_map.light == sun.Owner then
			if shadow_map.role == "inset" then
				slot_matrices[INSET_SLOT] = shadow_map:GetLightSpaceMatrix(1)
				slot_draws[INSET_SLOT] = cull(slot_matrices[INSET_SLOT], draws)
			else
				for i = 1, shadow_map:GetCascadeCount() do
					if slot > 4 then break end

					slot_matrices[slot] = shadow_map:GetLightSpaceMatrix(i)
					slot_draws[slot] = cull(slot_matrices[slot], draws)
					slot = slot + 1
				end
			end
		end
	end
end

-- collects the glass, and fits every map to it, once a frame
do
	local frame = -1
	local was_enabled = nil

	function glass_tint.Prepare()
		local current = system.GetFrameNumber()

		if frame ~= current then
			frame = current
			local enabled = glass_tint.IsEnabled()

			-- the shadow maps expand the soup again, and glass takes or gives up its shadow
			if was_enabled ~= enabled then
				was_enabled = enabled
				Material.shadow_generation = Material.shadow_generation + 1
				Material.shadow_full_generation = Material.shadow_full_generation + 1
			end

			local draws = {}
			slot_draws = {}
			slot_matrices = {}
			state.active = false

			if enabled then
				event.Call("CollectGlassTint", draws)
				build_corners(draws)

				if fit_all(draws) then
					slot_draws[0] = draws
					slot_matrices[0] = state.light_space
					fit_cascades(draws)
				end
			end

			glass_tint.draws = draws
		end

		return state.active
	end
end

-- whether a slot has glass to draw this frame
function glass_tint.PrepareSlot(slot)
	glass_tint.Prepare()
	return slot_draws[slot] ~= nil and #slot_draws[slot] > 0
end

function glass_tint.GetSlotDraws(slot)
	return slot_draws[slot]
end

do
	local current_matrix = state.light_space
	local pvw = Matrix44()

	function glass_tint.SetDrawMatrix(matrix)
		current_matrix = matrix
	end

	-- what the glass is drawn through, world * the map's light space matrix
	function glass_tint.GetProjectionViewWorldMatrix()
		render3d.GetWorldMatrix():GetMultiplied(current_matrix, pvw)
		return pvw
	end

	function glass_tint.GetSlotMatrix(slot)
		return slot_matrices[slot]
	end
end

commands.Add("glass_tint_info", function()
	local slots = {}

	for slot = 1, INSET_SLOT do
		slots[#slots + 1] = slot_draws[slot] and tostring(#slot_draws[slot]) or "-"
	end

	logf(
		"glass tint: %s, %d glass entries, map %.1f x %.1f m deep %.1f m, a texel is %.3f x %.3f m; entries per cascade and inset: %s\n",
		state.active and
			"active" or
			(
				glass_tint.IsEnabled() and
				"on, no glass or no sun" or
				"off"
			),
		state.draw_count,
		state.size_x,
		state.size_y,
		state.size_z,
		state.size_x / glass_tint.SIZE,
		state.size_y / glass_tint.SIZE,
		table.concat(slots, " ")
	)
end)

-- the pass' camera block, which the glass is not drawn through, see
-- GetProjectionViewWorldMatrix
local identity = Matrix44()

function glass_tint.WriteCameraBlock(self, block)
	identity:CopyToFloatPointer(block.inv_view)
	identity:CopyToFloatPointer(block.inv_projection)
	identity:CopyToFloatPointer(block.view)
	identity:CopyToFloatPointer(block.projection)
	block.render_size[0] = glass_tint.SIZE
	block.render_size[1] = glass_tint.SIZE
	block.camera_position[0] = 0
	block.camera_position[1] = 0
	block.camera_position[2] = 0
	return block
end

-- the map of all the glass, for the probes
function glass_tint.WriteBlock(self, block)
	if not state.active or not render3d.IsPassEnabled("glass_tint") then
		block.glass_tint_tex = -1
		block.glass_tint_depth_tex = -1
		return block
	end

	local framebuffer = render3d.pipelines.glass_tint:GetFramebuffer()
	block.glass_tint_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
	block.glass_tint_depth_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
	state.light_space:CopyToFloatPointer(block.glass_tint_matrix)
	block.glass_tint_bias = state.bias
	block.glass_tint_hue = tinted:Get() and 1 or 0
	return block
end

-- the cascade maps, a slot with no glass in it is -1
function glass_tint.WriteCascadeBlock(self, block)
	local any = 0
	block.glass_tint_inset_tex = -1
	block.glass_tint_inset_depth_tex = -1

	for slot = 1, 4 do
		block.glass_tint_cascade_tex[slot - 1] = -1
		block.glass_tint_cascade_depth_tex[slot - 1] = -1
	end

	if state.active then
		for slot = 1, INSET_SLOT do
			local draws = slot_draws[slot]

			if draws and #draws > 0 then
				local framebuffer = render3d.pipelines[glass_tint.SLOT_NAMES[slot]]:GetFramebuffer()
				local tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
				local depth = self:GetTextureIndex(framebuffer:GetAttachment(2))
				any = 1

				if slot == INSET_SLOT then
					block.glass_tint_inset_tex = tex
					block.glass_tint_inset_depth_tex = depth
				else
					block.glass_tint_cascade_tex[slot - 1] = tex
					block.glass_tint_cascade_depth_tex[slot - 1] = depth
				end
			end
		end
	end

	block.glass_tint_active = any
	block.glass_tint_hue = tinted:Get() and 1 or 0
	return block
end

-- the light that gets through, in colour only when the glass is tinted
local function glass_light_glsl(block_name)
	return [[
		vec3 glass_light(vec3 transmitted) {
			return mix(vec3(dot(transmitted, vec3(0.2126, 0.7152, 0.0722))), transmitted, ]] .. block_name .. [[.glass_tint_hue);
		}
	]]
end

-- the probes' side, needs the block to hold glass_tint.block
function glass_tint.GetGLSL(block_name)
	return glass_light_glsl(block_name) .. [[
		// what the sun's light is multiplied by at world_pos after the glass in
		// front of it
		vec3 get_glass_transmittance(vec3 world_pos) {
			if (]] .. block_name .. [[.glass_tint_tex < 0) return vec3(1.0);

			vec4 light_space = ]] .. block_name .. [[.glass_tint_matrix * vec4(world_pos, 1.0);
			vec3 coords = light_space.xyz / light_space.w;
			vec2 uv = coords.xy * 0.5 + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(1.0);

			ivec2 texel = ivec2(uv * vec2(textureSize(TEXTURE(]] .. block_name .. [[.glass_tint_depth_tex), 0)));
			float glass_depth = texelFetch(TEXTURE(]] .. block_name .. [[.glass_tint_depth_tex), texel, 0).r;

			if (coords.z <= glass_depth + ]] .. block_name .. [[.glass_tint_bias) return vec3(1.0);

			return glass_light(texelFetch(TEXTURE(]] .. block_name .. [[.glass_tint_tex), texel, 0).rgb);
		}
	]]
end

-- the lit surfaces' side, needs the block to hold glass_tint.cascade_block and
-- the shadow block, and getCascadeIndex
function glass_tint.GetCascadeGLSL(block_name)
	return glass_light_glsl(block_name) .. [[
		// a = -1 when the cascade's map does not cover the point. rgb is what the
		// glass in front of it lets through. the map is coarser than the shadow
		// map, so where its glass ends a texel is only part covered, and blending
		// in the light of the texels beside it would leave a bright, stair stepped
		// fringe along the shadows of the frames. it takes the most absorbing of
		// the texel and the two rings around it instead, which the shadow map's own
		// edges mostly cover
		vec4 glass_cascade_sample(int tint_tex, int depth_tex, mat4 light_space, vec3 world_pos) {
			vec4 clip = light_space * vec4(world_pos, 1.0);
			vec3 coords = clip.xyz / clip.w;
			vec2 uv = coords.xy * 0.5 + 0.5;

			if (any(lessThan(uv, vec2(0.002))) || any(greaterThan(uv, vec2(0.998)))) return vec4(0.0, 0.0, 0.0, -1.0);

			if (tint_tex < 0) return vec4(1.0);

			ivec2 size = textureSize(TEXTURE(depth_tex), 0);
			ivec2 center = ivec2(floor(uv * vec2(size)));
			float bias = 0.05 * length(vec3(light_space[0].z, light_space[1].z, light_space[2].z));
			vec3 transmitted = vec3(1.0);

			for (int i = 0; i < 25; i++) {
				ivec2 texel = clamp(center + ivec2(i % 5 - 2, i / 5 - 2), ivec2(0), size - 1);
				float glass_depth = texelFetch(TEXTURE(depth_tex), texel, 0).r;

				if (coords.z > glass_depth + bias) {
					transmitted = min(transmitted, texelFetch(TEXTURE(tint_tex), texel, 0).rgb);
				}
			}

			return vec4(transmitted, 1.0);
		}

		// what the sun's light is multiplied by at world_pos after the glass in
		// front of it, from the map of the cascade the shadow lookup would use
		vec3 get_glass_tint(vec3 world_pos) {
			if (]] .. block_name .. [[.shadows.cascade_count <= 0) return vec3(1.0);

			float dist = -(]] .. block_name .. [[.view * vec4(world_pos, 1.0)).z;

			if (]] .. block_name .. [[.shadows.inset_shadow_map_index >= 0 && dist < ]] .. block_name .. [[.shadows.inset_shadow_distance) {
				vec4 inset = glass_cascade_sample(]] .. block_name .. [[.glass_tint_inset_tex, ]] .. block_name .. [[.glass_tint_inset_depth_tex, ]] .. block_name .. [[.shadows.inset_light_space_matrix, world_pos);

				if (inset.a >= 0.0) return glass_light(inset.rgb);
			}

			for (int i = getCascadeIndex(world_pos); i < ]] .. block_name .. [[.shadows.cascade_count; i++) {
				vec4 cascade = glass_cascade_sample(]] .. block_name .. [[.glass_tint_cascade_tex[i], ]] .. block_name .. [[.glass_tint_cascade_depth_tex[i], ]] .. block_name .. [[.shadows.light_space_matrices[i], world_pos);

				if (cascade.a >= 0.0) return glass_light(cascade.rgb);
			}

			return vec3(1.0);
		}
	]]
end

return glass_tint
