local Panel = require("ecs.panel")
return function(config)
	return Panel.New(
		table.merge(
			{
				ComponentSet = {
					"rect",
					"transform",
					"gui_element",
					"layout",
					"mouse_input",
					"clickable",
					"animation",
				},
			},
			config
		)
	)
end
