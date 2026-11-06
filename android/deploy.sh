#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
package=com.goluwa.engine
staging=/data/local/tmp/goluwa.tar

mkdir -p "$here/build"
if [ $# -eq 0 ]; then set -- --2d; fi
printf '%s\n' "$@" > "$repo/args.txt"
(
	cd "$repo"
	tar -cf "$here/build/goluwa.tar" --exclude=addons/__assets --exclude=addons/gltf/scenes --exclude=addons/love/games \
		--exclude="addons/*/tests" args.txt glw goluwa addons
)
rm "$repo/args.txt"

adb install -r "$here/build/goluwa.apk"
adb push "$here/build/goluwa.tar" "$staging"
adb shell chmod 644 "$staging"
adb shell run-as "$package" sh -c "'mkdir -p files && cd files && rm -rf goluwa addons && tar -xf $staging'"
adb shell rm "$staging"
adb shell am force-stop "$package"
adb logcat -c
adb shell am start -n "$package/android.app.NativeActivity"
adb logcat -v brief -s goluwa:V AndroidRuntime:E DEBUG:V vulkan:V
