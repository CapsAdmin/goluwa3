local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local terrain_shadow = {}
terrain_shadow.textures = {}
terrain_shadow.field = nil
terrain_shadow.ready = false
terrain_shadow.sun = {0, 1, 0}
terrain_shadow.sun_version = 0

local function create_texture(size, usage, name)
	local texture = Texture.New{
		width = size,
		height = size,
		format = "r32_sfloat",
		image = {usage = usage},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture:SetDebugName("terrain shadow " .. name)
	return texture
end

function terrain_shadow.SetHeightField(heights, size, min_x, min_z, step, max_height, caster_radius)
	local t = terrain_shadow.textures

	if not t.size or t.size ~= size then
		if t.height then
			t.height:Remove()
			t.shadow:Remove()
		end

		t.height = create_texture(size, {"sampled", "transfer_dst"}, "heights")
		t.shadow = create_texture(size, {"storage", "sampled"}, "shadow")
		t.size = size
	end

	t.height:Upload(heights)
	terrain_shadow.field = {
		size = size,
		min_x = min_x,
		min_z = min_z,
		step = step,
		max_height = max_height,
		caster_radius = caster_radius,
	}
	terrain_shadow.dirty = true
end

function terrain_shadow.Clear()
	terrain_shadow.field = nil
	terrain_shadow.ready = false
end

function terrain_shadow.IsActive()
	return terrain_shadow.field ~= nil
end

function terrain_shadow.GetShadowBlockLayout()
	return {
		{"terrain_shadow_tex", "int"},
		{"terrain_shadow_field", "vec4"},
		{"terrain_shadow_params", "vec4"},
	}
end

function terrain_shadow.WriteShadowBlock(self, block)
	local field = terrain_shadow.field

	if not field or not terrain_shadow.ready then
		block.terrain_shadow_tex = -1
		return
	end

	block.terrain_shadow_tex = self:GetTextureIndex(terrain_shadow.textures.shadow)
	block.terrain_shadow_field[0] = field.min_x - field.step * 0.5
	block.terrain_shadow_field[1] = field.min_z - field.step * 0.5
	block.terrain_shadow_field[2] = 1 / (field.step * field.size)
	block.terrain_shadow_field[3] = 0
	block.terrain_shadow_params[0] = field.step * 0.1
	block.terrain_shadow_params[1] = field.step * 0.1
	block.terrain_shadow_params[2] = field.caster_radius
	block.terrain_shadow_params[3] = 0
end

function terrain_shadow.GetShadowGLSL(prefix)
	return [[
		#ifndef TERRAIN_SHADOW_GLSL
		#define TERRAIN_SHADOW_GLSL
		float get_terrain_shadow(vec3 world_pos) {
			if (]] .. prefix .. [[.terrain_shadow_tex < 0) return 1.0;

			vec2 uv = (world_pos.xz - ]] .. prefix .. [[.terrain_shadow_field.xy) * ]] .. prefix .. [[.terrain_shadow_field.z;
			vec2 edge = abs(uv - 0.5) * 2.0;
			float outside = smoothstep(0.9, 1.0, max(edge.x, edge.y));

			if (outside >= 1.0) return 1.0;

			float lowest_ray = textureLod(TEXTURE(]] .. prefix .. [[.terrain_shadow_tex), uv, 0.0).r;
			float margin = world_pos.y - lowest_ray;
			float lit = smoothstep(-]] .. prefix .. [[.terrain_shadow_params.y, ]] .. prefix .. [[.terrain_shadow_params.x, margin);
			return mix(lit, 1.0, outside);
		}
		#endif
	]]
end

return terrain_shadow
