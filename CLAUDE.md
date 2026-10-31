# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

iPSX2 is a PS2 emulator for iOS, porting PCSX2/ARMSX2 to iPhone/iPad. Target: iOS 18+, arm64 only. Confirmed working on iOS 26 and iOS 18 via StikDebug & UTM-Dolphin.js.

## Build System

CMake generates an Xcode project; all actual compilation happens in Xcode/xcodebuild.

**Generate Xcode project (simulator):**
```sh
cmake -S cpp -B build-sim -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DiPSX2_REAL_DEVICE=OFF
```

**Generate Xcode project (real device):**
```sh
cmake -S cpp -B build-device -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DiPSX2_REAL_DEVICE=ON
```

**Build from command line:**
```sh
xcodebuild -project build-sim/iPSX2.xcodeproj \
  -scheme iPSX2 -sdk iphonesimulator \
  -configuration Debug build
```

Real-device IPAs are re-signed with Sideloadly before sideloading — code signing is intentionally disabled in CMake (`CODE_SIGNING_REQUIRED=NO`).

**IPA size (Signulous):** this fork's IPAs are installed through Signulous, which silently turns away an IPA bigger than the build already installed. CI (`.github/workflows/build-ipa.yml`) packs the IPA with `zip -9`, recompresses it with zopfli (`advzip -4`, kept only if the file listing matches), and reports the result as an `IPA size` annotation. Compare it with the previous build's before handing a build over.

**Built-in JIT helper:** run `scripts/fetch_stikjit.sh` before generating a real-device project. It downloads StikJIT 1.9.0 (MPL-2.0) into `cpp/3rdparty/StikJIT` (git-ignored); CMake then builds the `iPSX2JITHelper` app extension from its sources and embeds it as `iPSX2.app/PlugIns/iPSX2JITHelper.appex`. Without that folder the helper is skipped and iPSX2 works only with StikDebug.

No in-tree builds: CMake will error if `build/` is inside the source tree.

## Architecture

```
iPSX2-src-main/
├── cpp/              # C++/ObjC backend
│   ├── CMakeLists.txt       # Top-level build; adds common/ and pcsx2/
│   ├── common/              # Platform utilities (FileSystem, Threading, etc.)
│   ├── pcsx2/               # Core emulator (EE, IOP, GS, VU, SPU2, SIO…)
│   │   ├── arm64/           # arm64 JIT helpers (VIXL-based, partial)
│   │   ├── GS/Renderers/Metal/  # Metal renderer + .metal shaders
│   │   └── VMManager.cpp    # Central VM lifecycle (boot/pause/shutdown)
│   ├── ios_main.mm          # UIKit app entry; starts SDL3, spins emulator thread
│   ├── iPSX2Bridge.h/.mm    # ObjC++ class exposing emulator API to Swift
│   └── iPSX2-Bridging-Header.h  # Exposes ObjC types to Swift
└── swift/            # SwiftUI frontend
    ├── Views/               # SwiftUI screens
    │   ├── RootView.swift       # Top-level router (menu ↔ playing)
    │   ├── GameListView.swift   # ISO picker
    │   ├── GameScreenView.swift # In-game HUD wrapper
    │   ├── MetalGameView.swift  # UIViewRepresentable for Metal render surface
    │   ├── EmulatorView.swift   # Game screen + virtual pad
    │   ├── VirtualControllerView.swift
    │   └── Settings/            # Settings screens
    └── Models/
        ├── AppState.swift       # Screen state machine (menu/playing), boot actions
        ├── EmulatorBridge.swift # @Observable wrapper around iPSX2Bridge ObjC calls
        ├── SettingsStore.swift  # INI-backed settings via iPSX2Bridge getINI/setINI
        ├── PadLayoutStore.swift # Virtual pad button layout persistence
        ├── FileImportHandler.swift
        └── SwiftUIHost.swift    # UIHostingController bridging SwiftUI into UIKit
```

## Key Patterns

**C++ ↔ Swift boundary:** All calls cross via `iPSX2Bridge` (ObjC++ class). Swift calls `iPSX2Bridge.*()` directly through the bridging header. Never add direct C++ headers to Swift files.

**VM lifecycle notifications:** C++ posts `NSNotification` names (`iPSX2VMDidShutdown`, `iPSX2AutoBootDidStart`, `iPSX2ReturnToMenu`, `iPSX2EnterGameScreen`) that Swift observes. State changes flow one-way: C++ → notification → `AppState`.

**Settings:** All emulator settings read/written through `iPSX2Bridge getINI/setINI` which proxy to PCSX2's INI layer. Swift `SettingsStore` is the typed wrapper.

**Renderer:** Metal only. Shaders live in `cpp/pcsx2/GS/Renderers/Metal/*.metal` and are compiled into `default.metallib` by Xcode. The Metal layer is surfaced to SwiftUI via `MetalGameView` (UIViewRepresentable wrapping the view from `iPSX2Bridge.gameRenderView()`).

**JIT entitlement:** `Entitlements.plist` includes `com.apple.security.cs.allow-jit` — required for the emulator's JIT recompiler. Re-signing must preserve this.

**Built-in JIT:** `cpp/iPSX2BuiltInJIT.mm` (ARC) starts the helper extension (`swift/JITHelper/iPSX2JITHelper.swift`, Swift 5 mode, StikJIT sources compiled in) through the private NSExtension API and sends it iPSX2's PID and `Documents/StikJIT/pairingFile.plist`. The helper attaches over LocalDevVPN and runs legacy.js; iPSX2 notices the attach and calls `iPSX2_ActivateBuiltInJIT()` (ios_main.mm), which does the same brk #0x69 code-memory handshake as a StikDebug launch. This only works before the first VM thread starts in a launch.

