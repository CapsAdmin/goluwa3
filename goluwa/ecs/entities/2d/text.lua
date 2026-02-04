local Panel = require("ecs.panel")
return function(config)
	return Panel.New(
		table.merge(
			{
				ComponentSet = {
					"text",
					"transform",
					"gui_element",
					"layout",
					"mouse_input",
					"clickable",
					"animation",
					"resizable",
				},
			},
			config
		)
	)
end
