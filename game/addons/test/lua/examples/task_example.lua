local tasks = require("tasks")

tasks.CreateTask(function(self)
	for i = 1, 3 do
		print(i .. "...")
		self:Wait(1)
	end

	print("exit!")
end)
