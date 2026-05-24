local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")

local function get_scene_source_texture(self, block, key)
	post_source.WriteSceneSourceTexture(self, block, key)
end

local function write_down_constants(self, block, pipeline_name)
	if not render3d.pipelines[pipeline_name] then
		block.source_tex = -1
		return block
	end

	block.source_tex = self:GetTextureIndex(render3d.pipelines[pipeline_name]:GetFramebuffer():GetAttachment(1))
	return block
end

local function write_up_constants(self, block, source_name, merge_name)
	if not render3d.pipelines[source_name] then
		block.source_tex = -1
	else
		block.source_tex = self:GetTextureIndex(render3d.pipelines[source_name]:GetFramebuffer():GetAttachment(1))
	end

	if not render3d.pipelines[merge_name] then
		block.merge_tex = -1
	else
		block.merge_tex = self:GetTextureIndex(render3d.pipelines[merge_name]:GetFramebuffer():GetAttachment(1))
	end

	return block
end

local r = {
	{
		name = "bloom_extract",
		ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
		scale = 0.5,
		fragment = {
			push_constants = {
				{
					name = "extract",
					block = {
						{"source_tex", "int"},
					},
					write = function(self, block)
						get_scene_source_texture(self, block, "source_tex")
						return block
					end,
				},
			},
			shader = [[
				void main() {
					if (extract.source_tex == -1) {
						set_bloom(vec4(0.0));
						return;
					}

					vec3 col = texture(TEXTURE(extract.source_tex), in_uv).rgb;

					float threshold = 1.25;
					float knee = 0.75;
					float brightness = dot(col, vec3(0.2126, 0.7152, 0.0722));
					float soft = brightness - threshold + knee;
					soft = clamp(soft, 0.0, 2.0 * knee);
					soft = soft * soft / (4.0 * knee + 0.00001);
					float contribution = max(soft, brightness - threshold);
					contribution /= max(brightness, 0.00001);

					set_bloom(vec4(col * contribution, 1.0));
				}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
local downsample_shader = [[
	void main() {
		if (down.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}

		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(down.source_tex), 0));
		vec3 sum = vec3(0.0);

		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(0, -2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, -2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(-2, 2) * texel_size).rgb;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(0, 2) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(down.source_tex), in_uv + vec2(2, 2) * texel_size).rgb;

		set_bloom(vec4(sum / 16.0, 1.0));
	}
]]

for i = 1, 3 do
	local prev_name = i == 1 and "bloom_extract" or ("bloom_down" .. (i - 1))
	table.insert(
		r,
		{
			name = "bloom_down" .. i,
			ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "down",
						block = {
							{"source_tex", "int"},
						},
						write = function(self, block)
							return write_down_constants(self, block, prev_name)
						end,
					},
				},
				shader = downsample_shader,
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

local upsample_merge_strength = 0.65
local upsample_shader = string.format(
	[[
	void main() {
		if (up.source_tex == -1) {
			set_bloom(vec4(0.0));
			return;
		}

		vec2 texel_size = 1.0 / vec2(textureSize(TEXTURE(up.source_tex), 0));
		vec3 sum = vec3(0.0);

		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(0, -1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, -1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv).rgb * 4.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, 0) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(-1, 1) * texel_size).rgb;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(0, 1) * texel_size).rgb * 2.0;
		sum += texture(TEXTURE(up.source_tex), in_uv + vec2(1, 1) * texel_size).rgb;

		vec3 result = sum / 16.0;

		if (up.merge_tex != -1) {
			result += texture(TEXTURE(up.merge_tex), in_uv).rgb * %.3f;
		}

		set_bloom(vec4(result, 1.0));
	}
	]],
	upsample_merge_strength
)

for i = 3, 1, -1 do
	local source_name = i == 3 and "bloom_down3" or ("bloom_up" .. (i + 1))
	local merge_name = i == 1 and "bloom_extract" or ("bloom_down" .. i)
	local idx = i == 1 and 0 or i
	table.insert(
		r,
		{
			name = "bloom_up" .. idx,
			ColorFormat = {{"r16g16b16a16_sfloat", {"bloom", "rgba"}}},
			scale = 0.5 / (2 ^ i),
			fragment = {
				push_constants = {
					{
						name = "up",
						block = {
							{"source_tex", "int"},
							{"merge_tex", "int"},
						},
						write = function(self, block)
							return write_up_constants(self, block, source_name, merge_name)
						end,
					},
				},
				shader = upsample_shader,
			},
			CullMode = "none",
			DepthTest = false,
			DepthWrite = false,
		}
	)
end

return r
