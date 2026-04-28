# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Cardinal is a self-contained, GPLv3+ plugin wrapper around [VCV Rack](https://github.com/VCVRack/Rack/), built on top of the [DPF (DISTRHO Plugin Framework)](https://github.com/DISTRHO/DPF/). It uses Rack's source directly (as a git submodule) rather than forking, and bundles ~90 third-party module collections plus internal Cardinal modules into a single binary. It does **not** load external modules at runtime and does **not** connect to the VCV Rack library/store.

Core authoring repos referenced here: `dpf/` (plugin framework), `carla/` (used internally for plugin hosting), `src/Rack/` (Rack itself).

## Build system

GNU Make. The repo is heavily submoduled — after cloning, you must run:

```bash
git submodule update --init --recursive
```

Build everything (default target = `all`):

```bash
make -j$(sysctl -n hw.ncpu)   # macOS
make -j$(nproc)               # Linux
```

### Full build — concrete commands

**macOS (this machine, Apple Silicon, MacPorts toolchain):** `emcc` is in `PATH` at `/opt/local/bin/emcc`, which silently hijacks the build into a WebAssembly toolchain (see "Platform-specific gotchas" below). Always override `CC`/`CXX` explicitly:

```bash
# Native arm64 release build (recommended for development on this Mac)
CC=/usr/bin/clang CXX=/usr/bin/clang++ make -j$(sysctl -n hw.ncpu)

# Universal (arm64 + x86_64) build, matching the official release artifacts
export CFLAGS="-DMAC_OS_X_VERSION_MAX_ALLOWED=MAC_OS_X_VERSION_10_12 -mmacosx-version-min=10.12 -arch x86_64 -arch arm64"
export CXXFLAGS="${CFLAGS}"
CC=/usr/bin/clang CXX=/usr/bin/clang++ make -j$(sysctl -n hw.ncpu)

# Debug build (terrible runtime perf, but required for valgrind workflows in docs/DEBUGGING.md)
CC=/usr/bin/clang CXX=/usr/bin/clang++ make DEBUG=true -j$(sysctl -n hw.ncpu)
```

Cold full build runs ~30–60 min on a 12-core M-series Mac. Subsequent incremental builds are much faster. Artifacts land in `bin/`.

**Linux:**

```bash
make -j$(nproc)
```

**Web (emscripten):** import the emsdk env first, then:

```bash
source /path/to/emsdk/emsdk_env.sh
export AR=emar CC=emcc CXX=em++ NM=emnm RANLIB=emranlib STRIP=emstrip
make USE_GLES2=true -j$(nproc)
```

**Windows:** cross-compile only (see `docs/BUILDING.md`); no native build.

### Build option flags

Pass as `make OPTION=value`. Common ones:

- `DEBUG=true` — non-stripped debug build (slow, dev only)
- `NOSIMD=true` — disable SIMD (dev only)
- `HEADLESS=true` — no GUI; required for `loader` and MOD/embed builds
- `STATIC_BUILD=true` — skip Cardinal core modules that need local resources (audio file, plugin host)
- `SYSDEPS=true` — use system jansson/libarchive/samplerate/speexdsp instead of vendored copies (auto-on for FreeBSD)
- `WITH_LTO=true` — Link-time optimization (much slower build)
- `MODDUO=true` / `MOD_BUILD=true` — MOD device targets
- `WASM=true` — auto-set when building with emscripten

Standard `CC`/`CXX`/`CFLAGS`/`CXXFLAGS`/`PREFIX`/`DESTDIR` are respected.

### Common build targets

The top-level Makefile delegates to subdir Makefiles. Useful sub-targets for quick iteration:

- `make jack` / `make native` — standalone executables
- `make au` / `make clap` / `make lv2` / `make vst2` / `make vst3` — single plugin format
- `make mini` — the CardinalMini variant (LV2 + standalone only, supports DSP/UI separation)
- `make loader` — headless loader (forces `HEADLESS=true STATIC_BUILD=true`)
- `make plugins` / `make resources` — module code / module resources only
- `make modgui` — MOD device GUI under `src/CardinalMiniSep`
- `make clean` — top-level clean (recurses into carla, deps, dpf/dgl, plugins, src, ttl-generator)
- `make download` (in `deps/`) — fetch upstream tarballs for vendored deps
- `make tarball` / `make tarball+deps` — release tarballs

Build artifacts land in `bin/` as bundle directories (`Cardinal.lv2/`, `Cardinal.vst3/`, `Cardinal.clap/`, `Cardinal.vst/`, plus `CardinalFX.*`, `CardinalSynth.*`, `CardinalMini.*` and standalones `Cardinal`, `CardinalNative`, `CardinalMini`).

### Patched submodules (forked under jtmack6)

