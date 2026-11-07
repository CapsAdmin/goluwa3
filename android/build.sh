#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
out="$here/build"
abis="${ABIS:-arm64-v8a}"
api=26
target_api=34
ndk="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

test -n "$ndk" || { echo "set ANDROID_NDK_ROOT"; exit 1; }
test -n "$sdk" || { echo "set ANDROID_HOME"; exit 1; }

manifest_ref() {
	sed -n "/$1 = {/,/}/s/^[[:space:]]*ref = \"\(.*\)\".*/\1/p" "$repo/goluwa/bin_manifest.lua" | head -1
}

luajit_ref="$(manifest_ref luajit)"
glslang_ref="$(manifest_ref glslang)"
toolchain="$(echo "$ndk"/toolchains/llvm/prebuilt/*)"
build_tools="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
platform="$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)"
glue="$ndk/sources/android/native_app_glue"

mkdir -p "$out/src"

if [ ! -d "$out/src/luajit" ]; then
	git clone https://github.com/LuaJIT/LuaJIT "$out/src/luajit"
fi

git -C "$out/src/luajit" fetch -q origin
git -C "$out/src/luajit" checkout -q "$luajit_ref"

if [ ! -d "$out/src/glslang" ]; then
	git clone --depth 1 --branch "$glslang_ref" https://github.com/KhronosGroup/glslang "$out/src/glslang"
fi

rm -rf "$out/stage"

for abi in $abis; do
	case "$abi" in
		arm64-v8a) triple=aarch64-linux-android ;;
		x86_64) triple=x86_64-linux-android ;;
		*) echo "unsupported abi $abi"; exit 1 ;;
	esac

	cc="$toolchain/bin/$triple$api-clang"
	abi_out="$out/$abi"
	mkdir -p "$abi_out" "$out/stage/lib/$abi"

	rm -rf "$abi_out/luajit"
	cp -r "$out/src/luajit" "$abi_out/luajit"
	make -C "$abi_out/luajit" amalg -j"$(nproc)" \
		HOST_CC="${HOST_CC:-cc}" \
		CROSS="$toolchain/bin/$triple-" \
		STATIC_CC="$cc -fPIC" \
		DYNAMIC_CC="$cc -fPIC" \
		TARGET_LD="$cc" \
		TARGET_AR="$toolchain/bin/llvm-ar rcus" \
		TARGET_STRIP="$toolchain/bin/llvm-strip" \
		XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT" \
		BUILDMODE=static

	"$cc" -shared -fPIC -O2 -o "$out/stage/lib/$abi/libgoluwa.so" \
		"$here/main.c" "$glue/android_native_app_glue.c" \
		-I"$glue" -I"$abi_out/luajit/src" \
		-Wl,--whole-archive "$abi_out/luajit/src/libluajit.a" -Wl,--no-whole-archive \
		-Wl,-soname,libgoluwa.so -Wl,-z,global -Wl,-z,max-page-size=16384 \
		-u ANativeActivity_onCreate -landroid -llog -lm -ldl

	if [ ! -f "$abi_out/libglslang.so" ]; then
		cmake -S "$out/src/glslang" -B "$abi_out/glslang" -G Ninja -DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
			-DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$api" -DANDROID_STL=c++_static \
			-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
			-DBUILD_SHARED_LIBS=ON -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF
		cmake --build "$abi_out/glslang"
		cp -L "$(find "$abi_out/glslang" -name libglslang.so | head -1)" "$abi_out/libglslang.so"
		cp -L "$(find "$abi_out/glslang" -name libglslang-default-resource-limits.so | head -1)" "$abi_out/libglslang-default-resource-limits.so"
	fi

	for library in libglslang libglslang-default-resource-limits; do
		"$toolchain/bin/llvm-strip" --strip-unneeded -o "$out/stage/lib/$abi/$library.so" "$abi_out/$library.so"
	done
done

if [ ! -f "$out/debug.keystore" ]; then
	keytool -genkeypair -keystore "$out/debug.keystore" -storepass android -keypass android \
		-alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
fi

rm -f "$out/unsigned.apk" "$out/aligned.apk"
"$build_tools/aapt2" link -o "$out/unsigned.apk" --manifest "$here/AndroidManifest.xml" \
	-I "$platform/android.jar" --min-sdk-version "$api" --target-sdk-version "$target_api"
(cd "$out/stage" && zip -qr "$out/unsigned.apk" lib)
"$build_tools/zipalign" -f -p 4 "$out/unsigned.apk" "$out/aligned.apk"
"$build_tools/apksigner" sign --ks "$out/debug.keystore" --ks-pass pass:android \
	--out "$out/goluwa.apk" "$out/aligned.apk"
echo "built $out/goluwa.apk for $abis"
