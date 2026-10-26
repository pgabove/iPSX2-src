// GameScreenView.swift — Unified game screen (Metal + Virtual Pad + Menu)
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import Combine
import GameController

struct GameScreenView: View {
    @State private var appState = AppState.shared
    @State private var settings = SettingsStore.shared
    @State private var padVisible = true
    @State private var fullScreen = false
    @State private var controllerConnected = false // [iPSX2 #12]

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            Group {
            if isLandscape {
                ZStack {
                    // Landscape: always use full screen area for Metal + pad
                    // so that pad coordinates match the layout editor exactly.
                    ZStack {
                        MetalGameView()
                        if padVisible {
                            VirtualControllerView(isLandscape: true)
                        }
                    }
                    .ignoresSafeArea()  // Always fullscreen layout in landscape
                    // [iPSX2 #12] The menu button stays inside the safe area, so it is never
                    // under the status bar (battery/clock) or the iPadOS window controls.
                    menuOverlay(isLandscape: true)
                }
            } else {
                // Portrait: Metal top half, pad bottom half, within safe area
                VStack(spacing: 0) {
                    MetalGameView()
                        .frame(height: geo.size.height / 2)
                    if padVisible {
                        VirtualControllerView()
                            .frame(height: geo.size.height / 2)
                    } else {
                        Spacer()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    menuOverlay(isLandscape: false)
                }
            }
            }
            // [iPSX2 #12] Keep the on-screen stats clear of the status bar / window controls.
            .onAppear { updateOverlaySafeArea(geo, isLandscape: isLandscape) }
            .onChange(of: geo.safeAreaInsets) { _, _ in updateOverlaySafeArea(geo, isLandscape: isLandscape) }
            .onChange(of: isLandscape) { _, newValue in updateOverlaySafeArea(geo, isLandscape: newValue) }
        }
        .onChange(of: fullScreen) { _, newValue in
            iPSX2Bridge.setFullScreen(newValue)
        }
        // [iPSX2 #12] Touch controls follow the physical controller.
        .onAppear { refreshControllerState(initial: true) }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshControllerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshControllerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("iPSX2GamepadConnectionChanged"))) { _ in
            refreshControllerState()
        }
    }

    /// [iPSX2 #12] In landscape the game image runs under the status bar / iPadOS window controls,
    /// so the renderer pushes the top stats down by that much. In portrait the game view already
    /// sits inside the safe area, so no offset is needed.
    private func updateOverlaySafeArea(_ geo: GeometryProxy, isLandscape: Bool) {
        let insets = geo.safeAreaInsets
        if isLandscape {
            iPSX2Bridge.setOverlaySafeAreaTop(insets.top, left: insets.leading, right: insets.trailing)
        } else {
            iPSX2Bridge.setOverlaySafeAreaTop(0, left: 0, right: 0)
        }
    }

    /// [iPSX2 #12] Any physical controller: one the GameController framework reports, or the one
    /// SDL opened for input.
    private static func isControllerConnected() -> Bool {
        !GCController.controllers().isEmpty || iPSX2Bridge.isGamepadConnected()
    }

    /// [iPSX2 #12] Touch controls hide when a controller connects and come back when the last one
    /// disconnects. The "Virtual Pad" toggle in the ••• menu still overrides this in between.
    private func refreshControllerState(initial: Bool = false) {
        let connected = Self.isControllerConnected()
        guard initial || connected != controllerConnected else { return }
        controllerConnected = connected
        if settings.autoHidePadWithController {
            padVisible = !connected
        }
    }

    private func menuOverlay(isLandscape: Bool) -> some View {
        VStack {
            HStack {
                Spacer()
                menuButton(isLandscape: isLandscape)
            }
            .padding(.top, isLandscape ? 8 : 4)
            .padding(.trailing, isLandscape ? 8 : 4)
            Spacer()
        }
    }

    private func menuButton(isLandscape: Bool) -> some View {
        Menu {
            Toggle(isOn: Binding(
                get: { settings.osdPreset != .off },
                set: { newValue in
                    if newValue {
                        settings.osdPreset = .simple
                        iPSX2Bridge.setPerformanceOverlayVisible(true)
                    } else {
                        settings.osdPreset = .off
                        iPSX2Bridge.setPerformanceOverlayVisible(false)
                    }
                }
            )) {
                Label("OSD", systemImage: "speedometer")
            }
            Toggle(isOn: $padVisible) {
                Label("Virtual Pad", systemImage: "gamecontroller")
            }
            if isLandscape {
                Toggle(isOn: $fullScreen) {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            Divider()
            Button {
                appState.returnToMenu()
            } label: {
                Label("Back to Menu", systemImage: "list.bullet")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.5))
                .padding(6)
                .background(.black.opacity(0.15), in: Circle())
        }
    }
}
