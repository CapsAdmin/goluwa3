# macos

On macos, the kosmickrisp vulkan driver is used as opposed to moltenvk

# Love2D and Garrysmod wrapper

These wrappers make it possible to run lua scripts made for those engines, in this engine. They exist in `addons/love/*` and `addons/gmod/*`

- Never modify a love2d game's source code. Always fix issues in the wrapper itself. The same applies for garrysmod scripts.

- Do not add script and game specific workarounds in the wrapper for specific games and scripts.

- The glua wrapper uses garrysmod's lua source as-is and only implements functions that garrysmod defines in C. Never redefine something like Color, since it's already in garrysmod's lua source.

- If this engine lacks core functionality that the wrapper's engine assume exists, consider adding it to this engine if it's generic and useful enough, as opposed to adding functionality to the wrapper only. For example, if render2d in this engine is missing alpha blending, add alpha blending to render2d, then write wrapper code to to use the new engine functionality.
