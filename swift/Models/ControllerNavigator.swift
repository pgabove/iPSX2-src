// ControllerNavigator.swift — Game controller shortcuts and menu navigation
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import GameController

/// [iPSX2 #18] What a controller button can do outside the PS2 game.
enum ControllerShortcut: String, CaseIterable, Identifiable, Sendable {
    case openMenu = "OpenMenu"
    case quickSave = "QuickSave"
    case quickLoad = "QuickLoad"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openMenu: return "Pause Menu"
        case .quickSave: return "Quick Save (Slot 1)"
        case .quickLoad: return "Quick Load (Slot 1, hold)"
        }
    }

    /// Used until the user picks a button. The Home button (the Stadia, PS or Xbox button) opens the
    /// pause menu; the extra buttons differ per controller, so quick save/load start unassigned.
    var defaultButton: String {
        switch self {
        case .openMenu: return "Button Home"
        case .quickSave, .quickLoad: return ""
        }
    }
}

/// [iPSX2 #18] A row of the controller pause menu.
struct ControllerMenuItem: Identifiable {
    enum Action {
        case resume, showSave, showLoad, backToMenu, back
        case save(Int), load(Int)
    }

    let id: Int
    let title: String
    let detail: String?
    let isEnabled: Bool
    let action: Action
}

/// [iPSX2 #18] Controller input outside the PS2 game: the pause menu (opened with a controller
/// button, moved through with the D-pad or the left stick, A to choose, B to go back), the quick
/// save/load shortcuts, left-stick moves for the game list, and button capture for Settings. It polls
/// the GameController framework on the main thread; the emulator reads the same controller via SDL.
@MainActor
@Observable
final class ControllerNavigator {
    static let shared = ControllerNavigator()
    static let quickSlot = 1
    /// Posted with userInfo["direction"] = "up"/"down"/"left"/"right" when the left stick is pushed
    /// on the menu screens (the D-pad already moves iPadOS's own focus there).
    static let moveNotification = Notification.Name("iPSX2ControllerMove")

    enum Page { case main, save, load }
    enum MoveDirection: String { case up, down, left, right }

