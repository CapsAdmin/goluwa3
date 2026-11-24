local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local grade = import("goluwa/render3d/grade.lua")
local scopes = {}
scopes.MAX_COLUMNS = 1024
scopes.WAVEFORM_ROW_STRIDE = 2
scopes.LINGER = 0.5
pvars.StartGroup("Post", "Scopes", {prefix = "scope_"})
local columns_setting = pvars.Setup2{
	key = "r_scope_columns",
	default = "512",
	enums = {"128", "256", "512", "1024"},
	help = "columns of the histogram scope across the screen, it has half as many brightness levels",
}
pvars.EndGroup()
scopes.block = {
	{"waveform_columns", "int"},
	{"waveform_range", "float"},
}
local requested = -math.huge
local frame_active = false
local waveform_buffer
local cleared_columns

function scopes.RequestWaveform()
	requested = system.GetElapsedTime()
end

function scopes.IsWaveformActive()
	return frame_active
end

function scopes.GetRange()
	return grade.GetCurveDisplayRange()
end

function scopes.GetColumns()
	return tonumber(columns_setting:Get())
end

function scopes.SetColumns(columns)
	pvars.Set("r_scope_columns", tostring(columns))
end

function scopes.GetWaveformBuffer(cmd)
	if not waveform_buffer then
		waveform_buffer = render.CreateBuffer{
			byte_size = scopes.MAX_COLUMNS * scopes.MAX_COLUMNS / 2 * 3 * 4,
			buffer_usage = {"storage_buffer", "transfer_dst"},
			memory_property = {"device_local"},
			label = "scope_waveform",
		}
	end

	if cleared_columns ~= scopes.GetColumns() then
		cleared_columns = scopes.GetColumns()
		cmd:FillBuffer(waveform_buffer, 0, waveform_buffer:GetSize(), 0)
		cmd:PipelineBarrier{
			srcStage = {"transfer", "compute"},
			dstStage = "compute",
			bufferBarriers = {
				{
					buffer = waveform_buffer,
					srcAccessMask = {"transfer_write", "shader_write"},
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
	end

	return waveform_buffer
end

function scopes.WriteBlock(block)
	frame_active = system.GetElapsedTime() - requested < scopes.LINGER
	block.waveform_columns = frame_active and scopes.GetColumns() or 0
	block.waveform_range = scopes.GetRange()
	return block
end

function scopes.GetWaveformTexture()
	local render3d = import("goluwa/render3d/render3d.lua")
	local pipeline = render3d.pipelines.scope_waveform
	return pipeline and pipeline:GetFramebuffer():GetAttachment(1)
end

function scopes.GetGLSL(block_name, binding)
	return (
		string.format(
			[[
		layout(std430, set = 0, binding = %d) buffer ScopeWaveform {
			uint scope_waveform_counts[];
		};

		void scope_waveform(vec3 encoded, ivec2 pos, ivec2 size) {
			int columns = BLOCK.waveform_columns;

			if (columns == 0 || pos.y %% %d != 0) return;

			int levels = columns / 2;
			int column = clamp(pos.x * columns / size.x, 0, columns - 1);
			ivec3 level = clamp(ivec3(encoded / BLOCK.waveform_range * float(levels)), 0, levels - 1);
			ivec3 index = ((level * columns + column) * 3) + ivec3(0, 1, 2);
			atomicAdd(scope_waveform_counts[index.r], 1u);
			atomicAdd(scope_waveform_counts[index.g], 1u);
			atomicAdd(scope_waveform_counts[index.b], 1u);
		}
	]],
			binding,
			scopes.WAVEFORM_ROW_STRIDE
		):gsub("BLOCK", block_name)
	)
end

scopes.resolve_pass = {
	name = "scope_waveform",
	ComputePass = true,
	ColorFormat = {{"r16g16b16a16_sfloat", {"waveform", "rgba"}}},
	FramebufferSize = {x = scopes.MAX_COLUMNS, y = scopes.MAX_COLUMNS / 2},
	is_enabled = scopes.IsWaveformActive,
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {{binding_index = 0, attachment = 1, dst_stage = "fragment"}},
	storage_buffers = {{binding_index = 1}},
	block = {
		{"density", "float"},
		{"columns", "int"},
	},
	write = function(self, block)
		local size = render.GetRenderImageSize()
		block.columns = scopes.GetColumns()
		block.density = math.log(1 + size.x / block.columns * size.y / scopes.WAVEFORM_ROW_STRIDE)
		return block
	end,
	on_pre_draw = function(self, cmd, frame, desc)
		local buffer = scopes.GetWaveformBuffer(cmd)
		self:UpdateDescriptorSet("storage_buffer", desc, 1, 0, buffer, buffer:GetSize())
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		local buffer = scopes.GetWaveformBuffer(cmd)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "compute",
			bufferBarriers = {
				{
					buffer = buffer,
					srcAccessMask = "shader_write",
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, scopes.GetColumns(), scopes.GetColumns() / 2, 1, desc, self.dynamic_offsets)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "compute",
			bufferBarriers = {
				{
					buffer = buffer,
					srcAccessMask = "shader_write",
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
	end,
	custom_declarations = [[
		layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_waveform;
		layout(std430, set = 0, binding = 1) buffer ScopeWaveform {
			uint scope_waveform_counts[];
		};
	]],
	shader = [[
		void main() {
			ivec2 p = ivec2(gl_GlobalInvocationID.xy);
			int columns = compute.columns;

			if (p.x >= columns || p.y >= columns / 2) return;

			int index = (p.y * columns + p.x) * 3;
			vec3 counts = vec3(scope_waveform_counts[index], scope_waveform_counts[index + 1], scope_waveform_counts[index + 2]);
			scope_waveform_counts[index] = 0u;
			scope_waveform_counts[index + 1] = 0u;
			scope_waveform_counts[index + 2] = 0u;
			imageStore(out_waveform, p, vec4(clamp(log(1.0 + counts) / compute.density, 0.0, 1.0), 1.0));
		}
	]],
}
return scopes
