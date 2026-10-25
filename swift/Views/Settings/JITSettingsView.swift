// JITSettingsView.swift — Settings › JIT: built-in JIT (StikJIT helper) setup
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UniformTypeIdentifiers

struct JITSettingsView: View {
    @State private var jit = BuiltInJITModel.shared
    @State private var showImporter = false
    @State private var confirmRemove = false

    private var deviceFolder: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("JIT")
                    Spacer()
                    Text(jit.isJITOn ? "On" : "Off")
                        .fontWeight(.semibold)
                        .foregroundStyle(jit.isJITOn ? .green : .red)
                }
                if jit.isBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(jit.statusText ?? "Working…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = jit.errorText, !jit.isBusy {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !jit.isJITOn {
                    Button("Turn On JIT") { jit.enable() }
                        .disabled(jit.isBusy || !jit.isAvailable || !jit.hasPairingFile)
                }
            } footer: {
                Text("Built-in JIT does what StikDebug does, from inside iPSX2: its helper attaches to iPSX2 through LocalDevVPN. It needs this device's pairing file and LocalDevVPN connected.")
            }

            if let reason = jit.unavailableReason {
                Section {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Text("Pairing File")
                    Spacer()
                    Text(jit.hasPairingFile ? "Imported" : "Missing")
                        .foregroundStyle(jit.hasPairingFile ? Color.green : Color.secondary)
                }
                Button(jit.hasPairingFile ? "Replace Pairing File" : "Import Pairing File") { showImporter = true }
                if jit.hasPairingFile {
                    Button("Remove Pairing File", role: .destructive) { confirmRemove = true }
                }
                if let message = jit.pairingImportMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(jit.pairingImportFailed ? Color.red : Color.green)
                }
            } header: {
                Text("Pairing File")
            } footer: {
                Text("Use the same pairing file StikDebug uses: in the Files app it is in \(deviceFolder) › StikDebug › pairingFile.plist. You can also copy it into iPSX2's own folder.")
            }

            Section {
                Toggle("Turn On JIT When iPSX2 Opens", isOn: Binding(
                    get: { jit.enableAtLaunch },
                    set: { jit.setEnableAtLaunch($0) }
                ))
                HStack {
                    Text("LocalDevVPN")
                    Spacer()
                    Text(!jit.isLocalDevVPNInstalled ? "Not installed" : (jit.isLocalDevVPNConnected ? "Connected" : "Not connected"))
                        .foregroundStyle(jit.isLocalDevVPNConnected ? Color.green : Color.secondary)
                }
                Toggle("Connect LocalDevVPN Automatically", isOn: Binding(
                    get: { jit.autoConnectLocalDevVPN },
                    set: { jit.setAutoConnectLocalDevVPN($0) }
                ))
                Button(jit.localDevVPNTitle) { jit.openLocalDevVPN() }
                Button("Check Setup") { jit.checkSetup() }
                    .disabled(jit.isBusy || !jit.isAvailable || !jit.hasPairingFile)
                if let check = jit.setupCheckText {
                    Text(check)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Reset Developer Disk Image") { jit.resetDeveloperDiskImage() }
                    .disabled(jit.isBusy || !jit.isAvailable)
            } header: {
                Text("Built-in JIT")
            } footer: {
                Text("With Connect LocalDevVPN Automatically on, iPSX2 opens LocalDevVPN for a moment when its tunnel is off, and LocalDevVPN sends you straight back. Check Setup tests LocalDevVPN and downloads and mounts Apple's Developer Disk Image (once per restart of the device). If setup keeps failing after an iOS update, reset the Developer Disk Image, restart the device and try again.")
            }
        }
        .navigationTitle("JIT")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { jit.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: BuiltInJITModel.pairingFileTypes) { result in
            jit.importPairingFile(result)
        }
        .alert("Remove the pairing file?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                jit.removePairingFile()
            }
        } message: {
            Text("Built-in JIT stops working until you import it again. StikDebug keeps its own copy.")
        }
    }
}
