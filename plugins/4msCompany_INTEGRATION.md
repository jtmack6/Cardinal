# 4ms-vcv → Cardinal integration plan

Goal: bring the **MetaModule Hub** + a small set of 4ms DSP modules into Cardinal, so patches built in CardinalNative can be saved as `.vcv` files and run on MetaModule hardware.

**Selected modules:** `HubMedium`, `Atvert2`, `Slew`, `Noise`, `Pan`, `Source`. Skip everything else (hardware clones DLD/Tapo/EnOsc/PEG/QPLFO/etc. and the physical-hardware expanders MMAudio/MMButton).

## Architecture mismatch

Cardinal builds with GNU Make, single static link, namespaced (`DGL_NAMESPACE=CardinalDGL`, `DISTRHO_NAMESPACE=CardinalDISTRHO`). 4ms-vcv builds with CMake, nine nested `CMakeLists.txt`, multiple sub-libraries with `WHOLE_ARCHIVE` linkage and per-target compile flags.

Approach: flatten into Cardinal's `PLUGIN_FILES += ...` pattern, with per-collection compile rule (`-DpluginInstance=pluginInstance__4ms` like every other collection at `plugins/Makefile:2151+`).

## Source files to compile

### Top-level (from `4msCompany/CMakeLists.txt`)

Required (Hub framework):
- `src/hub/hub_map_button.cc`
- `src/hub/hub_jack_label.cc`
- `src/hub/hub_medium.cc`
- `src/hub/mm_blendish.cc`
- `src/comm/comm_module.cc`
- `src/mapping/midi_modules.cc`
- `src/mapping/patch_writer.cc`            ← uses `patch_to_yaml_string()`
- `src/mapping/module_specific_fixes.cc`
- `src/filesystem/async_filebrowser.cc`
- `src/hardware_support/{memory,random,time,filesystem_helpers}.cc`
- `src/wav/wav_file_stream.cc`, `src/wav/dr_wav.c`
- `src/dsp/stream_resampler.cc`
- `src/graphics/waveform_display.cc`
- `src/thread/{async_thread,async_thread_control}.cc`
- `src/compat/{gui,patch}.cc`
- `src/flatbuffers/encode.cc`              ← single source file, headers in `lib/flatbuffers/`

Skip:
- `src/plugin.cc` — Cardinal pattern is to skip upstream's plugin.cc and instead have plugins.cpp manage `pluginInstance__4ms` via the StaticPluginLoader pattern (see `plugins/plugins.cpp:1152` for example).
- `src/expanders/audio_expander.cc`, `src/expanders/button_expander.cc` — physical hardware expander modules; we drop those models.
- `src/network/network.cpp` — Cardinal stubs `rack::network::*` to no-op (`src/custom/network.cpp`); compiling 4ms's `network.cpp` against those stubs will fail or push fake data. We provide our own minimal stub (see "Network stubbing" below).

### Per-module (chosen subset)

- `src/models/{Atvert2,Slew,Noise,Pan,Source}.cc` — 5 files, each is a 3-line `GenericModule<Info>::create()` template instantiation.

### Sub-libraries

**`lib/CoreModules/`:**
- `moduleFactory.cc`            ← module registry

**`lib/cpputil/`:**
- `util/math_tables.cc`
- `util/int_to_str.cc`

**`lib/patch-serial/`:**
- `yaml_to_patch.cc`
- `patch_to_yaml.cc`
- `ryml/ryml_init.cc`
- `ryml/ryml_serial.cc`

**`lib/patch-serial/ryml/rapidyaml/`** — the YAML library itself. Has its own `CMakeLists.txt`. Need to read its source list and flatten. **This is the biggest unknown.**
- Plus its dep `ryml/rapidyaml/ext/c4core/` — c4core runtime
- Plus c4core sub-deps `debugbreak/`, `fast_float/`

**`lib/CoreModules/4ms/core/` (per chosen module):**
- `Atvert2Core.cc`, `SlewCore.cc`, `NoiseCore.cc`, `PanCore.cc`, `SourceCore.cc`

### Header-only (just include paths)

- `lib/metamodule-plugin-sdk/core-interface/` — `INTERFACE` library, no .cc files
- `lib/flatbuffers/` — vendored flatbuffers headers (we compile our own `src/flatbuffers/encode.cc`)
- All `_info.hh` headers under `lib/CoreModules/4ms/info/` (auto-generated, already committed)

## Include paths

