Attempts to be a graphics/game framework like love2d and maybe some garrysmod, written in luajit using vulkan.

The constraints I want to follow are:

- Write everything in LuaJIT.
- LuaJIT FFI bindings should only target the OS and the Vulkan driver. Anything else like libpng, sdl, etc is not allowed, everything has to be written in lua.

This should be the successor of https://github.com/CapsAdmin/goluwa . In my previous project, I used OpenGL had bindings to SDL, freeimage, etc. I often had issues with portability when dealing with third party libraries, so this time I want to avoid it entirely. Today we also have LLM's which can greatly help with doing things from scratch.