#!/usr/bin/env rdmd

module build_android;

import std.algorithm;
import std.array;
import std.ascii : isAlpha, isAlphaNum;
import std.bitmanip;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

version (linux)
	enum hostTag = "linux-x86_64";
else version (OSX)
	enum hostTag = "darwin-x86_64";
else
	static assert(0, "Unsupported host OS for this script."); // TODO: Maybe this could work on windows

string requireEnv(string name, string hint = null)
{
	auto v = environment.get(name);
	enforce(v !is null && v.length > 0,
		"Set " ~ name ~ (hint.length ? " (" ~ hint ~ ")" : ""));
	return v;
}

string envOr(string name, string dflt)
{
	auto v = environment.get(name);
	return (v is null) ? dflt : v;
}

string expandEnvVars(string value)
{
	if (value.length == 0)
		return value;

	// Leading ~ -> $HOME (only a bare leading ~ or ~/..., not ~user)
	if (value == "~" || value.startsWith("~/"))
	{
		auto home = environment.get("HOME", "");
		value = home ~ value[1 .. $];
	}

	auto result = appender!string;
	size_t i = 0;
	while (i < value.length)
	{
		if (value[i] == '$' && i + 1 < value.length)
		{
			if (value[i + 1] == '{')
			{
				auto close = value.indexOf('}', i + 2);
				if (close >= 0)
				{
					auto name = value[i + 2 .. close];
					result.put(environment.get(name, ""));
					i = close + 1;
					continue;
				}
			}
			else if (isAlpha(value[i + 1]) || value[i + 1] == '_')
			{
				size_t j = i + 1;
				while (j < value.length && (isAlphaNum(value[j]) || value[j] == '_'))
					j++;
				auto name = value[i + 1 .. j];
				auto resolved = environment.get(name, null);
				result.put(resolved is null ? value[i .. j] : resolved);
				i = j;
				continue;
			}
		}
		result.put(value[i]);
		i++;
	}
	return result.data;
}

void loadEnvFile(string path)
{
	if (!exists(path))
		return;

	foreach (rawLine; File(path).byLine)
	{
		auto line = rawLine.idup.strip;
		if (line.length == 0 || line.startsWith("#"))
			continue;
		if (line.startsWith("export "))
			line = line["export ".length .. $].strip;

		auto eq = line.indexOf('=');
		if (eq < 0)
			continue;

		auto key = line[0 .. eq].strip;
		auto val = line[eq + 1 .. $].strip;

		if (val.length >= 2 &&
			((val[0] == '"' && val[$ - 1] == '"') ||
			(val[0] == '\'' && val[$ - 1] == '\'')))
		{
			val = val[1 .. $ - 1];
		}

		environment[key] = expandEnvVars(val);
	}
}

// ABI configuration
struct AbiConfig
{
	string abi; // canonical Android ABI name
	string triple; // LDC target triple
	string clangName; // NDK clang wrapper filename (without dir)
	string runtimeLibDir;
	bool is64Bit;
}

AbiConfig resolveAbi(string requested, int apiLevel)
{
	switch (requested)
	{
		case "arm64-v8a":
		case "aarch64":
		case "arm64":
		{
			auto home = requireEnv("LDC_ANDROID_AARCH64_HOME",
				"your extracted ldc2-*-android-aarch64 package");
			return AbiConfig(
				"arm64-v8a",
				"aarch64-linux-android",
				"aarch64-linux-android" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib"),
				true
			);
		}
		case "x86_64":
		case "amd64":
		{
			auto home = requireEnv("LDC_ANDROID_AARCH64_HOME",
				"your extracted ldc2-*-android-aarch64 package");
			return AbiConfig(
				"x86_64",
				"x86_64-linux-android",
				"x86_64-linux-android" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib-android-x86_64"),
				true
			);
		}
		case "armeabi-v7a":
		case "arm":
		case "arm32":
		{
			auto home = requireEnv("LDC_ANDROID_ARMV7A_HOME",
				"your extracted ldc2-*-android-armv7a package");
			return AbiConfig(
				"armeabi-v7a",
				"armv7a-linux-androideabi",
				"armv7a-linux-androideabi" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib"),
				false
			);
		}
		default:
			throw new Exception("Unsupported ABI: " ~ requested);
	}
}

