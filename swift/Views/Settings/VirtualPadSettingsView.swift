// VirtualPadSettingsView.swift — Virtual pad opacity, haptic, layout editing
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct VirtualPadSettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var showLayoutEditor = false

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading) {
                    Text("Opacity: \(Int(settings.padOpacity * 100))%")
                    Slider(value: $settings.padOpacity, in: 0.1...1.0, step: 0.05)
                }
            }

            Section("Feedback") {
                Toggle("Haptic Feedback", isOn: $settings.hapticFeedback)
            }

            // [iPSX2 #12]
            Section {
                Toggle("Hide When a Controller Is Connected", isOn: $settings.autoHidePadWithController)
            } footer: {
                Text("The touch controls disappear when you connect a game controller and come back when it disconnects. You can still show them from the ••• menu in a game.")
            }

            Section("Layout") {
                Button {
                    showLayoutEditor = true
                } label: {
                    Label("Edit Layout", systemImage: "square.resize")
                }
                Text("Drag buttons to reposition. Pinch to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Virtual Pad")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showLayoutEditor) {
            PadLayoutEditView()
        }
    }
}
