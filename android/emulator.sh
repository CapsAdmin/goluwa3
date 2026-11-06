#!/usr/bin/env bash
set -euo pipefail

name=goluwa
image="system-images;android-34;google_apis;x86_64"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

if ! avdmanager list avd -c | grep -qx "$name"; then
	echo no | avdmanager create avd -n "$name" -k "$image" -d pixel_7
fi

exec emulator -avd "$name" -gpu host -no-snapshot -no-boot-anim "$@"
