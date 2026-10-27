// GamepadSettingsView.swift — Virtual pad + controller mapping
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import GameController

private struct PS2Button: Identifiable {
    let id: Int
    let name: String
}

private let ps2Buttons: [PS2Button] = [
    PS2Button(id: 0,  name: "D-Pad Up"),
    PS2Button(id: 1,  name: "D-Pad Down"),
    PS2Button(id: 2,  name: "D-Pad Left"),
    PS2Button(id: 3,  name: "D-Pad Right"),
    PS2Button(id: 4,  name: "Cross"),
    PS2Button(id: 5,  name: "Circle"),
    PS2Button(id: 6,  name: "Square"),
    PS2Button(id: 7,  name: "Triangle"),
    PS2Button(id: 8,  name: "L1"),
    PS2Button(id: 9,  name: "R1"),
    PS2Button(id: 12, name: "Start"),
    PS2Button(id: 13, name: "Select"),
    PS2Button(id: 14, name: "L3"),
    PS2Button(id: 15, name: "R3"),
]

// SDL_GamepadButton → display name (matches SDL3 enum order)
private func sdlButtonName(_ idx: Int) -> String {
    switch idx {
    case 0:  return "A / Cross"
    case 1:  return "B / Circle"
    case 2:  return "X / Square"
    case 3:  return "Y / Triangle"
    case 4:  return "Share / Back"
    case 5:  return "Guide / PS"
    case 6:  return "Options / Start"
    case 7:  return "L-Stick Press"
    case 8:  return "R-Stick Press"
    case 9:  return "L-Shoulder"
    case 10: return "R-Shoulder"
    case 11: return "D-Pad Up"
    case 12: return "D-Pad Down"
    case 13: return "D-Pad Left"
    case 14: return "D-Pad Right"
    case 15: return "Misc / Share"
    case 20: return "Touchpad"
    default: return "Button \(idx)"
    }
}

struct GamepadSettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var capturingIndex: Int? = nil
    @State private var mappingVersion = 0
    @State private var pollTimer: Timer? = nil
    @State private var vibrationStatus = 0       // [iPSX2 #17] see iPSX2Bridge.controllerVibrationStatus
    @State private var vibrationController = ""
    @State private var navigator = ControllerNavigator.shared // [iPSX2 #18] shortcut capture

    var body: some View {
        Form {
            // [iPSX2 #17] DualShock 2 vibration on the controller.
            Section {
                Toggle("Vibration", isOn: $settings.vibrationEnabled)
                if settings.vibrationEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Strength")
                            Spacer()
                            Text("\(Int((settings.vibrationStrength * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.vibrationStrength, in: 0.25...2.0, step: 0.25)
                    }
                    Button("Test Vibration") {
                        refreshVibrationStatus()
                        iPSX2Bridge.testControllerVibration()
                    }
                    .disabled(vibrationStatus != 2)
                }
            } header: {
                Text("Vibration")
            } footer: {
                Text(vibrationFooter)
            }

            // [iPSX2 #18] Menus and shortcuts.
            Section {
                Toggle("Left Stick Moves the D-pad Too", isOn: $settings.leftStickAsDpad)
            } header: {
                Text("Controls")
            } footer: {
                Text("Lets the left stick move through game menus that only listen to the D-pad, like BT4's. Turn it off if a game uses the D-pad for something else.")
            }

            Section {
                ForEach(ControllerShortcut.allCases) { shortcut in
                    shortcutRow(shortcut)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Tap a shortcut, then press the controller button for it. Pick buttons the game doesn't use, like the Stadia controller's Assistant and Capture buttons. If nothing happens when you press a button, iPadOS doesn't pass that button to apps; tap the row again to cancel. Quick Load needs a half-second hold so a bump can't throw away your progress.")
            }

            Section {
                ForEach(ps2Buttons) { btn in
                    mappingRow(btn)
                }
            } header: {
                Text("Button Mapping")
            } footer: {
                Text("Tap a row, then press a button on your controller to assign it. L2/R2 are analog triggers (not remappable).")
            }

            Section {
                Button("Reset to Default") {
                    iPSX2Bridge.resetButtonMappings()
                    mappingVersion += 1
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Game Controller")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshVibrationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshVibrationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshVibrationStatus()
        }
        .onDisappear {
            stopCapture()
            navigator.capturing = nil
        }
    }

    /// [iPSX2 #18] Shortcut name, the assigned button (or "Press a button…" while capturing), clear.
    @ViewBuilder
    private func shortcutRow(_ shortcut: ControllerShortcut) -> some View {
        let isCapturing = navigator.capturing == shortcut
        let button = settings.button(for: shortcut)
        HStack {
            Button {
                navigator.capturing = isCapturing ? nil : shortcut
            } label: {
                HStack {
                    Text(shortcut.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isCapturing {
                        Text("Press a button…")
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    } else {
                        Text(button.isEmpty ? "Not set" : ControllerNavigator.displayName(for: button))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if !button.isEmpty && !isCapturing {
                Button {
                    settings.setButton("", for: shortcut)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear")
            }
        }
        .listRowBackground(isCapturing ? Color.orange.opacity(0.15) : nil)
    }

    /// [iPSX2 #17] Whether iPadOS lets apps vibrate the connected controller.
    private func refreshVibrationStatus() {
        vibrationStatus = iPSX2Bridge.controllerVibrationStatus()
        vibrationController = iPSX2Bridge.controllerName() ?? ""
    }

    private var vibrationFooter: String {
        switch vibrationStatus {
        case 2:
            return "\(vibrationController) supports vibration. Games that use the DualShock 2's motors rumble the controller (large motor on the left, small motor on the right)."
        case 1:
            return "iPadOS doesn't give apps access to the vibration motors of \(vibrationController), so it can't rumble. Vibration works with controllers iPadOS supports it for, such as PlayStation (DualShock 4, DualSense) and Xbox Wireless controllers."
        default:
            return "Connect a controller to use vibration."
        }
    }

    @ViewBuilder
    private func mappingRow(_ btn: PS2Button) -> some View {
        let isCapturing = capturingIndex == btn.id
        let currentSDL = Int(iPSX2Bridge.getButtonMapping(Int32(btn.id)))

        Button {
            if isCapturing {
                stopCapture()
            } else {
                startCapture(for: btn.id)
            }
        } label: {
            HStack {
                // Left: assigned controller button (prominent)
                if isCapturing {
                    Text("Press a button...")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                } else {
                    Text(sdlButtonName(currentSDL))
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                Spacer()
                // Right: PS2 function name (secondary)
                Text(btn.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(mappingVersion)
        }
        .listRowBackground(isCapturing ? Color.orange.opacity(0.15) : nil)
    }

    private func startCapture(for ps2Index: Int) {
        capturingIndex = ps2Index
        iPSX2Bridge.startButtonCapture()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                iPSX2Bridge.pollGamepadForCapture()
                let captured = iPSX2Bridge.capturedButton()
                if captured >= 0 {
                    iPSX2Bridge.setButtonMapping(Int32(ps2Index), toSDLButton: captured)
                    stopCapture()
                    mappingVersion += 1
                }
            }
        }
    }

    private func stopCapture() {
        pollTimer?.invalidate()
        pollTimer = nil
        capturingIndex = nil
        iPSX2Bridge.stopButtonCapture()
    }
}
