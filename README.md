# LuaJIT PureFFI

This is a collection of pure LuaJIT FFI bindings that aim to be cross-platform compatible.

Each module aims to be standalone, copy-pastable, and have no strict dependency on any shared libraries.

## Modules

- **`filesystem.lua`** - Provides functionality similar to [LuaFileSystem](https://github.com/lunarmodules/luafilesystem)

- **`socket.lua`** - Provides functionality similar to [luasocket](https://github.com/lunarmodules/luasocket)

- **`threads.lua`** - Provides functionality similar to [effil](https://github.com/effil/effil). It uses `string.buffer` in LuaJIT 2.1 for serialization between threads and also has a thread pool to keep threads alive (since we need to create a Lua state per thread)

- **`tls.lua`** - Provides functionality similar to [luasec](https://github.com/lunarmodules/luasec). This is a work in progress; it depends on shared libraries existing on some platforms but can use TLS on the OS if it exists

- **`terminal.lua`** - A low-level module for building a TUI and provides async key and mouse events

- **`vk.lua`** - An auto-generated Vulkan binding built with [NattLua](https://github.com/CapsAdmin/NattLua/blob/master/examples/vulkan_bindgen.lua)

- **`cocoa.lua`** - Provides a way to open and receive window events on macOS. This depends on `objc.lua` for bindings.
## Usage

`luajit examples/terminal/game_of_life.lua`

`luajit examples/vulkan/game_of_life.lua` (only works on macos at the moment)

If you get a segfault, you can run `luajit debug.lua examples/gameoflife.lua` to get a C stacktrace and a lua stacktrace.