**JIT code writes (iOS 26+ / TXM dual-map):** the code region is mapped twice. Code *runs* from the RX view and must be *written* through the RW alias at `rx + DarwinMisc::g_code_rw_offset` (`HostSys::BeginCodeWrite` does nothing in this mode, and writing to the RX view is a SIGBUS). `arm64/VixlHelpers.cpp` (EE/IOP/VU/VIF recompilers) and `GS/Renderers/Common/GSFunctionMap.h` (software rasterizer JIT) apply the offset and hand out the RX address; any new code generator must do the same. The offset is 0 in the other JIT modes.

**Crash logs:** an unrecoverable fault prints a `@@FATAL_FAULT@@` block (pc, fault address, ESR class, page-fault path, image offsets, frame walk) just before `Aborting application.`. The previous two sessions are kept as `pcsx2_log.prev.txt` / `pcsx2_log.prev2.txt`.

**EE register slots vs. microVU (COP2 macro mode):** the EE allocator has 5 slots (`iREGCNT_GPR`), and slot N lives in host register `HostGprPhys(N)` (x19–x24, see `x86/iCore.h`). microVU's allocator indexes `gprMap` by host register number and emits `armWRegister(i)`, so when it borrows EE slots in COP2 mode the two disagree about where a VI register is. Every macro op that touches VI registers therefore runs on the interpreter (`INTERPRETATE_COP2_FUNC` in `microVU_Macro.inl`). Also in macro mode the code runs inside EE blocks, where x28 is `&psxRegs`, not `&g_vuRegistersPack`: `PTR_MVU()` is wrong there (use an x27-relative address, see `mVUdivFlagMem`).

**`armStorePtr(imm, ...)`** stores 32 bits unless an X register is passed (the zero case used to store `xzr`, 8 bytes).

**Diagnostics (Settings › Emulator › Diagnostics):** INI `iPSX2/Debug` `COP2MacroMode` / `VIFUnpackMode` / `FPUMode` = 0 JIT, 1 Interpreter, 2 Check (run both, log `@@COP2_CHECK@@` / `@@VIF_CHECK@@` / `@@FPU_CHECK@@` mismatches, keep the interpreter's result). Read by `VMManager::LoadSettings()` (`iPSX2Diagnostics.h`); boot logs a `@@DIAG@@` line.

**`Host::RunOnCPUThread` (ios_main.mm):** a real queue now (it was an empty stub, so core code deferred to the CPU thread never ran). Drained in `Host::PumpMessagesOnCPUThread()` at every guest vsync (the point PCSX2's save-state hotkeys run at) and in the VM thread's paused loop; runs directly when already on the VM thread; dropped when a VM starts or stops.

**Save states:** `VMManager::SaveStateToSlot` / `LoadStateFromSlot` (slots 1-10, `Documents/sstates/<serial> (<crc>).NN.p2s`) queued through `iPSX2_RequestSaveState` → `iPSX2Bridge saveStateToSlot:/loadStateFromSlot:`; results come back as `iPSX2SaveStateFinished`, `iPSX2GameChanged` tells `SaveStateStore` to re-list slots. The iOS build has no PNG encoder, so `SaveState_SaveScreenshot()` returns nullptr there (a screenshot that can't be compressed fails the whole save). Logs `@@SAVESTATE@@`.

**Controller vibration (`iPSX2Rumble.mm`, ARC):** `PadDualshock2::Poll` → `iPSX2_UpdatePadVibration` → GameController haptics (CoreHaptics) on a serial queue: large motor on the left handle, small on the right (one engine if the controller has no per-handle localities), watchdog stops motors when updates stop. Only controllers iPadOS exposes `GCController.haptics` for can rumble (not reachable any other way from an app). INI `iPSX2/Gamepad` `Vibration` / `VibrationStrength`. Logs `@@RUMBLE@@` (controller, localities, first request).

**Controller menus and shortcuts (`swift/Models/ControllerNavigator.swift`):** polls `GCController.current` on the main thread at 60 Hz (the emulator reads the same controller through SDL on the CPU thread). The Open Menu shortcut (default `Button Home`) pauses the VM (`iPSX2Bridge setEmulationPaused:` → `Host::RunOnCPUThread` → `VMManager::SetPaused`) and shows `ControllerMenuView`. That menu is built from plain views, not Buttons, because iPadOS's focus engine already moves with the D-pad and would also react to A. The VM resumes only once all controller buttons are released, so the button that closed the menu doesn't reach the game. Quick Save is a press and Quick Load a 0.5 s hold, both on slot 1. Shortcuts are GameController element names stored in INI `iPSX2/Shortcuts` and assigned in Settings by pressing a button; the buttons a controller exposes are logged as `@@CONTROLLER@@`. On the menu screens the left stick posts `iPSX2ControllerMove`, which `GameListView` turns into `@FocusState` moves. `iPSX2/Gamepad` `LeftStickAsDpad` (default on, read in `PumpMessagesOnCPUThread`) makes the controller's left stick also press the PS2 D-pad, with hysteresis, for game menus that ignore the stick.

**Swift version:** Swift 6.0, strict concurrency. Shared singletons (`AppState.shared`, `EmulatorBridge.shared`) are marked `@unchecked Sendable` to cross the actor boundary since they call ObjC synchronously.

## 3rd-Party Dependencies (vendored under `cpp/3rdparty/`)

SDL3, fmt, vixl (arm64 code gen), imgui, rapidyaml, libchdr, libzip, cubeb, rcheevos, freetype, soundtouch, lz4, lzma, zstd.