    private(set) var isMenuOpen = false
    private(set) var page: Page = .main
    private(set) var selection = 0
    private(set) var message: String?
    /// Settings › Game Controller is waiting for a button for this shortcut.
    var capturing: ControllerShortcut?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var previousButtons: Set<String> = []
    @ObservationIgnored private var heldMove: MoveDirection?
    @ObservationIgnored private var nextRepeat: TimeInterval = 0
    @ObservationIgnored private var pausedByMenu = false
    @ObservationIgnored private var resumePending = false
    @ObservationIgnored private var resumePendingSince: TimeInterval = 0
    @ObservationIgnored private var quickLoadHeldSince: TimeInterval?
    @ObservationIgnored private var quickLoadFired = false
    @ObservationIgnored private var awaiting: (slot: Int, save: Bool)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Notification.Name("iPSX2SaveStateFinished"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let slot = (info?["slot"] as? NSNumber)?.intValue ?? 0
            let save = (info?["save"] as? NSNumber)?.boolValue ?? false
            let ok = (info?["ok"] as? NSNumber)?.boolValue ?? false
            let reason = info?["message"] as? String ?? ""
            MainActor.assumeIsolated {
                self?.saveStateFinished(slot: slot, save: save, ok: ok, reason: reason)
            }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("iPSX2VMDidShutdown"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reset()
            }
        })
    }

    // MARK: - Pause menu

    var title: String {
        switch page {
        case .main: return "Paused"
        case .save: return "Save State"
        case .load: return "Load State"
        }
    }

    var items: [ControllerMenuItem] {
        let states = SaveStateStore.shared
        switch page {
        case .main:
            return [
                ControllerMenuItem(id: 0, title: "Resume", detail: nil, isEnabled: true, action: .resume),
                ControllerMenuItem(id: 1, title: "Save State", detail: nil, isEnabled: states.isAvailable, action: .showSave),
                ControllerMenuItem(id: 2, title: "Load State", detail: nil, isEnabled: states.hasSavedState, action: .showLoad),
                ControllerMenuItem(id: 3, title: "Back to Menu", detail: nil, isEnabled: true, action: .backToMenu),
            ]
        case .save, .load:
            let saving = page == .save
            var rows = states.slots.map { slot in
                ControllerMenuItem(
                    id: slot.id,
                    title: slot.id == Self.quickSlot ? "Slot \(slot.id) (Quick)" : "Slot \(slot.id)",
                    detail: slot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Empty",
                    isEnabled: !states.isBusy && (saving || !slot.isEmpty),
                    action: saving ? .save(slot.id) : .load(slot.id))
            }
            rows.append(ControllerMenuItem(id: 100, title: "Back", detail: nil, isEnabled: true, action: .back))
            return rows
        }
    }

    /// Pauses the game and shows the menu.
    func open() {
        guard !isMenuOpen else { return }
        SaveStateStore.shared.refresh()
        page = .main
        selection = 0
        message = nil
        awaiting = nil
        heldMove = nil
        resumePending = false
        isMenuOpen = true
        if !pausedByMenu {
            pausedByMenu = true
            iPSX2Bridge.setEmulationPaused(true)
        }
        iPSX2Bridge.log("[Controller] pause menu opened")
    }

    /// Hides the menu; the game resumes once the controller's buttons are let go, so the button that
    /// closed the menu doesn't also reach the game.
    func close(resume: Bool = true) {
        guard isMenuOpen else { return }
        isMenuOpen = false
        page = .main
        message = nil
        awaiting = nil
        if resume && pausedByMenu {
            resumePending = true
            resumePendingSince = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Chooses a row (A button or a tap).
    func activate(index: Int) {
        let rows = items
        guard rows.indices.contains(index) else { return }
        selection = index
        let item = rows[index]
        guard item.isEnabled else { return }
        switch item.action {
        case .resume:
            close(resume: true)
        case .showSave:
            show(.save)
        case .showLoad:
            show(.load)
        case .backToMenu:
            close(resume: true)
            AppState.shared.returnToMenu()
        case .back:
            goBack()
        case .save(let slot):
            request(slot: slot, save: true)
        case .load(let slot):
            request(slot: slot, save: false)
        }
    }

    private func request(slot: Int, save: Bool) {
        let states = SaveStateStore.shared
        message = save ? "Saving to slot \(slot)…" : "Loading slot \(slot)…"
        awaiting = (slot, save)
        if save {
            states.save(slot: slot)
        } else {
            states.load(slot: slot)
        }
        if !states.isBusy {
            // Not queued: the game stopped or has no disc serial.
            awaiting = nil
            message = save ? "Couldn't save right now." : "Couldn't load right now."
        }
    }

    private func show(_ newPage: Page) {
        SaveStateStore.shared.refresh()
        page = newPage
        message = nil
        selection = 0
        if let first = items.first, !first.isEnabled {
            moveSelection(by: 1)
        }
    }

    private func goBack() {
        guard page != .main else {
            close(resume: true)
            return
        }
        let previous = page
        page = .main
        message = nil
        selection = previous == .save ? 1 : 2
    }

    private func moveSelection(by delta: Int) {
        let rows = items
        guard !rows.isEmpty else { return }
        var index = selection
        for _ in 0..<rows.count {
            index = (index + delta + rows.count) % rows.count
            if rows[index].isEnabled {
                selection = index
                return
            }
        }
    }

    private func saveStateFinished(slot: Int, save: Bool, ok: Bool, reason: String) {
        guard isMenuOpen, let awaiting, awaiting.slot == slot, awaiting.save == save else { return }
        self.awaiting = nil
        guard ok else {
            message = reason.isEmpty ? (save ? "Couldn't save to slot \(slot)." : "Couldn't load slot \(slot).") : reason
            return
        }
        message = save ? "Saved to slot \(slot)." : "Loaded slot \(slot)."
        DispatchQueue.main.asyncAfter(deadline: .now() + (save ? 0.8 : 0.3)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMenuOpen, self.awaiting == nil else { return }
                self.close(resume: true)
            }
        }
    }

    private func finishResume() {
        resumePending = false
        guard pausedByMenu else { return }
        pausedByMenu = false
        iPSX2Bridge.setEmulationPaused(false)
    }

    private func reset() {
        isMenuOpen = false
        page = .main
        message = nil
        awaiting = nil
        pausedByMenu = false
        resumePending = false
    }

    // MARK: - Polling

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let controller = GCController.current ?? GCController.controllers().first else {
            previousButtons = []
            heldMove = nil
            quickLoadHeldSince = nil
            if resumePending {
                finishResume()
            }
            return
        }

        var pressed = Set<String>()
        for (name, button) in controller.physicalInputProfile.buttons where button.isPressed {
            pressed.insert(name)
        }
        let newlyPressed = pressed.subtracting(previousButtons)
        previousButtons = pressed

        if resumePending && (pressed.isEmpty || now - resumePendingSince > 1.0) {
            finishResume()
        }

        if let shortcut = capturing {
            if let button = newlyPressed.sorted().first {
                SettingsStore.shared.setButton(button, for: shortcut)
                iPSX2Bridge.log("[Controller] \(shortcut.rawValue) = \(button)")
                capturing = nil
            }
            return
        }

        switch AppState.shared.currentScreen {
        case .playing:
            if isMenuOpen {
                menuTick(controller, newlyPressed: newlyPressed, now: now)
            } else {
                gameTick(pressed: pressed, newlyPressed: newlyPressed, now: now)
            }
        case .menu:
            if isMenuOpen {
                close(resume: true) // left the game screen some other way
            }
            if let move = repeatingMove(controller, useDPad: false, now: now) {
                NotificationCenter.default.post(name: Self.moveNotification, object: nil,
                                                userInfo: ["direction": move.rawValue])
            }
        }
    }

    private func gameTick(pressed: Set<String>, newlyPressed: Set<String>, now: TimeInterval) {
        let settings = SettingsStore.shared
        let openButton = settings.shortcutOpenMenu
        if !openButton.isEmpty && newlyPressed.contains(openButton) {
            open()
            return
        }

        let saveButton = settings.shortcutQuickSave
        if !saveButton.isEmpty && newlyPressed.contains(saveButton) {
            iPSX2Bridge.log("[Controller] quick save (slot \(Self.quickSlot))")
            SaveStateStore.shared.save(slot: Self.quickSlot)
        }

        // Quick load needs a short hold, so a bump can't throw away progress.
        let loadButton = settings.shortcutQuickLoad
        if !loadButton.isEmpty && pressed.contains(loadButton) {
            if let since = quickLoadHeldSince {
                if !quickLoadFired && now - since >= 0.5 {
                    quickLoadFired = true
                    iPSX2Bridge.log("[Controller] quick load (slot \(Self.quickSlot))")
                    SaveStateStore.shared.load(slot: Self.quickSlot)
                }
            } else {
                quickLoadHeldSince = now
                quickLoadFired = false
            }
        } else {
            quickLoadHeldSince = nil
            quickLoadFired = false
        }
    }

    private func menuTick(_ controller: GCController, newlyPressed: Set<String>, now: TimeInterval) {
        if let move = repeatingMove(controller, useDPad: true, now: now) {
            switch move {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            case .left: if page != .main { goBack() }
            case .right: break
            }
        }
        let openButton = SettingsStore.shared.shortcutOpenMenu
        if newlyPressed.contains(GCInputButtonA) {
            activate(index: selection)
        } else if newlyPressed.contains(GCInputButtonB) {
            goBack()
        } else if !openButton.isEmpty && newlyPressed.contains(openButton) {
            close(resume: true)
        }
    }

    /// A direction when it is first pushed, then repeating while held (like a held arrow key).
    private func repeatingMove(_ controller: GCController, useDPad: Bool, now: TimeInterval) -> MoveDirection? {
        let direction = currentDirection(controller, useDPad: useDPad)
        if direction != heldMove {
            heldMove = direction
            nextRepeat = now + 0.4
            return direction
        }
        if let direction, now >= nextRepeat {
            nextRepeat = now + 0.12
            return direction
        }
        return nil
    }

    private func currentDirection(_ controller: GCController, useDPad: Bool) -> MoveDirection? {
        guard let pad = controller.extendedGamepad else { return nil }
        if useDPad {
            if pad.dpad.up.isPressed { return .up }
            if pad.dpad.down.isPressed { return .down }
            if pad.dpad.left.isPressed { return .left }
            if pad.dpad.right.isPressed { return .right }
        }
        // Left stick, dominant axis. A held direction stays held down to a smaller push so it
        // doesn't flicker at the edge.
        let x = pad.leftThumbstick.xAxis.value
        let y = pad.leftThumbstick.yAxis.value // up is positive
        let candidate: MoveDirection
        let amount: Float
        if abs(y) >= abs(x) {
            candidate = y > 0 ? .up : .down
            amount = abs(y)
        } else {
            candidate = x > 0 ? .right : .left
            amount = abs(x)
        }
        return amount > (heldMove == candidate ? 0.35 : 0.55) ? candidate : nil
    }

    // MARK: - Settings

    /// What iPadOS calls the button on the connected controller ("Button Home" → "Home" otherwise).
    static func displayName(for button: String) -> String {
        if let controller = GCController.current ?? GCController.controllers().first,
           let name = controller.physicalInputProfile.elements[button]?.localizedName, !name.isEmpty {
            return name
        }
        return button.hasPrefix("Button ") ? String(button.dropFirst("Button ".count)) : button
    }
}
