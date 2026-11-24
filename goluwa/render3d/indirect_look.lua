local pvars = import("goluwa/cli/pvars.lua")
local indirect_look = {}
pvars.StartGroup("Lighting", "Indirect look", {store = false, prefix = "gi_"})
indirect_look.gain = pvars.Setup2{
	key = "gi_gain",
	default = 1,
	help = "scales the diffuse indirect light on the surfaces the camera sees, sky and bounce light together. Probes, reflections, fog and translucent surfaces do not change. 1 is physical",
}
indirect_look.contrast = pvars.Setup2{
	key = "gi_contrast",
	default = 1,
	help = "spreads the diffuse indirect light around gi_contrast_pivot: surfaces that get more indirect light than the pivot get brighter, ones that get less get darker. It is a power, 2 squares the light like overlaying the gi on the image. 1 is physical",
}
indirect_look.contrast_pivot = pvars.Setup2{
	key = "gi_contrast_pivot",
	default = 0.18,
	help = "the indirect light gi_contrast leaves as it is, as the exposed brightness a white surface would have under it (middle grey is 0.18). Lower brightens more of the indirect light, higher darkens more",
	callback = function(value)
		assert(value > 0, "gi_contrast_pivot must be above 0")
	end,
}
indirect_look.saturation = pvars.Setup2{
	key = "gi_saturation",
	default = 1,
	help = "colourfulness of the diffuse indirect light on the surfaces the camera sees, 0 is grey and 2 twice the colour. Saturates the sky's blue as much as the bounce colour. 1 is physical",
}
indirect_look.bounce_gain = pvars.Setup2{
	key = "gi_bounce_gain",
	default = 1,
	help = "scales the albedo of surfaces that gi rays hit, so only light that has bounced off something gets brighter, the sky's light does not. It compounds per bounce, enclosed spaces gain more than open ones. 1 is physical",
}
indirect_look.bounce_saturation = pvars.Setup2{
	key = "gi_bounce_saturation",
	default = 1,
	help = "colourfulness of the albedo of surfaces that gi rays hit, 0 is grey bounce light and 2 twice the colour. It compounds per bounce like gi_bounce_gain. 1 is physical",
}
indirect_look.sky_gain = pvars.Setup2{
	key = "gi_sky_gain",
	default = 1,
	help = "scales the sky's light that gi rays bring back (probe and screen gi rays that miss), not the sky itself or the direct sun. 1 is physical",
}
pvars.EndGroup()
return indirect_look
