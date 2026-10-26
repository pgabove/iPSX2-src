// SaveStateStore.swift — Save-state slots of the running game
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

/// [iPSX2 #17] One PCSX2 save-state slot of the running game.
struct SaveStateSlot: Identifiable, Equatable {
    let id: Int      // slot number, 1-10
    let date: Date?  // nil = empty

    var isEmpty: Bool { date == nil }
}

/// [iPSX2 #17] Save/load state for the in-game menu. The states are PCSX2's per-game slot files
/// (Documents/sstates/<serial> (<crc>).NN.p2s); saving and loading run on the emulator thread at the
/// next frame, and the core shows progress and errors on the in-game OSD.
@Observable
final class SaveStateStore: @unchecked Sendable {
    static let shared = SaveStateStore()

    /// Slots of the running game; empty while no game with a disc serial is running (BIOS, ELF).
    private(set) var slots: [SaveStateSlot] = []
    /// A save or load is queued or running.
    private(set) var isBusy = false

    var isAvailable: Bool { !slots.isEmpty }
    var hasSavedState: Bool { slots.contains { !$0.isEmpty } }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var requestToken = 0

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Notification.Name("iPSX2SaveStateFinished"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.isBusy = false
            self?.refresh()
        })
        // The disc serial is known (or changed): its slots can be listed.
        observers.append(center.addObserver(
            forName: Notification.Name("iPSX2GameChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: Notification.Name("iPSX2VMDidShutdown"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.isBusy = false
            self?.slots = []
        })
    }

    /// Re-reads the slot files of the running game.
    func refresh() {
        guard let stamps = iPSX2Bridge.saveStateSlotTimestamps() else {
            slots = []
            return
        }
        slots = stamps.enumerated().map { index, stamp in
            let seconds = stamp.doubleValue
            return SaveStateSlot(id: index + 1, date: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil)
        }
    }

    func save(slot: Int) {
        request(slot: slot, save: true)
    }

    func load(slot: Int) {
        request(slot: slot, save: false)
    }

    private func request(slot: Int, save: Bool) {
        guard !isBusy else { return }
        let queued = save ? iPSX2Bridge.saveState(slot: slot) : iPSX2Bridge.loadState(slot: slot)
        guard queued else {
            refresh()
            return
        }
        isBusy = true
        requestToken += 1
        let token = requestToken
        // The emulator answers with iPSX2SaveStateFinished; this only covers a request that was
        // dropped because the game stopped first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isBusy, self.requestToken == token else { return }
            self.isBusy = false
            self.refresh()
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
