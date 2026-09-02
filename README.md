# raylib-d Android build template

This is a template for building a raylib-d game for android, please note that the solution is extremely wacky and anything can fail.


## Requirements

- [Android NDK](https://developer.android.com/ndk/)
- [Gradle](https://gradle.org/)
- Linux LDC (Not tested on Windows/MacOS)
- [Android LDC](https://github.com/ldc-developers/ldc/releases)
- A [Raylib](https://github.com/raysan5/raylib) .a file compiled for Android (Depending on target archtitecture)
- `dmd` or `ldc2` on your host, to run `build-android.d` itself via `rdmd`/`dmd -run` (this is separate from the Android-targeting LDC above)

> [!NOTE]
> ldc2-aarch64 includes the x86_64 libs, so is still needed for x86_64

## Considerations
This template currently assumes a `-betterC`-style build.

While D and Phobos *can* theoretically run on Android, this setup does not ship Android-compatible druntime/Phobos libraries and i don't know how to properly setup a Phobos build for that (on arm it does not but, and on x86_64 it builds but the app itself crashes), so enabling them will result in linker errors such as:

```
ld.lld: error: /usr/lib/ldc_rt.dso.o is incompatible with aarch64linux
ld.lld: error: /usr/lib/libphobos2-ldc-shared.so is incompatible with aarch64linux
ld.lld: error: /usr/lib/libdruntime-ldc-shared.so is incompatible with aarch64linux
```

## Prepare

### Add the android setup to your `dub.json`

```
	"configurations": [
...
		{
			"name": "android",
			"targetType": "dynamicLibrary",
			"targetName": "main",
			"dependencies": {
				"raylib-d": "~>6.0.1"
			},
			"subConfigurations": {
				"raylib-d": "library"
			},
			"libs-posix": []
		}
	]
```


### Compile Raylib

1. Clone and build raylib

```
git clone https://github.com/raysan5/raylib
cd raylib/src
```

```
make PLATFORM=PLATFORM_ANDROID \
     ANDROID_NDK=/path/to/your/android-ndk \
     ANDROID_ARCH=arm64 \
     ANDROID_API_VERSION=29
```

> Replace `aarch64` to `x86_64` or `arm` if needed

2. Place your raylib in `raylib-android` according to the desired archtitecture, for example:

```
-> tree raylib-android/
raylib-android/
├── arm64-v8a
│   └── libraylib.a
└── x86_64
    └── libraylib.a
```

### Define environment variables

```
export LDC_ANDROID_AARCH64_HOME=/home/user/ldc2-aarch64
export ANDROID_NDK_HOME=/opt/android-ndk
export RAYLIB_LIB_DIR=/home/user/raylib-android/
export ANDROID_OUTPUT_DIR=/path/to/your/apk/setup/
```

> Replace those paths with the actual paths, or copy `asetup.example` to
> `asetup.sh` and edit it. `build-android.d` loads simple `KEY=VALUE`
> lines from `asetup.sh` automatically if the file exists, and expands
> `$VAR`, `${VAR}`, and a leading `~` (e.g. `$USER`, `$HOME`) the same
> way a shell would.

## Try to build

The build helper is a native D script (`build-android.d`), no shell interpreter required beyond your normal system tools (`dub`, the NDK, `llvm-strip`).

Run it with `rdmd` (bundled with DMD/LDC) or compile it once and reuse the binary:

```shell
rdmd build-android.d arm64-v8a # or x86_64 / armeabi-v7a
```

Equivalent, using `dmd`/`ldc` directly instead of `rdmd`:

```shell
dmd -run build-android.d arm64-v8a
```

### Building for other architectures

The first argument selects the target ABI. Supported values (aliases in parentheses):

| ABI | Aliases | Required env var |
| --- | --- | --- |
| `arm64-v8a` | `aarch64`, `arm64` | `LDC_ANDROID_AARCH64_HOME` |
| `x86_64` | `amd64` | `LDC_ANDROID_AARCH64_HOME`* |
| `armeabi-v7a` | `arm`, `arm32` | `LDC_ANDROID_ARMV7A_HOME` |

> x86_64 builds use the same `ldc2-*-android-aarch64` package — see the note above under Requirements.

Defaults to `arm64-v8a` if no argument is given:

```
rdmd build-android.d # arm64-v8a
```

```
rdmd build-android.d x86_64 # x86_64
```

```
rdmd build-android.d armeabi-v7a # armeabi-v7a
```

To build for multiple architectures in one go just call it once per ABI, Each run writes its output to `android/app/src/main/jniLibs/<ABI>/libmain.so`, so subsequent runs for different ABIs don't overwrite each other. The resulting `jniLibs/` tree can then be picked up as is by a single Gradle build producing a multi-ABI APK/AAB.

```
gradle wrapper # You may need to get gradlew jar first time
```

```
gradlew assembleDebug
```

## Use it as a submodule

This project can be used as submodule:

```
git submodule add https://github.com/zariep-software/raylib-d-android-template.git abuild
```

so then you call

```
rdmd abuild/build-android.d arm64-v8a
```

## More Information

More information about setting up a game for android in raylib-d (e.g. Setting up / troubleshoot things like rotation, Touch screen or screen size) available on [the wiki](https://github.com/Zariep-Software/raylib-d-android-template/wiki)
