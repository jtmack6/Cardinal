# Cardinal Build Notes - macOS

## Issues Resolved

### 1. Git Submodules Not Initialized
**Problem:** Initial error was "OpenGL dependency not installed/available" which was misleading. The real issue was that the `dpf` directory and all other submodules were empty.

**Solution:**
```bash
git submodule update --init --recursive
```

This successfully initialized 90+ submodules including:
- dpf (DISTRHO Plugin Framework)
- carla
- src/Rack
- All plugin subdirectories with their nested submodules

**Verification:**
```bash
git submodule status | head -20
# Should show commit hashes (not `-` prefix) for all submodules
```

### 2. Emscripten Cache Permissions
**Problem:** After submodules were initialized, build failed with permission error:
```
PermissionError: [Errno 13] Permission denied: '/opt/local/libexec/emscripten/cache/ports/sdl2'
```

**Solution:**
```bash
sudo mkdir -p /opt/local/libexec/emscripten/cache/ports
sudo chown -R $(whoami) /opt/local/libexec/emscripten/cache
```

## Current Issue - Emscripten Auto-Detection

**Problem:** The build system auto-detects emscripten (emcc) in PATH and switches to WebAssembly build mode instead of native macOS build. This happens because:

1. DPF's `Makefile.base.mk` runs `$(CC) -dumpmachine` to detect target platform (line 82)
2. Since emcc is in PATH and CC isn't explicitly set, it uses emcc
3. This returns `wasm32-unknown-emscripten` which sets `WASM=true`
4. The entire build then uses emscripten toolchain (emcc, em++, emar)

**Evidence:**
```
env AR=emar CC=emcc CXX=em++  # Wrong - should be clang/clang++
checking for wasm32-unknown-emscripten-gcc... emcc  # Wrong platform
```

## Next Steps (After Removing Emscripten from PATH)

### Option 1: Remove emcc from PATH temporarily
```bash
# In your shell, before running make:
export PATH=$(echo $PATH | tr ':' '\n' | grep -v emscripten | paste -sd ':' -)
```

### Option 2: Explicitly set compilers
```bash
CC=/usr/bin/clang CXX=/usr/bin/clang++ make -j$(sysctl -n hw.ncpu)
```

### Option 3: Use WASM=false (didn't work - build still found emcc)
```bash
make WASM=false -j$(sysctl -n hw.ncpu)  # This still used emcc
```

## Expected Build Command (After emcc removal)

Once emscripten is removed from PATH, the standard build should work:
```bash
make -j$(sysctl -n hw.ncpu)
```

Or to be explicit:
```bash
CC=clang CXX=clang++ make -j$(sysctl -n hw.ncpu)
```

## Build System Details

### Platform Detection
Location: `dpf/Makefile.base.mk:82`
```make
TARGET_MACHINE := $(shell $(CC) -dumpmachine)
```

For native macOS, this should return something like:
- `x86_64-apple-darwin` (Intel)
- `arm64-apple-darwin` (Apple Silicon)

NOT `wasm32-unknown-emscripten`

### Makefile Hierarchy
1. `Makefile` - Main entry point
2. `Makefile.base.mk` - Cardinal-specific base config
3. `dpf/Makefile.base.mk` - DPF base (platform detection here)
4. `src/Makefile.cardinal.mk` - Cardinal plugin variants
5. `carla/source/Makefile.deps.mk` - Carla dependencies
6. `plugins/Makefile` - Plugin modules

## Dependencies (may be needed)

Check for these if build still fails:
```bash
# These are typically available on macOS via Xcode Command Line Tools
# But might need MacPorts or Homebrew versions:
# - OpenGL (system provided)
# - fftw3f (mentioned in Makefile:125 warning)
# - pkg-config
```

## Other Warnings Seen (non-fatal)
- `grep: warning: stray \ before #` - Can be ignored
- `Makefile:125: fftw3f dependency not installed/available` - May be optional
- Various `-Wnan-infinity-disabled` warnings in Carla - Cosmetic

## Clean Build
If you need to start fresh:
```bash
make clean
# Then run normal build command
```

## Expected Build Targets

The build should create:
- `bin/Cardinal.lv2/` - LV2 plugin
- `bin/Cardinal.vst/` - VST2 plugin
- `bin/Cardinal.vst3/` - VST3 plugin
- `bin/Cardinal.clap/` - CLAP plugin
- `bin/CardinalFX.*` - FX variant
- `bin/CardinalSynth.*` - Synth variant

---

**Date:** 2026-01-04
**Status:** Ready to build once emscripten is removed from PATH
