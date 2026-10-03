local T = import("test/environment.lua")
local render_helpers = import("test/tests/render/helpers.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local objects = import("goluwa/objects/objects.lua")

T.Test3D("GraphicsPipeline creates and caches variants based on static state", function()
	local pipeline = render_helpers.CreatePipeline()
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil)
	T(pipeline.current_variant_id)["=="](pipeline.base_variant_id)
	pipeline:SetPolygonMode("line")
	T(pipeline.current_variant_id)["=="](pipeline.base_variant_id)
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil)
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	T(pipeline.static_variant_dirty)["=="](true)
	T(pipeline.bind_state_dirty_regions ~= nil)["=="](false)
	pipeline:RebuildPipeline(pipeline.overridden_state)
	T(pipeline.current_variant_id)["~="](pipeline.base_variant_id)
	T(pipeline.pipeline_variants[pipeline.current_variant_id])["~="](nil)
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil)
	T(pipeline.static_variant_dirty)["=="](false)
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	T(pipeline.current_variant_id)["~="](pipeline.base_variant_id)
	T(pipeline.static_variant_dirty)["=="](false)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline caches variants with same static state but different dynamic state", function()
	local pipeline = render_helpers.CreatePipeline()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant1_id = pipeline.current_variant_id
	pipeline:SetPolygonMode("line")
	T(pipeline.current_variant_id)["=="](variant1_id)
	pipeline:SetCullMode("back")
	T(pipeline.current_variant_id)["=="](variant1_id)
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:SetPolygonMode("fill")
	pipeline:SetCullMode("front")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	T(pipeline.current_variant_id)["=="](variant1_id)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline variant ID is unique for different static state combinations", function()
	local pipeline = render_helpers.CreatePipeline()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_4 = pipeline.current_variant_id
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("8")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_8 = pipeline.current_variant_id
	T(variant_4)["~="](variant_8)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline input assembly static state creates unique variants", function()
	local pipeline = render_helpers.CreatePipeline()
	local base_id = pipeline.current_variant_id
	pipeline:SetTopology("triangle_strip")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_1 = pipeline.current_variant_id
	T(variant_1)["~="](base_id)
	pipeline:ResetToBase()
	pipeline:SetTopology("line_list")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_2 = pipeline.current_variant_id
	T(variant_2)["~="](base_id)
	T(variant_2)["~="](variant_1)
	pipeline:ResetToBase()
	pipeline:SetTopology("triangle_strip")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_3 = pipeline.current_variant_id
	T(variant_3)["~="](base_id)
	T(variant_3)["=="](variant_1)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline hash interner produces stable IDs", function()
	local pipeline = render_helpers.CreatePipeline()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local id1 = pipeline.current_variant_id
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local id2 = pipeline.current_variant_id
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local id3 = pipeline.current_variant_id
	T(id1)["=="](id2)
	T(id2)["=="](id3)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline GetStorableVariables derives all metadata", function()
	local prop_count = 0
	local with_state_section = 0
	local with_dynamic_state_name = 0

	for _, info in ipairs(objects.GetStorableVariables(GraphicsPipeline)) do
		prop_count = prop_count + 1

		if info.state_section and info.state_key then
			with_state_section = with_state_section + 1

			if info.dynamic_state_name then
				with_dynamic_state_name = with_dynamic_state_name + 1
			end
		end
	end

	T(prop_count)[">"](50)
	T(with_state_section)[">"](30)
	T(with_dynamic_state_name)[">"](0)
end)

T.Test3D("GraphicsPipeline Vulkan bindings are derived from GetSet properties", function()
	local bindings_count = 0

	for _, info in ipairs(objects.GetStorableVariables(GraphicsPipeline)) do
		if info.dynamic_state_name then bindings_count = bindings_count + 1 end
	end

	T(bindings_count)[">"](10)
end)