/*
	Native ELF rpath stripping

	Method: locate PT_DYNAMIC, walk its Elf{32,64}_Dyn entries, and for
	any DT_RPATH (15) / DT_RUNPATH (29) tag, overwrite the tag with DT_NULL
	(0) in place. This is a no-shrink, no-relink patch — exactly what
	`patchelf --remove-rpath` does under the hood for the common case where
	no other tags need to move. Handles both 32-bit and 64-bit ELF.
*/

private enum PT_DYNAMIC = 2;
private enum DT_NULL = 0;
private enum DT_RPATH = 15;
private enum DT_RUNPATH = 29;

void stripRpath(string path)
{
	auto data = cast(ubyte[]) std.file.read(path);
	enforce(data.length >= 20 && data[0] == 0x7f && data[1] == 'E'
		&& data[2] == 'L' && data[3] == 'F', "Not a valid ELF file: " ~ path);

	bool is64 = data[4] == 2; // EI_CLASS: 1 = ELFCLASS32, 2 = ELFCLASS64
	bool littleEndian = data[5] == 1; // EI_DATA: 1 = LE, 2 = BE

	enforce(littleEndian, "Only little-endian ELF is supported (Android targets)");

	size_t patched = 0;

	if (is64)
	{
		// Elf64_Ehdr layout: e_phoff at offset 0x20 (8 bytes),
		// e_phentsize at 0x36 (2 bytes), e_phnum at 0x38 (2 bytes)
		ulong phoff = data.peek!(ulong, Endian.littleEndian)(0x20);
		ushort phentsize = data.peek!(ushort, Endian.littleEndian)(0x36);
		ushort phnum = data.peek!(ushort, Endian.littleEndian)(0x38);

		foreach (i; 0 .. phnum)
		{
			size_t phOff = cast(size_t)(phoff + i * phentsize);
			uint pType = data.peek!(uint, Endian.littleEndian)(phOff);
			if (pType != PT_DYNAMIC)
				continue;

			ulong dynOffset = data.peek!(ulong, Endian.littleEndian)(phOff + 8); // p_offset
			ulong dynFilesz = data.peek!(ulong, Endian.littleEndian)(phOff + 32); // p_filesz

			// Elf64_Dyn { Elf64_Sxword d_tag; Elf64_Xword d_val; } = 16 bytes
			size_t entrySize = 16;
			size_t count = cast(size_t)(dynFilesz / entrySize);
			size_t removed = 0;
			ubyte[] entries;

			foreach (j; 0 .. count)
			{
				size_t off = cast(size_t)(dynOffset + j * entrySize);
				long tag = cast(long) data.peek!(ulong, Endian.littleEndian)(off);

				if (tag == DT_RPATH || tag == DT_RUNPATH)
				{
					removed++;
					continue;
				}

				entries ~= data[off .. off + entrySize];

				if (tag == DT_NULL)
					break;
			}

			if (removed > 0)
			{
				size_t writeOff = cast(size_t) dynOffset;
				data[writeOff .. writeOff + entries.length] = entries[];

				size_t padStart = writeOff + entries.length;
				size_t padEnd = cast(size_t)(dynOffset + dynFilesz);
				data[padStart .. padEnd] = 0; // DT_NULL (tag 0) + val 0, repeated
				patched += removed;
			}
		}
	}
	else
	{
		// Elf32_Ehdr layout: e_phoff at offset 0x1C (4 bytes),
		// e_phentsize at 0x2A (2 bytes), e_phnum at 0x2C (2 bytes)
		uint phoff = data.peek!(uint, Endian.littleEndian)(0x1C);
		ushort phentsize = data.peek!(ushort, Endian.littleEndian)(0x2A);
		ushort phnum = data.peek!(ushort, Endian.littleEndian)(0x2C);

		foreach (i; 0 .. phnum)
		{
			size_t phOff = cast(size_t)(phoff + i * phentsize);
			uint pType = data.peek!(uint, Endian.littleEndian)(phOff);
			if (pType != PT_DYNAMIC)
				continue;

			uint dynOffset = data.peek!(uint, Endian.littleEndian)(phOff + 4); // p_offset
			uint dynFilesz = data.peek!(uint, Endian.littleEndian)(phOff + 16); // p_filesz

			// Elf32_Dyn { Elf32_Sword d_tag; Elf32_Word d_val; } = 8 bytes
			size_t entrySize = 8;
			size_t count = dynFilesz / entrySize;

			foreach (j; 0 .. count)
			{
				size_t off = dynOffset + j * entrySize;
				int tag = cast(int) data.peek!(uint, Endian.littleEndian)(off);
				if (tag == DT_RPATH || tag == DT_RUNPATH)
				{
					data.write!(uint, Endian.littleEndian)(DT_NULL, off);
					patched++;
				}
				else if (tag == DT_NULL)
				{
					break;
				}
			}
		}
	}

	if (patched > 0)
	{
		std.file.write(path, data);
		writefln("Stripped %d rpath/runpath entr%s from %s",
			patched, patched == 1 ? "y" : "ies", path);
	}
	else
	{
		writeln("No rpath/runpath entries found in ", path, " (nothing to do)");
	}
}

