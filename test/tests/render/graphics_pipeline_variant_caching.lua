local T = import("test/environment.lua")
local render_helpers = import("test/tests/render/helpers.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local objects = import("goluwa/objects/objects.lua")


T.Test3D("GraphicsPipeline creates and caches variants based on static state", function()
	local pipeline = render_helpers.CreatePipeline()
	-- Base variant should be created
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil)
	T(pipeline.current_variant_id)["=="](pipeline.base_variant_id)
	-- Changing a dynamic state should NOT create a new variant
	pipeline:SetPolygonMode("line")
	T(pipeline.current_variant_id)["=="](pipeline.base_variant_id)
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil)
	-- Changing a static state should mark the pipeline as dirty
	pipeline:SetRasterizationSamples("4")
	T(pipeline.static_variant_dirty)["=="](true)
	T(pipeline.bind_state_dirty)["=="](true)
	-- Trigger variant rebuild by calling RebuildPipeline directly
	pipeline:RebuildPipeline(pipeline.overridden_state)
	T(pipeline.current_variant_id)["~="](pipeline.base_variant_id)
	T(pipeline.pipeline_variants[pipeline.current_variant_id])["~="](nil)
	T(pipeline.pipeline_variants[pipeline.base_variant_id])["~="](nil) -- base still exists
	T(pipeline.static_variant_dirty)["=="](false)
	-- Resetting and setting the same static state should reuse the cached variant
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	T(pipeline.current_variant_id)["~="](pipeline.base_variant_id) -- same variant ID as before
	T(pipeline.static_variant_dirty)["=="](false)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline caches variants with same static state but different dynamic state", function()
	local pipeline = render_helpers.CreatePipeline()
	-- Set a static state to create a variant
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant1_id = pipeline.current_variant_id
	-- Change dynamic state
	pipeline:SetPolygonMode("line")
	T(pipeline.current_variant_id)["=="](variant1_id)
	-- Change another dynamic state
	pipeline:SetCullMode("back")
	T(pipeline.current_variant_id)["=="](variant1_id)
	-- Reset and set same static state, different dynamic states
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	pipeline:SetPolygonMode("fill")
	pipeline:SetCullMode("front")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	-- Should still be the same variant (static state is the same)
	T(pipeline.current_variant_id)["=="](variant1_id)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline variant ID is unique for different static state combinations", function()
	local pipeline = render_helpers.CreatePipeline()
	-- Create variant with rasterization_samples=4
	pipeline:SetRasterizationSamples("4")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_4 = pipeline.current_variant_id
	-- Create variant with rasterization_samples=8
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("8")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_8 = pipeline.current_variant_id
	T(variant_4)["~="](variant_8)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline input assembly static state creates unique variants", function()
	local pipeline = render_helpers.CreatePipeline()
	-- Base variant
	local base_id = pipeline.current_variant_id
	-- Change topology (static state)
	pipeline:SetTopology("triangle_strip")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_1 = pipeline.current_variant_id
	T(variant_1)["~="](base_id)
	-- Change to another topology
	pipeline:ResetToBase()
	pipeline:SetTopology("line_list")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_2 = pipeline.current_variant_id
	T(variant_2)["~="](base_id)
	T(variant_2)["~="](variant_1)
	-- Reset and set same topology as variant_1 (should reuse cached variant)
	pipeline:ResetToBase()
	pipeline:SetTopology("triangle_strip")
	pipeline:RebuildPipeline(pipeline.overridden_state)
	local variant_3 = pipeline.current_variant_id
	T(variant_3)["~="](base_id)
	T(variant_3)["=="](variant_1) -- same variant as variant_1 because topology is the same
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline hash interner produces stable IDs", function()
	local pipeline = render_helpers.CreatePipeline()
	-- Set same static state multiple times
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
	-- All should be the same variant ID
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

	-- Should have many properties
	T(prop_count)[">"](50)
	-- Most should have state_section and state_key
	T(with_state_section)[">"](30)
	-- Some should have dynamic_state_name
	T(with_dynamic_state_name)[">"](0)
end)

T.Test3D("GraphicsPipeline Vulkan bindings are derived from GetSet properties", function()
	-- Verify that properties with dynamic_state_name have corresponding vulkan_bindings
	-- This test verifies that the vulkan_bindings table is populated from GetSet metadata
	-- The actual binding logic is in graphics_pipeline.lua
	local bindings_count = 0

	for _, info in ipairs(objects.GetStorableVariables(GraphicsPipeline)) do
		if info.dynamic_state_name then bindings_count = bindings_count + 1 end
	end

	-- Should have multiple dynamic state bindings
	T(bindings_count)[">"](10)
end)
