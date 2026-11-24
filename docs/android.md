# Android

`android/` holds the only C in the repository: `main.c`, a NativeActivity entry built on the NDK's `android_native_app_glue`. It routes stdout and stderr to logcat (tag `goluwa`), puts the `struct android_app` address in `GOLUWA_ANDROID_APP`, sets `HOME` and the working directory to the app's internal files directory, builds `arg` from `args.txt` there (one argument per line) and runs `goluwa/main.lua`. Everything else is LuaJIT.

## Building and running

- `nix develop .#android` gives the SDK, NDK, emulator and build tools. CI builds the same APK with `.github/workflows/android.yml`.
- `android/build.sh` builds LuaJIT, `libgoluwa.so` and glslang for each ABI in `$ABIS` (add `x86_64` for the emulator) and signs `android/build/goluwa.apk` with a generated debug key.
- `android/deploy.sh [engine args]` installs the APK, unpacks `glw`, `goluwa/` and `addons/` into the app's internal files directory with `run-as` (adb cannot write to `/sdcard/Android/data` on Android 11 and later), writes `args.txt`, starts the activity and follows logcat. The Lua tree is not in the APK, so changing Lua only needs a deploy, not a rebuild.
- `android/emulator.sh` creates and boots an x86_64 AVD with the host GPU (`-no-window` for headless, `adb exec-out screencap -p` for screenshots). Its Vulkan is a translation layer over the host driver that aborts the whole emulator on structs it does not know, so it is stricter than desktop drivers about chaining feature structs for unsupported extensions.
- `adb shell input` covers taps, swipes, long presses (`swipe x y x y 900`), `text`, `keyevent` and `mouse tap`; it has no multi-touch or wheel.
- Validation on the phone: take `libVkLayer_khronos_validation.so` for `arm64-v8a` from a Khronos android-binaries release, add it to a copy of the APK under `lib/arm64-v8a/` and re-sign (the loader searches the app library directory), then run with `--vulkan-validate --exit-on-error`. Known benign messages go in `suppressed_warnings` in `goluwa/render/vulkan/internal/instance.lua`. Vendor GPU debug layers (Samsung GpuWatch) hook every Vulkan call; keep them off.

## Simulating a phone GPU on desktop

The Khronos profiles layer (`VK_LAYER_KHRONOS_profiles`, from KhronosGroup/Vulkan-Profiles) makes the desktop GPU report only what a given device supports; device profiles come from `https://vulkan.gpuinfo.org/api/v3/getprofile.php?id=<report id>`. Run with `VK_LAYER_PATH` pointing at the built layer, `VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation:VK_LAYER_KHRONOS_profiles` (validation first so it checks against the simulated device), `VK_KHRONOS_PROFILES_PROFILE_FILE=<json>` and `VK_KHRONOS_PROFILES_SIMULATE_CAPABILITIES=SIMULATE_API_VERSION_BIT,SIMULATE_FEATURES_BIT,SIMULATE_PROPERTIES_BIT,SIMULATE_EXTENSIONS_BIT,SIMULATE_FORMATS_BIT`. It only removes capabilities: it cannot add what the host lacks (ASTC on desktop) and says nothing about speed, tiling or memory size.

## Platform layer

- `jit.os` is `"Linux"` on Android. `goluwa/bindings/android.lua` has `android.active` (any Android process, Termux included) and `android.app` (only inside the APK). Check them before the Linux branches.
- The window is `goluwa/window_implementations/android.lua`: it pumps the glue's looper itself and reads the input queue directly, so no C callbacks into Lua exist. Losing the window or the screen turning off shuts the engine down; the window keeps the screen on.
- Input maps onto the existing mouse and keyboard events (taps are `button_1`, long press `button_2`, two finger drags are wheel steps; a real mouse gives its own buttons and hover). Every finger is also sent as a `TouchInput` event; a listener that returns true on `down` owns that finger until it lifts. Text edits send `TextInputStart`/`TextInputStop`, which show and hide the soft keyboard.
- `ANativeActivity_showSoftInput` does nothing on current Android (it targets a view the input method service never serves), so `android.ShowSoftKeyboard` calls `InputMethodManager.showSoftInput` on the decor view through JNI from Lua. The emulator hides the soft keyboard while it has a hardware keyboard unless `settings put secure show_ime_with_hard_keyboard 1`.
- Touch controls (`addons/game/lua/autorun/render_2d/touch_controls.lua`) are an on screen stick, look area and buttons for the local player, drawn from `Draw2D` because cameras can hide the HUD.
- `libgoluwa.so` is linked with `-z global` so `ffi.C` resolves the LuaJIT API for worker thread states. NDK libraries other than libc (`android`, `aaudio`, `vulkan`) go through `ffi.load`. glslang is loaded from the APK's native library directory; shared libraries cannot be loaded from `/sdcard`.
- Bionic differs from glibc in places that matter for ffi: `sysconf` constants, no `libpthread`, `backtrace` only from API 33.
- The swapchain uses the identity transform when the surface allows it and lets the compositor rotate, so a landscape app on a portrait panel presents `VK_SUBOPTIMAL_KHR` every frame; the swapchain knows it chose that and does not rebuild.
- The app renders into smaller buffers than the screen: the `r_quality` preset picks the height (`android_render_height` in `goluwa/render3d/quality.lua`), applied with `ANativeWindow_setBuffersGeometry`, and the compositor scales up; touch coordinates are scaled to match. Phone GPUs are fill rate bound, so resolution matters far more than the other quality settings. `r_quality` `auto` is `low` on Android.

## Adreno shader rules

- A `uint64_t` in a uniform block at an offset of 8 modulo 16 is read as the field after it. `glsl_metadata` pads every `uint64_t` in a uniform buffer block to a 16 byte boundary on the ffi and GLSL sides (`pad_uniform_buffer_uint64`). Storage buffers are not affected.
- A constant block array (push constants or a uniform block) indexed with a loop counter in a compute shader is miscompiled. Read such arrays with constant indices (the frustum plane test in `goluwa/render3d/scene/draw.lua`). Check a suspicious pass by comparing `scene_draw.ReadBackCull(0).count` with the desktop for the same camera.
