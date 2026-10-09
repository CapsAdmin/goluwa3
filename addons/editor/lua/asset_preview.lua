local assets = import("goluwa/assets.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local previews = library()
previews.RENDER_SIZE = 192
previews.MAX_RENDERED = 360
previews.TEXTURE_BYTES = 256 * 1024 * 1024
previews.MAX_LOADING = 6
previews.STARTS_PER_FRAME = 2
previews.RENDERS_PER_FRAME = 2
previews.TIMEOUT = 15
previews.frame = previews.frame or 0
previews.private_serial = previews.private_serial or 0
local wanted = {}
local next_wanted = {}
local inflight = {}
local loading = {model_count = 0, material_count = 0}
local rendered = previews.rendered or {}
previews.rendered = rendered
local texture_states = previews.texture_states or {}
previews.texture_states = texture_states
previews.render_count = previews.render_count or 0
local texture_bytes = 0
local material_sphere

local function get_kind(entry)
	if entry.category == "textures" then return "texture" end

	if entry.category == "models" then
		if entry.extension == ".bsp" then return "none" end

		return "model"
	end

	if entry.category == "materials" then return "material" end

	return "none"
end

local function fail(state, reason)
	state.status = "failed"
	state.error = reason
end

local function create_preview_entity_from_descriptor(descriptor)
	local entity = Entity.New{Name = descriptor.name or "asset_preview_model", Transient = true}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:SetVisible(false)

	for index, primitive in ipairs(descriptor.create_primitives({})) do
		local primitive_entity = Entity.New{
			Name = (descriptor.name or "asset_preview_model") .. "_primitive_" .. index,
			Parent = entity,
		}
		primitive_entity:AddComponent("transform")
		local visual_primitive = primitive_entity:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(primitive.mesh or primitive.polygon3d or primitive)

		if primitive.material then visual_primitive:SetMaterial(primitive.material) end
	end

	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity
end

function previews.CreateModelEntity(path)
	if path:ends_with(".lua") then
		local entry = assets.GetModel(path)

		if entry and entry.value and type(entry.value.create_primitives) == "function" then
			return create_preview_entity_from_descriptor(entry.value)
		end

		return nil
	end

	local entity = Entity.New{Name = path, Transient = true}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:SetVisible(false)
	entity.visual:SetUseOcclusionCulling(false)
	entity.visual:SetModelPath(path)
	return entity
end

function previews.IsMaterialReady(material)
	if not material then return true end

	if material.Error then return true end

	if material.vmt_path and not material.vmt then return false end

	for _, info in ipairs(material:GetTextures()) do
		if not info.texture:IsReady() then return false end
	end

	return true
end

function previews.AreModelMaterialsReady(visual)
	if not previews.IsMaterialReady(visual:GetMaterialOverride()) then
		return false
	end

	for _, render_entry in ipairs(visual:GetRenderEntries()) do
		if not previews.IsMaterialReady(visual:GetResolvedMaterial(render_entry)) then
			return false
		end
	end

	return true
end

local function acquire_render(state)
	local render

	if previews.render_count < previews.MAX_RENDERED then
		previews.render_count = previews.render_count + 1
		render = {
			preview = ModelPreview.New{
				Width = previews.RENDER_SIZE,
				Height = previews.RENDER_SIZE,
				Padding = 1.12,
			},
			state = state,
		}
		return render
	end

	local stalest
	local stalest_index

	for i, other in ipairs(rendered) do
		if
			previews.frame - other.last_used > 2 and
			(
				not stalest or
				other.last_used < stalest.last_used
			)
		then
			stalest = other
			stalest_index = i
		end
	end

	if not stalest then return nil end

	table.remove(rendered, stalest_index)
	local reused = stalest.render
	stalest.render = nil
	stalest.texture = nil
	stalest.entry.preview = nil
	reused.state = state
	return reused
end

local function release_texture_state(state)
	texture_bytes = texture_bytes - (state.bytes or 0)
	state.bytes = 0
	local texture = state.texture
	state.texture = nil
	state.entry.preview = nil

	if
		state.owned and
		texture:IsValid() and
		texture.image ~= Texture.GetFallback().image
	then
		texture:Remove()
	end
end

local function enforce_texture_budget()
	while texture_bytes > previews.TEXTURE_BYTES do
		local stalest
		local stalest_index

		for i, other in ipairs(texture_states) do
			if
				previews.frame - other.last_used > 2 and
				(
					not stalest or
					other.last_used < stalest.last_used
				)
			then
				stalest = other
				stalest_index = i
			end
		end

		if not stalest then return end

		table.remove(texture_states, stalest_index)
		release_texture_state(stalest)
	end
end

local function step_texture(state, now)
	local entry = state.entry

	if not state.texture then
		if entry.kind == "lua" or entry.source == "virtual" then
			state.texture = assets.GetTexture(entry.path)
		else
			state.texture = Texture.New{
				path = entry.path,
				srgb = true,
				cache_key = "asset_preview|" .. entry.lower_path,
			}
			state.owned = true
		end

		if not state.texture then
			fail(state, "unable to load texture")
			return false
		end

		state.status = "loading"
		state.started = now
		return true
	end

	local texture = state.texture

	if not texture:IsReady() then
		if now - state.started > previews.TIMEOUT then
			fail(state, "timed out while loading")
		end

		return false
	end

	if state.abandoned then
		release_texture_state(state)
		state.status = "released"
		return false
	end

	if state.owned and texture.image == Texture.GetFallback().image then
		state.texture = nil
		state.owned = false
		fail(state, "failed to decode texture")
		return false
	end

	state.status = "ready"
	state.width = texture:GetWidth()
	state.height = texture:GetHeight()
	state.format = texture.format
	state.mip_levels = texture.mip_map_levels
	state.compressed = texture.is_compressed

	if state.owned then
		state.bytes = state.width * state.height * (state.compressed and 1 or 4) * 1.34
		texture_bytes = texture_bytes + state.bytes
		texture_states[#texture_states + 1] = state
		enforce_texture_budget()
	end

	return false
end

local function collect_model_info(state, visual)
	local info = {primitives = 0, vertices = 0, triangles = 0, materials = {}}
	local seen = {}

	for _, render_entry in ipairs(visual:GetRenderEntries()) do
		info.primitives = info.primitives + 1
		local mesh = render_entry.polygon3d:GetMesh()

		if mesh:IsValid() then
			info.vertices = info.vertices + mesh.vertex_buffer:GetVertexCount()

			if mesh.index_buffer then
				info.triangles = info.triangles + mesh.index_buffer:GetIndexCount() / 3
			end
		end

		local material = visual:GetResolvedMaterial(render_entry)
		local name = material.vmt_path or material:GetName()

		if name ~= "" and not seen[name] then
			seen[name] = true
			info.materials[#info.materials + 1] = name
		end
	end

	local aabb = visual:GetAABB()
	info.size = {
		aabb.max_x - aabb.min_x,
		aabb.max_y - aabb.min_y,
		aabb.max_z - aabb.min_z,
	}
	state.info = info
end

local function finish_render(state, render)
	state.render = render
	state.texture = render.preview:GetTexture()
	state.status = "ready"
	state.width = previews.RENDER_SIZE
	state.height = previews.RENDER_SIZE
	rendered[#rendered + 1] = state
end

local function cleanup_model_job(state)
	local entity = state.entity
	state.entity = nil

	if entity and entity:IsValid() then entity:Remove() end

	if state.owns_model_cache then
		model_loader.model_loads:Forget(state.entry.path)
	end
end

local function step_model(state, now, budget)
	local entry = state.entry

	if not state.entity then
		if loading.model_count >= previews.MAX_LOADING then return false end

		local owns_model_cache = entry.kind ~= "lua" and not model_loader.model_cache[entry.path]
		state.entity = previews.CreateModelEntity(entry.path)

		if not state.entity then
			fail(state, "not a procedural model")
			return false
		end

		state.owns_model_cache = owns_model_cache
		state.status = "loading"
		state.started = now
		loading.model_count = loading.model_count + 1
		return true
	end

	local visual = state.entity.visual
	local render_entries = visual:GetRenderEntries()

	if visual.Loading or not render_entries[1] then
		if not visual.Loading and not render_entries[1] then
			cleanup_model_job(state)
			loading.model_count = loading.model_count - 1
			fail(state, "model has no geometry")
		elseif now - state.started > previews.TIMEOUT then
			cleanup_model_job(state)
			loading.model_count = loading.model_count - 1
			fail(state, "timed out while loading")
		end

		return false
	end

	if render_entries[1].entity.Name:ends_with("_error") then
		cleanup_model_job(state)
		loading.model_count = loading.model_count - 1
		fail(state, "failed to load model")
		return false
	end

	if
		not previews.AreModelMaterialsReady(visual) and
		now - state.started < previews.TIMEOUT
	then
		return false
	end

	if budget.renders <= 0 then return false end

	local render = acquire_render(state)

	if not render then return false end

	budget.renders = budget.renders - 1
	collect_model_info(state, visual)
	render.preview:SetTarget(visual)
	render.preview:Refresh()
	render.preview:SetTarget(nil)
	finish_render(state, render)
	cleanup_model_job(state)
	loading.model_count = loading.model_count - 1
	return true
end

function previews.GetMaterialSphere()
	if not material_sphere or not material_sphere:IsValid() then
		material_sphere = create_preview_entity_from_descriptor(assets.GetModel("models/sphere.lua").value)
		material_sphere:SetName("asset_preview_material_sphere")
	end

	return material_sphere
end

function previews.LoadMaterial(entry)
	local virtual_asset = assets.virtual_assets[entry.path]

	if virtual_asset then
		local result = virtual_asset.load(entry.path)

		if type(result) == "table" and result.Type ~= "render3d_material" then
			result = Material.New(result)
		end

		return result
	end

	if entry.extension == ".vmt" then
		previews.private_serial = previews.private_serial + 1
		return vmt_material.FromVMT(entry.path, "asset_preview|" .. previews.private_serial .. "|")
	end

	return assets.GetMaterial(entry.path)
end

function previews.ReleaseMaterial(material)
	if material.private_prefix then vmt_material.Release(material) end
end

local function step_material(state, now, budget)
	local entry = state.entry

	if not state.material then
		if loading.material_count >= previews.MAX_LOADING then return false end

		local ok, material = xpcall(previews.LoadMaterial, debug.traceback, entry)

		if not ok or not material then
			fail(state, ok and "unable to load material" or material)
			return false
		end

		state.material = material
		state.status = "loading"
		state.started = now
		loading.material_count = loading.material_count + 1
		return true
	end

	local material = state.material

	if material.Error then
		state.material = nil
		loading.material_count = loading.material_count - 1
		fail(state, material.Error)
		previews.ReleaseMaterial(material)
		return false
	end

	if
		not previews.IsMaterialReady(material) and
		now - state.started < previews.TIMEOUT
	then
		return false
	end

	if budget.renders <= 0 then return false end

	local render = acquire_render(state)

	if not render then return false end

	budget.renders = budget.renders - 1
	local sphere = previews.GetMaterialSphere()
	sphere.visual:SetMaterialOverride(material)
	render.preview:SetTarget(sphere.visual)
	render.preview:Refresh()
	render.preview:SetTarget(nil)
	sphere.visual:SetMaterialOverride(nil)
	finish_render(state, render)
	state.material = nil
	loading.material_count = loading.material_count - 1
	previews.ReleaseMaterial(material)
	return true
end

function previews.Request(entry)
	local state = entry.preview

	if not state then
		state = {
			entry = entry,
			kind = get_kind(entry),
			status = "queued",
			last_used = previews.frame,
		}

		if state.kind == "none" then state.status = "none" end

		entry.preview = state
	end

	state.last_used = previews.frame

	if state.status == "queued" or state.status == "loading" then
		next_wanted[#next_wanted + 1] = state
	end

	return state
end

function previews.Draw(state, x, y, w, h)
	if state.render then
		state.render.preview:Draw(x, y, w, h)
		return
	end

	local scale = math.min(w / state.width, h / state.height)
	local dw, dh = state.width * scale, state.height * scale
	render2d.SetTexture(state.texture)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(x + (w - dw) / 2, y + (h - dh) / 2, dw, dh)
end

function previews.Release(entry)
	local state = entry.preview

	if not state then return end

	if state.entity then
		cleanup_model_job(state)
		loading.model_count = loading.model_count - 1
		state.status = "released"
	elseif state.material then
		loading.material_count = loading.material_count - 1
		previews.ReleaseMaterial(state.material)
		state.material = nil
		state.status = "released"
	elseif state.kind == "texture" and state.status == "loading" then
		state.abandoned = true
	elseif state.texture and state.owned then
		for i, other in ipairs(texture_states) do
			if other == state then
				table.remove(texture_states, i)

				break
			end
		end

		release_texture_state(state)
	end

	entry.preview = nil
end

function previews.Clear()
	for i = #inflight, 1, -1 do
		previews.Release(inflight[i].entry)
	end

	for _, state in ipairs(texture_states) do
		release_texture_state(state)
	end

	list.clear(texture_states)

	for _, state in ipairs(rendered) do
		state.render.preview:Remove()
		state.render = nil
		state.texture = nil
		state.entry.preview = nil
	end

	list.clear(rendered)
	previews.render_count = 0

	for _, state in ipairs(wanted) do
		state.entry.preview = nil
	end

	list.clear(wanted)
	list.clear(next_wanted)
end

local steps = {texture = step_texture, model = step_model, material = step_material}

function previews.Update()
	previews.frame = previews.frame + 1
	local now = system.GetElapsedTime()
	local frame_wanted = next_wanted
	next_wanted = wanted
	wanted = frame_wanted
	list.clear(next_wanted)
	local budget = {starts = previews.STARTS_PER_FRAME, renders = previews.RENDERS_PER_FRAME}

	for i = #inflight, 1, -1 do
		local state = inflight[i]
		steps[state.kind](state, now, budget)

		if state.status ~= "loading" then table.remove(inflight, i) end
	end

	for _, state in ipairs(wanted) do
		if state.status == "queued" and budget.starts > 0 then
			if steps[state.kind](state, now, budget) then
				budget.starts = budget.starts - 1
				inflight[#inflight + 1] = state
			end
		end
	end
end

event.AddListener("Update", "asset_previews", previews.Update)
return previews
