// GameListView.swift — ROM list with favorites
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct ISOEntry: Identifiable {
    let id = UUID()
    let name: String
    let size: UInt64
    var isFavorite: Bool
}

struct GameListView: View {
    @State private var games: [ISOEntry] = []
    @State private var appState = AppState.shared
    @State private var showRestartAlert = false
    @State private var showStopAlert = false
    @State private var pendingGameName: String = ""
    // Without JIT every CPU core silently falls back to the interpreter, so make it visible.
    // 0 = ready, 1 = not opened from StikDebug, 2 = StikDebug attached but no JIT script.
    @State private var jitStatus: Int = iPSX2Bridge.jitStatus()

    var sortedGames: [ISOEntry] {
        games.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if games.isEmpty && appState.runningGameName == nil {
                    emptyState
                } else {
                    List {
                        if jitStatus != 0 {
                            Section {
                                jitWarning
                            }
                        }
                        if let gameName = appState.runningGameName {
                            vmStatusSection(gameName: gameName)
                        }
                        ForEach(sortedGames) { game in
                            gameRow(game)
                        }
                    }
                }
            }
            .navigationTitle("Games")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { loadGames() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if iPSX2Bridge.hasBIOS() {
                        Button("BIOS Only") {
                            if appState.runningGameName == "BIOS" {
                                appState.returnToGame()
                            } else if appState.runningGameName != nil {
                                pendingGameName = ""
                                showRestartAlert = true
                            } else {
                                appState.bootBIOSOnly()
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .alert("Restart VM?", isPresented: $showRestartAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Restart", role: .destructive) {
                    if pendingGameName.isEmpty {
                        appState.shutdownAndBootBIOS()
                    } else {
                        appState.shutdownAndBoot(isoName: pendingGameName)
                    }
                }
            } message: {
                let target = pendingGameName.isEmpty ? "BIOS Only" : pendingGameName
                Text("VM is currently running.\nShut down and start \(target)?")
            }
        }
        .onAppear {
            loadGames()
            jitStatus = iPSX2Bridge.jitStatus()
        }
    }

    private var jitWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(jitStatus == 2 ? "JIT script missing" : "JIT is off", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(jitStatus == 2
                 ? "StikDebug is attached, but no script answered iPSX2's JIT request, so games would run in a very slow backup mode."
                 : "iPSX2 was opened without JIT, so games run in a very slow backup mode. Menus may work, but fights, 3D scenes and loading screens can stay black.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(jitStatus == 2
                 ? "In StikDebug, press and hold iPSX2, tap Assign Script and choose legacy.js. Then close iPSX2 and open it from StikDebug again."
                 : "Close iPSX2, then open it from StikDebug (with the legacy.js script assigned to iPSX2).")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.vertical, 4)
    }

    private func vmStatusSection(gameName: String) -> some View {
        Section {
            // Resume row — tap anywhere to return to game
            Button {
                appState.returnToGame()
            } label: {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now Running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(gameName == "BIOS" ? "BIOS Only" : gameName)
                            .font(.body)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                    Text("Resume")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .tint(.primary)

            // Stop button — separate row with confirmation alert
            Button(role: .destructive) {
                showStopAlert = true
            } label: {
                HStack {
                    Spacer()
                    Label("Stop Emulation", systemImage: "stop.circle")
                        .font(.subheadline)
                    Spacer()
                }
            }
        }
        .alert("Stop Emulation?", isPresented: $showStopAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Stop", role: .destructive) {
                iPSX2Bridge.requestVMStop()
                appState.runningGameName = nil
            }
        } message: {
            Text("This will shut down the running game. All unsaved progress will be lost.")
        }
    }

    private func gameRow(_ game: ISOEntry) -> some View {
        Button {
            if game.name == appState.runningGameName {
                appState.returnToGame()
            } else if appState.runningGameName != nil {
                pendingGameName = game.name
                showRestartAlert = true
            } else {
                appState.bootGame(isoName: game.name)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(game.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if game.name == appState.runningGameName {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(formatSize(game.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    toggleFavorite(game.name)
                } label: {
                    Image(systemName: game.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(game.isFavorite ? .yellow : .gray)
                }
                .buttonStyle(.plain)

                Image(systemName: game.name == appState.runningGameName ? "play.fill" : "chevron.right")
                    .foregroundStyle(game.name == appState.runningGameName ? .green : .secondary)
                    .font(.caption)
            }
        }
        .foregroundStyle(.primary)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if jitStatus != 0 {
                jitWarning
                    .padding()
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            Image(systemName: "opticaldisc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Games Found")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Place ISO/BIN/CHD/IMG files in:\nDocuments/iso/")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Use the Files app or iTunes File Sharing\nto transfer game files.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func loadGames() {
        let isoDir = iPSX2Bridge.isoDirectory()
        let docsDir = iPSX2Bridge.documentsDirectory()
        let fileNames = iPSX2Bridge.availableISOs()
        let fm = FileManager.default
        games = fileNames.map { name in
            var path = (isoDir as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: path) {
                path = (docsDir as NSString).appendingPathComponent(name)
            }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? UInt64 ?? 0
            let fav = iPSX2Bridge.isFavorite(name)
            return ISOEntry(name: name, size: size, isFavorite: fav)
        }
    }

    private func toggleFavorite(_ name: String) {
        let current = iPSX2Bridge.isFavorite(name)
        iPSX2Bridge.setFavorite(name, favorite: !current)
        loadGames()
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
