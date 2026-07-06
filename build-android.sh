#!/usr/bin/env bash

if [ -f "./envvars.sh" ]; then
	source "./envvars.sh"
fi

set -euo pipefail

ABI="${1:-arm64-v8a}"
API_LEVEL=24
BETTERC_FLAG="-betterC" # TODO: Change this one day when become usable

ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT/ANDROID_NDK) to your NDK install path first}"

case "$(uname -s)" in
Linux)  HOST_TAG="linux-x86_64" ;;
Darwin) HOST_TAG="darwin-x86_64" ;; #?
*) echo "Unsupported host OS for this script: $(uname -s)" >&2; exit 1 ;;
esac

TOOLCHAIN_BIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"

case "$ABI" in
	arm64-v8a|aarch64|arm64)
		ABI="arm64-v8a" # canonical Android ABI
		LDC_TRIPLE="aarch64-linux-android"
		NDK_CLANG="${TOOLCHAIN_BIN}/aarch64-linux-android${API_LEVEL}-clang"
		: "${LDC_ANDROID_AARCH64_HOME:?Set LDC_ANDROID_AARCH64_HOME to your extracted ldc2-*-android-aarch64 package}"
		RUNTIME_LIB_DIR="${LDC_ANDROID_AARCH64_HOME}/lib"
		;;
	x86_64|amd64)
		ABI="x86_64"
		LDC_TRIPLE="x86_64-linux-android"
		NDK_CLANG="${TOOLCHAIN_BIN}/x86_64-linux-android${API_LEVEL}-clang"
		: "${LDC_ANDROID_AARCH64_HOME:?Set LDC_ANDROID_AARCH64_HOME to your extracted ldc2-*-android-aarch64 package}"
		RUNTIME_LIB_DIR="${LDC_ANDROID_AARCH64_HOME}/lib-android-x86_64"
		# BETTERC_FLAG=""
		;;
	armeabi-v7a|arm|arm32)
		ABI="armeabi-v7a"
		LDC_TRIPLE="armv7a-linux-androideabi"
		NDK_CLANG="${TOOLCHAIN_BIN}/armv7a-linux-androideabi${API_LEVEL}-clang"
		: "${LDC_ANDROID_ARMV7A_HOME:?Set LDC_ANDROID_ARMV7A_HOME to your extracted ldc2-*-android-armv7a package}"
		RUNTIME_LIB_DIR="${LDC_ANDROID_ARMV7A_HOME}/lib"
		;;
	*)
		echo "Unsupported ABI: $ABI" >&2
		exit 1
		;;
esac

ANDROID_OUTPUT_DIR="$(cd "${ANDROID_OUTPUT_DIR:-android/app/src/main}" && pwd)"
OUT_DIR="${ANDROID_OUTPUT_DIR}/jniLibs/${ABI}"

if [ ! -x "$NDK_CLANG" ]; then
	echo "!! Expected NDK clang wrapper not found: $NDK_CLANG" >&2
	exit 1
fi
if [ ! -d "$RUNTIME_LIB_DIR" ]; then
	echo "!! Expected android runtime lib dir not found: $RUNTIME_LIB_DIR" >&2
	echo "   List the package's contents to find the right folder name," >&2
	echo "   e.g.: ls \"\$(dirname \"$RUNTIME_LIB_DIR\")\"" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"

# Standalone ldc2 config used ONLY for this build (via -conf=)
TMP_CONF="$(mktemp -d)/ldc2-android.conf"
cat > "$TMP_CONF" <<EOF
"default":
{
	switches ~= [

		"-defaultlib=",
		"-debuglib=",
	];
	post-switches ~= [
		"-I/usr/include/dlang/ldc",
	];
};

"${LDC_TRIPLE}.*":
{
	switches ~= [

		"-defaultlib=",
		"-debuglib=",
	];
		post-switches ~= [
		"-I/usr/include/dlang/ldc",
	];
	lib-dirs = [];
	rpath = ["/"];
};
EOF

echo "== Building D sources for ${ABI} (${LDC_TRIPLE}, API ${API_LEVEL}) =="
echo "   using runtime libs from: ${RUNTIME_LIB_DIR}"

SYSROOT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}/sysroot"

# Force DUB to use NDK tools directly for everything
export CC="${NDK_CLANG}"

# -Wl,--wrap=fopen to satisfy Raylib's internal Android asset loader mapping.
DFLAGS="-conf=${TMP_CONF} ${BETTERC_FLAG} -gcc=${NDK_CLANG} \
-Xcc=--target=${LDC_TRIPLE}${API_LEVEL} \
-Xcc=--sysroot=${SYSROOT} \
-Xcc=-shared \
-Xcc=-Wl,--wrap=fopen \
-Xcc=-Wl,-u,ANativeActivity_onCreate \
-v \
-L--sysroot=${SYSROOT} \
-L-L${RAYLIB_LIB_DIR}/${ABI} \
-L-lraylib \
-L-lEGL \
-L-lGLESv2 \
-L-landroid \
-L-llog \
-L-lc \
-L-L${SYSROOT}/usr/lib/${LDC_TRIPLE}/${API_LEVEL}" \
dub build -v \
	--config=android \
	--compiler=ldc2 \
	--arch="${LDC_TRIPLE}" \
	--force



BUILT_LIB="libmain.so"

if [ -f "$BUILT_LIB" ]; then
	cp "$BUILT_LIB" "${OUT_DIR}/libmain.so"
	echo "Copied libmain.so -> ${OUT_DIR}"
	patchelf --remove-rpath "${OUT_DIR}/libmain.so"
elif [ -f "lib/libmain.so" ]; then
	cp "lib/libmain.so" "${OUT_DIR}/libmain.so"
	echo "Copied lib/libmain.so -> ${OUT_DIR}"
	patchelf --remove-rpath "${OUT_DIR}/libmain.so"
else
	echo "!! Build artifact 'libmain.so' not found in root or lib/." >&2
	echo "   Check your dub build output path and adjust BUILT_LIB." >&2
	exit 1
fi

${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}/bin/llvm-strip --strip-unneeded "${OUT_DIR}/libmain.so"

echo "Now run: cd android && ./gradlew assembleDebug"
