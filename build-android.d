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

string ldcPackageHome(string pkgDir, string legacyVar)
{
	auto root = environment.get("LDC_ANDROID_HOME");
	if (root is null || root.length == 0)
	{
		root = requireEnv(legacyVar,
			"parent dir containing '" ~ pkgDir ~ "/', or set LDC_ANDROID_HOME");
	}
	return buildPath(root, pkgDir);
}

// ELF e_machine values
private enum EM_ARM = 40;
private enum EM_X86_64 = 62;
private enum EM_AARCH64 = 183;

// ABI configuration
struct AbiConfig
{
	string abi; // canonical Android ABI name
	string triple; // LDC target triple
	string sysrootLibTriple; // dir name under <sysroot>/usr/lib (differs from triple on armv7)
	string clangName; // NDK clang wrapper filename (without dir)
	string runtimeLibDir;
	bool is64Bit;
	ushort elfMachine; // expected e_machine of objects for this ABI
}

AbiConfig resolveAbi(string requested, int apiLevel)
{
	switch (requested)
	{
		case "arm64-v8a":
		case "armv8":
		case "aarch64":
		case "arm64":
		{
			auto home = ldcPackageHome("arm64-v8a", "LDC_ANDROID_AARCH64_HOME");
			return AbiConfig(
				"arm64-v8a",
				"aarch64-linux-android",
				"aarch64-linux-android",
				"aarch64-linux-android" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib"),
				true,
				EM_AARCH64
			);
		}
		case "x86_64":
		case "amd64":
		{
			// x86_64 runtime libs ship inside the aarch64 package (lib-android-x86_64),
			// which lives in the arm64-v8a folder.
			auto home = ldcPackageHome("arm64-v8a", "LDC_ANDROID_AARCH64_HOME");
			return AbiConfig(
				"x86_64",
				"x86_64-linux-android",
				"x86_64-linux-android",
				"x86_64-linux-android" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib-android-x86_64"),
				true,
				EM_X86_64
			);
		}
		case "armeabi-v7a":
		case "armv7":
		case "arm":
		case "arm32":
		{
			auto home = ldcPackageHome("armeabi-v7a", "LDC_ANDROID_ARMV7A_HOME");
			return AbiConfig(
				"armeabi-v7a",
				"armv7a-linux-androideabi",
				// NDK sysroot uses "arm-linux-androideabi" instead of armv7a
				"arm-linux-androideabi",
				"armv7a-linux-androideabi" ~ apiLevel.to!string ~ "-clang",
				buildPath(home, "lib"),
				false,
				EM_ARM
			);
		}
		default:
			throw new Exception("Unsupported ABI: " ~ requested);
	}
}

string machineName(ushort m)
{
	switch (m)
	{
		case EM_ARM:     return "ARM (32-bit)";
		case EM_AARCH64: return "AArch64";
		case EM_X86_64:  return "x86-64";
		default:         return "unknown (e_machine=" ~ m.to!string ~ ")";
	}
}

ushort elfMachine(string path)
{
	auto f = File(path, "rb");
	ubyte[20] hdr;
	auto got = f.rawRead(hdr[]);
	enforce(got.length == 20 && hdr[0] == 0x7f && hdr[1] == 'E'
		&& hdr[2] == 'L' && hdr[3] == 'F', "Not a valid ELF file: " ~ path);
	return hdr[].peek!(ushort, Endian.littleEndian)(0x12); // e_machine
}

// Catches the cause of "incompatible with elf64-x86-64": an extra object
// (e.g. from aprebuild.sh) compiled for the wrong architecture. Only plain .o
// files are checked.
void checkObjectArch(string flags, AbiConfig cfg)
{
	foreach (tok; flags.split)
	{
		auto p = tok.startsWith("-L") ? tok[2 .. $] : tok;
		if (!p.endsWith(".o"))
			continue;
		if (!exists(p) || !isFile(p))
			throw new Exception("Extra object not found: " ~ p);

		auto m = elfMachine(p);
		enforce(m == cfg.elfMachine,
			p ~ " is built for " ~ machineName(m) ~ " but target " ~ cfg.abi ~
			" needs " ~ machineName(cfg.elfMachine) ~
			". Fix aprebuild.sh to compile it with $NDK_CLANG.");
		writeln("   ok: ", p, " is ", machineName(m));
	}
}

