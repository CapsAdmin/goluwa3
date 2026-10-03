local scene_loading = library()
scene_loading.pending = 0

function scene_loading.Begin()
	scene_loading.pending = scene_loading.pending + 1
end

function scene_loading.End()
	scene_loading.pending = scene_loading.pending - 1
end

function scene_loading.IsLoading()
	return scene_loading.pending > 0
end

function scene_loading.HoldTask(task)
	local on_remove = task.OnRemove
	scene_loading.Begin()

	function task:OnRemove()
		scene_loading.End()
		return on_remove(self)
	end
end

return scene_loading
