// JITCardView.swift — Games screen card: why JIT is off and how to turn it on
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UniformTypeIdentifiers

/// Shown on the Games screen while JIT is off or turning on.
struct JITCardView: View {
    @State private var jit = BuiltInJITModel.shared
    @State private var showImporter = false
    @State private var importError: String?

    private var deviceFolder: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if jit.isBusy {
                busyView
            } else {
                header
                if let error = jit.errorText {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                if jit.isAvailable {
                    builtInSteps
                } else {
                    stikDebugSteps
                }
            }
        }
        .padding(.vertical, 4)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            importError = jit.importPairingFile(result)
        }
    }

    private var busyView: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("Turning on JIT…")
                    .font(.headline)
                Text(jit.statusText ?? "Starting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(jit.jitStatus == 2 ? "JIT script missing" : "JIT is off", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Without JIT, games run in a very slow backup mode. Menus may work, but fights, 3D scenes and loading screens can stay black.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var builtInSteps: some View {
        if jit.problem == .restartNeeded {
            Text("Close iPSX2 completely (swipe it away in the app switcher) and open it again. Then turn on JIT before you start a game.")
                .font(.subheadline)
                .fontWeight(.semibold)
        } else if !jit.hasPairingFile {
            Text("Turn on JIT inside iPSX2 (one-time setup):")
                .font(.subheadline)
                .fontWeight(.semibold)
            step(1, "Open the Files app and go to \(deviceFolder) › StikDebug. The file pairingFile.plist is there.")
            step(2, "Come back here, tap Import Pairing File and pick that file.")
            step(3, "Make sure LocalDevVPN is connected, then tap Turn On JIT.")
            HStack(spacing: 10) {
                Button("Import Pairing File") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                Button(jit.localDevVPNTitle) { jit.openLocalDevVPN() }
                    .buttonStyle(.bordered)
            }
            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Text("You can also keep using StikDebug: open iPSX2 from StikDebug with the legacy.js script assigned to iPSX2.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(jit.problem == .notConnected
                 ? "Connect LocalDevVPN first, then tap Turn On JIT."
                 : "LocalDevVPN must be connected. Then tap Turn On JIT.")
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack(spacing: 10) {
                Button("Turn On JIT") { jit.enable() }
                    .buttonStyle(.borderedProminent)
                Button(jit.localDevVPNTitle) { jit.openLocalDevVPN() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var stikDebugSteps: some View {
        if let reason = jit.unavailableReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Text(jit.jitStatus == 2
             ? "In StikDebug, press and hold iPSX2, tap Assign Script and choose legacy.js. Then close iPSX2 and open it from StikDebug again."
             : "Close iPSX2, then open it from StikDebug (with the legacy.js script assigned to iPSX2).")
            .font(.subheadline)
            .fontWeight(.semibold)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(text)
                .font(.subheadline)
        }
    }
}