/*
	Native ELF rpath stripping

	Method: locate PT_DYNAMIC, walk its Elf{32,64}_Dyn entries, and for
	any DT_RPATH (15) / DT_RUNPATH (29) tag, overwrite the tag with DT_NULL
	(0) in place. This is a no-shrink, no-relink patch, exactly what
	`patchelf --remove-rpath` does for the common case where no other tags
	need to move. Handles both 32-bit and 64-bit ELF.
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

	enum LE = Endian.littleEndian;

	// Elf64_Ehdr: e_phoff 0x20 (8), e_phentsize 0x36 (2), e_phnum 0x38 (2)
	// Elf32_Ehdr: e_phoff 0x1C (4), e_phentsize 0x2A (2), e_phnum 0x2C (2)
	size_t phoff = is64 ? cast(size_t) data.peek!(ulong, LE)(0x20) : data.peek!(uint, LE)(0x1C);
	size_t phentsize = data.peek!(ushort, LE)(is64 ? 0x36 : 0x2A);
	size_t phnum = data.peek!(ushort, LE)(is64 ? 0x38 : 0x2C);

	// Elf64_Dyn = 16 bytes {Sxword tag; Xword val}, Elf32_Dyn = 8 bytes {Sword tag; Word val}
	size_t entrySize = is64 ? 16 : 8;
	size_t patched = 0;

	foreach (i; 0 .. phnum)
	{
		size_t ph = phoff + i * phentsize;
		if (data.peek!(uint, LE)(ph) != PT_DYNAMIC)
			continue;

		// 64-bit: p_offset at +8, p_filesz at +32. 32-bit: p_offset at +4, p_filesz at +16.
		size_t dynOffset = is64 ? cast(size_t) data.peek!(ulong, LE)(ph + 8) : data.peek!(uint, LE)(ph + 4);
		size_t dynFilesz = is64 ? cast(size_t) data.peek!(ulong, LE)(ph + 32) : data.peek!(uint, LE)(ph + 16);

		// Copy every entry except RPATH/RUNPATH, up to and including DT_NULL.
		// The table must be COMPACTED: the loader stops at the first DT_NULL, so
		// blanking an entry in the middle hides everything after it
		// (DT_GNU_HASH, DT_STRTAB, DT_SYMTAB, ...).
		ubyte[] kept;
		size_t removed = 0;

		foreach (j; 0 .. dynFilesz / entrySize)
		{
			size_t off = dynOffset + j * entrySize;
			long tag = is64
				? cast(long) data.peek!(ulong, LE)(off)
				: cast(long) cast(int) data.peek!(uint, LE)(off);

			if (tag == DT_RPATH || tag == DT_RUNPATH)
			{
				removed++;
				continue;
			}

			kept ~= data[off .. off + entrySize];

			if (tag == DT_NULL)
				break;
		}

		if (removed > 0)
		{
			data[dynOffset .. dynOffset + kept.length] = kept[];
			// Zero the tail: DT_NULL (tag 0) + val 0, repeated
			data[dynOffset + kept.length .. dynOffset + dynFilesz] = 0;
			patched += removed;
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

	Stdout lines of the form EXTRA_CFLAGS=..., EXTRA_LDFLAGS=... and
	EXTRA_DFLAGS=... are collected and appended to the matching flag sets.
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
	enum apiLevel = 29; // Older android fails with errors (See README.md)
	enum betterCFlag = "-betterC"; // TODO: revisit when druntime/Phobos on Android is usable

	auto ndkHome = requireEnv("ANDROID_NDK_HOME",
		"or set ANDROID_NDK_ROOT / ANDROID_NDK");

	auto abiCfg = resolveAbi(requestedAbi, apiLevel);

	auto toolchainBin = buildPath(ndkHome, "toolchains", "llvm", "prebuilt", hostTag, "bin");
	auto ndkClang = buildPath(toolchainBin, abiCfg.clangName);
	auto sysroot = buildPath(ndkHome, "toolchains", "llvm", "prebuilt", hostTag, "sysroot");
	auto sysrootApiLibDir = buildPath(sysroot, "usr", "lib", abiCfg.sysrootLibTriple, apiLevel.to!string);

	enforce(exists(ndkClang) && isFile(ndkClang),
		"Expected NDK clang wrapper not found: " ~ ndkClang);
	enforce(exists(sysrootApiLibDir) && isDir(sysrootApiLibDir),
		"Expected NDK sysroot lib dir not found: " ~ sysrootApiLibDir);
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
	writeln(" using sysroot libs from: ", sysrootApiLibDir);

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

	// Fail early (with a clear message) if any extra .o has the wrong architecture.
	checkObjectArch(extraDFlags, abiCfg);
	checkObjectArch(extraLdFlags, abiCfg);

	// VERBOSE_LINK=1 makes the clang link driver print its full lld command line,
	// which shows exactly which -m emulation / --target it ends up using.
	auto verboseLink = envOr("VERBOSE_LINK", "") == "1" ? "-Xcc=-v" : "";

	// -Wl,--wrap=fopen satisfies Raylib's internal Android asset loader mapping
	auto dflags = [
		"-conf=" ~ tmpConf,
		betterCFlag,
		// API level in the triple lets LLVM pick emulated TLS (native ELF TLS in
		// dlopen'd libs only works on Android 10+ / API 29+).
		"-mtriple=" ~ abiCfg.triple ~ apiLevel.to!string,
		"-gcc=" ~ ndkClang,
		"-Xcc=--target=" ~ abiCfg.triple ~ apiLevel.to!string,
		"-Xcc=--sysroot=" ~ sysroot,
		"-Xcc=-fuse-ld=lld",
		"-Xcc=-shared",
		"-Xcc=-Wl,--wrap=fopen",
		"-Xcc=-Wl,-u,ANativeActivity_onCreate",
		verboseLink,
		"-L--sysroot=" ~ sysroot,
		"-L-L" ~ buildPath(raylibLibDir, abiCfg.abi),
		"-L-lraylib",
		"-L-lEGL",
		"-L-lGLESv2",
		"-L-landroid",
		"-L-llog",
		"-L-lc",
		"-L-L" ~ sysrootApiLibDir,
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

	auto builtMachine = elfMachine(destLib);
	enforce(builtMachine == abiCfg.elfMachine,
		destLib ~ " is " ~ machineName(builtMachine) ~ ", expected " ~ machineName(abiCfg.elfMachine) ~
		" -- libmain.so in the project root is probably stale from another ABI.");

	stripRpath(destLib);

	auto llvmStrip = buildPath(toolchainBin, "llvm-strip");
	run([llvmStrip, "--strip-unneeded", destLib]);

	// Optional post-build hook: apostbuild.sh <pathToStrippedLib>
	// Handy for extra post-processing (e.g. custom signing, copying assets).
	// Its EXTRA_* stdout lines (if any) are parsed but unused at this point
	// since the build already ran; only its side effects and exit status matter.
	runHook("apostbuild.sh", [destLib], ["OUT_DIR": outDir, "ABI": abiCfg.abi]);

	writefln("DONE: \"\033[32m%s\033[0m\"", destLib);
}