Three submodules carry local patches. Rather than living as fragile working-tree edits, each is hosted on a fork on GitHub under `jtmack6/`, on a `cardinal-local` branch off the SHA Cardinal pins. The parent `.gitmodules` URLs point at the forks.

| Path | Fork | Branch | Patch |
|---|---|---|---|
| `plugins/MindMeldModular` | `jtmack6/MindMeldModular` | `cardinal-local` | `src/ShapeMaster/Shape.hpp` — replace `std::abs<T>(...)` with header-free ternary (macOS 26 SDK libc++ removed the explicit-template form for floats) |
| `plugins/4msCompany` | `jtmack6/4ms-vcv` | `cardinal-local` | `src/network/network.cpp` — comment out unused `<openssl/crypto.h>` and `CURL_STATICLIB` (Cardinal links the system libcurl dylib; openssl isn't needed) |
| `plugins/surgext` | `jtmack6/surge-rack` | `cardinal-local` | `src/VCO.cpp` — drop redundant `.template ` qualifier on two `emplace_back` calls (newer clang strictness) |

In each fork, `origin` points to your fork and `upstream` points to the original repo, so `git fetch upstream` works for rebasing later.

**To re-apply or audit on a fresh clone:** `git submodule update --init --recursive` will check out the right SHAs from the forks. To regenerate the forks if they're lost: see `scripts/setup-forked-submodules.sh`. The script is idempotent, auto-creates forks via `gh repo fork`, and uses `GITHUB_PAT` (or `gh auth login`) for the API call.

**To bump a submodule to a newer upstream:**
```bash
cd plugins/<sub>
git fetch upstream
git rebase upstream/<branch> cardinal-local
git push --force-with-lease origin cardinal-local
cd ../..
git add plugins/<sub>
git commit -m "Bump <sub> to latest upstream + cardinal-local rebase"
```

### Submodule drift (the most common build break)

If a build error references an undeclared identifier from a third-party module (e.g. `modelPhaseque`, `modelXYZ`), check `git submodule status` for `+`-prefixed entries. A `+` means the working-tree submodule SHA differs from what the parent Cardinal repo pins — usually because the submodule was advanced past Cardinal's expected commit (often by a stray `git submodule update --remote` or manual checkout). The generated `plugins/plugins.cpp` references whatever symbols the *pinned* submodule exports; if the local submodule has renamed/removed them, you get an undeclared-identifier error.

Fix: reset the offending submodule(s) to the parent's pinned SHA. Audit working trees first with `git -C <submodule> status --short` to make sure no local edits are about to be lost, then:

```bash
git submodule update <path> [<path> ...]
```

Historical example from this repo: ZZC drifted forward to a commit where `Phaseque.cpp` had been renamed to `Phasor.cpp`, breaking `plugins.cpp:3710`'s reference to `modelPhaseque`. `git submodule update plugins/ZZC` restored the build.

### Tests

There is no project-level test suite. Verification is done by:

1. Plugin scanning under valgrind via `carla-discovery` (see `docs/DEBUGGING.md`)
2. Plugin runtime under `carla-bridge-native` with `CARLA_BRIDGE_DUMMY=30` (dummy mode, audio every 30s)

Both require `make DEBUG=true` and use `dpf/utils/valgrind-dpf.supp` as the suppressions file.

### Platform-specific gotchas

- **macOS**: If `emcc` is in `PATH`, `dpf/Makefile.base.mk:82` runs `$(CC) -dumpmachine` against it and the entire build silently switches to a WebAssembly toolchain (`AR=emar CC=emcc CXX=em++`). Either remove emscripten from `PATH` for the shell or set `CC=clang CXX=clang++` explicitly. Setting `WASM=false` alone is **not** sufficient. See `BUILD_NOTES.md` for context.
- **macOS universal**: export `CFLAGS="-DMAC_OS_X_VERSION_MAX_ALLOWED=MAC_OS_X_VERSION_10_12 -mmacosx-version-min=10.12 -arch x86_64 -arch arm64"` and same for `CXXFLAGS` before `make`.
- **Windows**: msvc is not supported — must build via mingw, and the build host must be POSIX (Windows filesystems can't represent the symlinks the source tree uses).
- **WASM**: also set `USE_GLES2=true`. Only `CardinalNative` is produced.
- **FreeBSD**: must use `gmake`; `SYSDEPS=true` is forced.

## Architecture

### Plugin variants

Cardinal ships several variants of the same engine, differing only in IO count and plugin-format metadata. They live as sibling directories in `src/`:

- **Cardinal** ("main") — 8 audio in/out + 10 CV in/out. LV2/VST3/CLAP/standalone only (AU and VST2 don't support CV ports).
- **CardinalFX** — 2 audio in/out, no CV; advertised as effect.
- **CardinalSynth** — 2 audio out only, no CV; advertised as instrument.
- **CardinalMini** — LV2 + standalone only. Hand-picked small module set; the only variant that supports **DSP/UI separation** (DSP and UI on different machines, e.g. for MOD embedded devices).

Inside `src/Cardinal/`, `src/CardinalFX/`, `src/CardinalSynth/`, `src/CardinalMini/`: **everything is a symlink to a shared source file except `DistrhoPluginInfo.h` (variant metadata) and `Makefile` (variant name)**. Behaviour differences are switched on compile-time macros driven by those two files. Edit the underlying source — never the symlinks. The shared sources are `src/Cardinal*.cpp` etc. at the top of `src/`.

### Layered structure

Top to bottom:

1. **DPF** (`dpf/`) — Plugin format wrapper (LV2/VST2/VST3/CLAP/AU/JACK/standalone). `CardinalPlugin.cpp` implements DPF's `Plugin`; `CardinalUI.cpp` implements DPF's `UI`.
2. **Cardinal glue** (`src/`) — Bridges DPF to Rack: `CardinalPluginContext.hpp` extends Rack's `Context` so internal modules can reach DAW-provided data (time, parameters, MIDI). `WindowParameters.hpp` saves/restores per-instance Rack window state because Rack's `settings` is a global. Multiple Cardinal UIs can be open simultaneously thanks to this.
3. **Rack** (`src/Rack/`, submodule) — Compiled into `rack.a` / `rack-headless.a`. The `Makefile` in `src/` builds these static libs.
4. **Overrides** (`src/override/`) — Files copied from Rack and patched. Must be kept in sync with upstream when bumping the submodule.
5. **Custom** (`src/custom/`) — Files fully reimplemented vs. Rack, often stubs that disable network/online features.
6. **Include shims** (`include/`) — Headers that take precedence over Rack's; used to override implementation details and add platform compat (e.g. `linux-compat` for Haiku/WASM, `simd-compat` for non-x86, `single-precision`).
7. **Modules** (`plugins/`) — ~90 module collections, mostly third-party submodules. Cardinal's own modules live in `plugins/Cardinal/` (HostAudio, HostMIDI, HostCV, HostTime, HostParameters, AudioFile, AudioToCVPitch, Carla, Ildaeil, glBars, Blank, etc.). Built into `plugins/plugins.a`.
8. **Carla** (`carla/`) — Used as a static plugin host via `Carla` and `Ildaeil` modules; built with `CARLA_BACKEND_NAMESPACE=Cardinal` and `DGL_NAMESPACE=CardinalDGL` to avoid symbol collisions.

`Makefile.base.mk` sets distinguishing namespaces (`DISTRHO_NAMESPACE=CardinalDISTRHO`, `DGL_NAMESPACE=CardinalDGL`) — this is part of how Cardinal stays self-contained and avoids symbol conflicts when loaded alongside other DPF/Rack-based plugins. Don't change these casually.

### Resource bundling

Module SVG/font/etc. resources are not loaded from disk paths at runtime relative to the user's filesystem; they're staged into `bin/Cardinal*.lv2/resources/` by the `resources` target in `plugins/Makefile`. The other plugin-format bundles symlink into the LV2 `resources/`. **Plugin bundles must keep their internal folder structure intact** — moving the binary alone breaks the build.

### Versioning

`VERSION` is set in the top-level `Makefile`. When bumping it, also update (per the comment at line 12-17 of `Makefile`):

- `.github/ISSUE_TEMPLATE/bug.yaml`
- `src/CardinalCommon.cpp` (`CARDINAL_VERSION`)
- `src/CardinalPlugin.cpp` (`getVersion`)
- `utils/macOS/Info_JACK.plist` and `Info_Native.plist`

## Adding modules

External module additions are governed by [discussion #28](https://github.com/DISTRHO/Cardinal/discussions/28). Constraints:

- License must be GPLv3+-compatible (GPLv3-only is **not** allowed — final binary must be GPLv3+).
- No phone-home / online access.
- Minimize new dependencies.
- Add as a git submodule under `plugins/<Name>/`, register in `plugins/Makefile` and `plugins/plugin.cpp`-style integration.

Patches in `patches/` must be plain-text `.vcv` (not zstd-compressed) for git friendliness.

## Important docs

- `docs/BUILDING.md` — full per-distro dependency lists and cross-compile instructions
- `docs/DEBUGGING.md` — valgrind workflows
- `docs/OVERVIEW.md` — directory-by-directory map of the source tree
- `docs/DIFFERENCES.md` — Cardinal vs. Rack Pro comparison
- `docs/CARDINAL-MODULES.md` — Cardinal-internal module reference
- `BUILD_NOTES.md` — current macOS build issue notes (emscripten PATH problem)