// Subprocess helpers //

void run(string[] cmd)
{
	writeln("== ", cmd.join(" "));
	auto pid = spawnProcess(cmd);
	auto status = wait(pid);
	enforce(status == 0, cmd[0] ~ " failed with exit code " ~ status.to!string);
}

// Merges extra env vars into the "current" process environment for the
// child, rather than replacing it wholesale.
void runWithExtraEnv(string[] cmd, string[string] extraEnv)
{
	auto fullEnv = environment.toAA;
	foreach (k, v; extraEnv)
		fullEnv[k] = v;

	writeln("== ", cmd.join(" "));
	auto pid = spawnProcess(cmd, fullEnv);
	auto status = wait(pid);
	enforce(status == 0, cmd[0] ~ " failed with exit code " ~ status.to!string);
}

/*
	Optional build hooks: aprebuild.sh / apostbuild.sh

	These are plain, standalone, optional shell scripts (NOT sourced --
	just executed as a normal subprocess). If the file doesn't exist, the
	hook is silently skipped. If it exists but isn't executable, we warn
	and skip (so a stray non-executable file doesn't kill the build).
*/

struct HookResult
{
	string extraCFlags;
	string extraLdFlags;
	string extraDFlags;
}

HookResult runHook(string scriptName, string[] args, string[string] extraEnv = null)
{
	HookResult result;

	if (!exists(scriptName) || !isFile(scriptName))
		return result; // optional -- nothing to do

	version (Posix)
	{
		import core.sys.posix.sys.stat : S_IXUSR, S_IXGRP, S_IXOTH;
		auto mode = getAttributes(scriptName);
		if ((mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0)
		{
			writeln("== Skipping ", scriptName, " (found but not executable; run: chmod +x ", scriptName, ")");
			return result;
		}
	}

	auto fullEnv = environment.toAA;
	foreach (k, v; extraEnv)
		fullEnv[k] = v;

	writeln("== Running ", scriptName, " ", args.join(" "));

	auto scriptPath = isAbsolute(scriptName) ? scriptName : "./" ~ scriptName;
	auto pipes = pipeProcess([scriptPath] ~ args, Redirect.stdout, fullEnv);

	string[] extraCFlagsParts, extraLdFlagsParts, extraDFlagsParts;
	foreach (rawLine; pipes.stdout.byLine)
	{
		auto line = rawLine.idup.strip;
		if (line.length == 0)
			continue;

		// Echo it through too, so hook stdout isn't just swallowed silently.
		writeln("   [", scriptName, "] ", line);

		if (line.startsWith("EXTRA_CFLAGS="))
			extraCFlagsParts ~= line["EXTRA_CFLAGS=".length .. $].strip;
		else if (line.startsWith("EXTRA_LDFLAGS="))
			extraLdFlagsParts ~= line["EXTRA_LDFLAGS=".length .. $].strip;
		else if (line.startsWith("EXTRA_DFLAGS="))
			extraDFlagsParts ~= line["EXTRA_DFLAGS=".length .. $].strip;
	}

	auto status = wait(pipes.pid);
	enforce(status == 0, scriptName ~ " failed with exit code " ~ status.to!string);

	result.extraCFlags = extraCFlagsParts.filter!(s => s.length > 0).join(" ");
	result.extraLdFlags = extraLdFlagsParts.filter!(s => s.length > 0).join(" ");
	result.extraDFlags = extraDFlagsParts.filter!(s => s.length > 0).join(" ");
	return result;
}

string appendFlag(string existing, string extra)
{
	if (extra.length == 0)
		return existing;
	return existing.length == 0 ? extra : existing ~ " " ~ extra;
}

void main(string[] args)
{
	loadEnvFile("./asetup.sh");

	string requestedAbi = args.length > 1 ? args[1] : "arm64-v8a";
	enum apiLevel = 24;
	enum betterCFlag = "-betterC"; // TODO: revisit when druntime/Phobos on Android is usable

	auto ndkHome = requireEnv("ANDROID_NDK_HOME",
		"or set ANDROID_NDK_ROOT / ANDROID_NDK");

	auto abiCfg = resolveAbi(requestedAbi, apiLevel);

	auto toolchainBin = buildPath(ndkHome, "toolchains", "llvm", "prebuilt", hostTag, "bin");
	auto ndkClang = buildPath(toolchainBin, abiCfg.clangName);
	auto sysroot = buildPath(ndkHome, "toolchains", "llvm", "prebuilt", hostTag, "sysroot");

	enforce(exists(ndkClang) && isFile(ndkClang),
		"Expected NDK clang wrapper not found: " ~ ndkClang);
	enforce(exists(abiCfg.runtimeLibDir) && isDir(abiCfg.runtimeLibDir),
		"Expected android runtime lib dir not found: " ~ abiCfg.runtimeLibDir ~
		"\nList the package's contents to find the right folder name.");

	auto androidOutputDir = absolutePath(envOr("ANDROID_OUTPUT_DIR", "android/app/src/main")).buildNormalizedPath;
	auto outDir = buildPath(androidOutputDir, "jniLibs", abiCfg.abi);
	mkdirRecurse(outDir);

	// Standalone ldc2 config, used only for this build via -conf=
	auto tmpConfDir = buildPath(tempDir(), "ldc2-android-" ~ abiCfg.abi);
	mkdirRecurse(tmpConfDir);
	auto tmpConf = buildPath(tmpConfDir, "ldc2-android.conf");

	auto confContents = format(`"default":
{
	switches ~= [
		"-defaultlib=",
		"-debuglib=",
	];
	post-switches ~= [
		"-I/usr/include/dlang/ldc",
	];
};

"%s.*":
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
`, abiCfg.triple);

	std.file.write(tmpConf, confContents);

	writeln("== Building D sources for ", abiCfg.abi, " (", abiCfg.triple,
		", API ", apiLevel, ") ==");
	writeln(" using runtime libs from: ", abiCfg.runtimeLibDir);

	auto raylibLibDir = requireEnv("RAYLIB_LIB_DIR");
	auto extraCFlags = envOr("EXTRA_CFLAGS", "");
	auto extraLdFlags = envOr("EXTRA_LDFLAGS", "");
	auto extraDFlags = envOr("EXTRA_DFLAGS", "");

	// Optional pre-build hook: aprebuild.sh <abi> <triple> <apiLevel> <sysroot> <outDir>
	// Handy for compiling extra C/asm sources and emitting EXTRA_DFLAGS=... to
	// link them in (see doc comment on runHook above for the full contract).
	auto preHookEnv = [
		"NDK_CLANG": ndkClang,
		"SYSROOT": sysroot,
		"OUT_DIR": outDir,
		"ABI": abiCfg.abi,
		"LDC_TRIPLE": abiCfg.triple,
		"API_LEVEL": apiLevel.to!string,
	];
	auto preHook = runHook("aprebuild.sh",
		[abiCfg.abi, abiCfg.triple, apiLevel.to!string, sysroot, outDir],
		preHookEnv);

	extraCFlags = appendFlag(extraCFlags, preHook.extraCFlags);
	extraLdFlags = appendFlag(extraLdFlags, preHook.extraLdFlags);
	extraDFlags = appendFlag(extraDFlags, preHook.extraDFlags);

	// -Wl,--wrap=fopen satisfies Raylib's internal Android asset loader mapping
	auto dflags = [
		"-conf=" ~ tmpConf,
		betterCFlag,
		"-gcc=" ~ ndkClang,
		"-Xcc=--target=" ~ abiCfg.triple ~ apiLevel.to!string,
		"-Xcc=--sysroot=" ~ sysroot,
		"-Xcc=-shared",
		"-Xcc=-Wl,--wrap=fopen",
		"-Xcc=-Wl,-u,ANativeActivity_onCreate",
		"-L--sysroot=" ~ sysroot,
		"-L-L" ~ buildPath(raylibLibDir, abiCfg.abi),
		"-L-lraylib",
		"-L-lEGL",
		"-L-lGLESv2",
		"-L-landroid",
		"-L-llog",
		"-L-lc",
		"-L-L" ~ buildPath(sysroot, "usr", "lib", abiCfg.triple, apiLevel.to!string),
		extraCFlags,
		extraLdFlags,
		extraDFlags,
	].filter!(s => s.length > 0).join(" ");

	string[string] buildEnv;
	buildEnv["DFLAGS"] = dflags;
	buildEnv["CC"] = ndkClang;

	runWithExtraEnv(
		["dub", "build", "-v",
		"--config=android",
		"--compiler=ldc2",
		"--arch=" ~ abiCfg.triple,
		"--force"],
		buildEnv
	);

	// Locate the built shared library
	string builtLib;
	if (exists("libmain.so"))
		builtLib = "libmain.so";
	else if (exists(buildPath("lib", "libmain.so")))
		builtLib = buildPath("lib", "libmain.so");
	else
		throw new Exception(
			"Build artifact 'libmain.so' not found in root or lib/.\n" ~
			"Check your dub build output path and adjust the search paths above.");

	auto destLib = buildPath(outDir, "libmain.so");
	std.file.copy(builtLib, destLib);
	writeln("Copied ", builtLib, " -> ", outDir);

	stripRpath(destLib);

	auto llvmStrip = buildPath(toolchainBin, "llvm-strip");
	run([llvmStrip, "--strip-unneeded", destLib]);

	// Optional post-build hook: apostbuild.sh <pathToStrippedLib>
	// Handy for extra post-processing (e.g. custom signing, copying assets).
	// Its EXTRA_* stdout lines (if any) are parsed but unused at this point
	// since the build already ran; only its side effects and exit status matter.
	runHook("apostbuild.sh", [destLib], ["OUT_DIR": outDir, "ABI": abiCfg.abi]);

	writeln("Now run: cd android && ./gradlew assembleDebug");
}