From the various `target_include_directories`:

```
plugins/4msCompany/src
plugins/4msCompany/lib
plugins/4msCompany/lib/CoreModules
plugins/4msCompany/lib/CoreModules/4ms
plugins/4msCompany/lib/CoreModules/4ms/core
plugins/4msCompany/lib/CoreModules/4ms/core/peg-common
plugins/4msCompany/lib/CoreModules/4ms/core/peg-common/mocks
plugins/4msCompany/lib/CoreModules/4ms/core/tapo
plugins/4msCompany/lib/CoreModules/4ms/core/tapo/stmlib
plugins/4msCompany/lib/CoreModules/4ms/core/alpaca/include
plugins/4msCompany/lib/CoreModules/4ms/core/looping-delay/src
plugins/4msCompany/lib/cpputil
plugins/4msCompany/lib/metamodule-plugin-sdk/core-interface
plugins/4msCompany/lib/metamodule-plugin-sdk/core-interface/filesystem
plugins/4msCompany/lib/patch-serial
plugins/4msCompany/lib/patch-serial/ryml
plugins/4msCompany/lib/patch-serial/ryml/rapidyaml/src
plugins/4msCompany/lib/patch-serial/ryml/rapidyaml/ext/c4core/src
plugins/4msCompany/lib/flatbuffers
```

## Compile defines

Per their CMake:
- `VCVRACK` — required, gates VCV-specific code paths
- `TEST` — used by `CoreModules-4ms` for some test-mode code; **keep an eye on whether this leaks runtime-only test code into release**
- `SAMPLE_RATE=48000` — embedded sample-rate constant for cores
- `ALPACA_NO_PREFETCH` — suppresses prefetch in the `alpaca` serializer (probably required since alpaca isn't in our compile set, but safe to set)

Plus Cardinal's standard `-DpluginInstance=pluginInstance__4ms`.

## Name clashes (model symbols)

Comparing 4ms model slugs against existing collections, **7 clashes**:
- `modelDetune`  (4ms vs. Befaco?)
- `modelFollow`
- `modelLPG`
- `modelNoise`        ← in our chosen set
- `modelOctave`
- `modelPan`          ← in our chosen set
- `modelSlew`         ← in our chosen set

Cardinal pattern: `#define modelXxx model4msXxx` around the include block in `plugins/plugins.cpp` (see e.g. `plugins.cpp:64` `#define modelBlank modelAriaBlank`).

For our chosen subset, only **3 clashes matter**: `modelNoise`, `modelPan`, `modelSlew`. Apply renames in plugins.cpp. The model object's `slug` (read from plugin.json) stays `Noise`/`Pan`/`Slew` so users still see "Noise" in the browser; only the C++ symbol changes.

## plugins.cpp wiring

Add at top with other extern decls:
```cpp
// 4ms Company
#define modelNoise model4msNoise
#define modelPan model4msPan
#define modelSlew model4msSlew
extern Model* modelHubMedium;
extern Model* modelAtvert2;
extern Model* modelSlew;
extern Model* modelNoise;
extern Model* modelPan;
extern Model* modelSource;
#undef modelNoise
#undef modelPan
#undef modelSlew
```

Add to global declaration block (near `plugins.cpp:957`):
```cpp
Plugin* pluginInstance__4ms;
```

Add new `initStatic__4ms()` function near the others (around `plugins.cpp:1152`):
```cpp
static void initStatic__4ms()
{
    Plugin* const p = new Plugin;
    pluginInstance__4ms = p;
    const StaticPluginLoader spl(p, "4msCompany");
    if (spl.ok())
    {
        p->addModel(modelHubMedium);
        p->addModel(modelAtvert2);
        p->addModel(model4msSlew);   // C++ symbol, slug stays "Slew"
        p->addModel(model4msNoise);
        p->addModel(model4msPan);
        p->addModel(modelSource);

        // Drop everything else from the manifest so the loader doesn't
        // expect models we haven't registered.
        for (const char* slug : {
            "EnOsc","DLD","Tapo","SHEV","DEV","ENVVCA","PEG","MPEG",
            "QCD","SCM","RCD","QPLFO","PI","VCAM","SISM","L4",
            "Freeverb","BWAVP","CLKM","CLKD","Seq8","Verb","StMix",
            "PitchShift","MultiLFO","KPLS","Drum","Djembe","Detune",
            "SH","Switch41","Switch14","Prob8","Octave","MNMX",
            "HPF","Gate","Follow","FM","ComplexEG","LPG","BPF",
            "MMAudioExpander","MMButtonExpander",
        }) {
            spl.removeModule(slug);
        }
    }
}
```

Add call inside `initStaticPlugins()` near line 3801, alphabetically after `Cardinal`/`Fundamental` setup:
```cpp
initStatic__4ms();
```

## Network stubbing

`src/network/network.cpp` calls Rack's `rack::network::request*` with a custom binary body. Cardinal's `src/custom/network.cpp` returns nothing for those calls. Rather than drop 4ms's `network.cpp` and hope nothing references the symbol, replace it with a minimal stub:

```cpp
// In a new file: src/CardinalSubst/4ms_network_stub.cc
#include <span>
#include <vector>
#include <network.hpp>
namespace MetaModule::network {
    std::vector<uint8_t> requestRaw(rack::network::Method, const std::string&,
                                    const std::span<uint8_t>&,
                                    const rack::network::CookieMap& = {}) {
        return {};  // WiFi push not supported in Cardinal
    }
}
```

Or define directly inside `plugins/plugins.cpp` next to the other namespace hacks.

## What's not yet figured out

1. **rapidyaml compilation.** Need to read `lib/patch-serial/ryml/rapidyaml/CMakeLists.txt`, list its sources and includes, port to a Makefile block. c4core has its own CMake too. **First-session blocker.**
2. **`SAMPLE_RATE` define.** Hardcoded to 48000 at compile time. If user runs Cardinal at 44.1k or 96k, the 4ms cores are still going to assume 48k internally. May need runtime correction or just accept the pitch shift on non-48k hosts.
3. **WHOLE_ARCHIVE linkage.** Their CMake uses `WHOLE_ARCHIVE` for `CoreModules-4ms` so static-init registrations don't get DCE'd. Cardinal's plugins are linked into a single `plugins.a` — if static-init registrations are stripped, the `ModuleFactory::create(slug)` lookup at module construction time returns nullptr and instantiation fails. May need explicit dummy refs to keep the registrations alive. Watch for this when testing.
4. **`hub_medium.cc` is double-built in upstream.** The CoreModules-4ms CMake explicitly compiles `../hub/hub_medium.cc` to work around a linker DCE issue. We compile it once at the top level — should be fine for our static link. Watch for missing-symbol errors for hub-related globals.
5. **Settings (WiFi URL persistence).** `settingsToJson`/`settingsFromJson` in upstream `plugin.cc` save the WiFi target URL across sessions. We're skipping `plugin.cc` so the user re-enters this each time — fine for our use case (we're not using WiFi push anyway).

## Order of operations for next session

1. ✅ Submodule added (commit `1f4c738`)
2. ✅ Survey, name clash analysis, integration plan (this doc)
3. ⏳ Map out rapidyaml's source list — read its CMakeLists, port to Makefile block
4. ⏳ Write `plugins/Makefile` section: PLUGIN_FILES + per-collection compile rule
5. ⏳ Write `plugins/plugins.cpp` section: extern decls + initStatic__4ms + initStaticPlugins() call
6. ⏳ Write network stub
7. ⏳ First build attempt — capture error log, file under a known name
8. ⏳ Iterate: missing includes → add path, missing symbols → check whether file should be in PLUGIN_FILES, compile errors in C++23 features → may need to bump cxx standard, etc.
9. ⏳ Once it links: launch CardinalNative, try to add HubMedium, Save Patch to a `.vcv`, verify file is well-formed flatbuffers.
10. ⏳ Test on MetaModule hardware (loads the saved patch from USB/SD).

## Known risks

- **Build size:** plugins.a is already large; adding 4ms tree (likely ~50–80 new compile units once rapidyaml is included) extends already-long Cardinal build times.
- **Cardinal namespace games:** Cardinal renames `DGL` → `CardinalDGL` and other namespaces. 4ms framework code uses raw `rack::*` namespace; should be transparent but watch for unexpected DGL refs.
- **C++23.** `CoreModules-4ms` uses `cxx_std_23`. Cardinal's default is whatever `Makefile.base.mk` sets (likely C++17 or C++20). Need `CXXFLAGS += -std=c++23` per-collection or per-file. macOS clang (Apple Clang 15+) supports it.
- **Static-init order.** `ModuleFactory` registrations happen at static-init. If their order interleaves badly with Rack's plugin init, may see crashes during `initStaticPlugins()` call.
