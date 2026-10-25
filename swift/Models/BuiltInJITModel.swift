// BuiltInJITModel.swift — SwiftUI view of iPSX2's built-in JIT (iPSX2BuiltInJIT, ObjC)
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

@Observable
final class BuiltInJITModel: @unchecked Sendable {
    static let shared = BuiltInJITModel()

    /// iPSX2Bridge.jitStatus: 0 = JIT ready, 1 = no debugger, 2 = debugger but no JIT script.
    private(set) var jitStatus: Int = iPSX2Bridge.jitStatus()
    private(set) var isBusy = false
    private(set) var statusText: String?
    private(set) var errorText: String?
    private(set) var problem: iPSX2BuiltInJITProblem = .noProblem
    private(set) var hasPairingFile = false
    private(set) var unavailableReason: String?
    private(set) var setupCheckText: String?
    private(set) var isLocalDevVPNInstalled = false
    private(set) var isLocalDevVPNConnected = false
    /// Open LocalDevVPN for a moment to connect it when its tunnel is down (stored by iPSX2BuiltInJIT).
    private(set) var autoConnectLocalDevVPN = true
    /// Turn JIT on automatically when iPSX2 opens (stored by iPSX2BuiltInJIT).
    private(set) var enableAtLaunch = true

    @ObservationIgnored private var observer: NSObjectProtocol?

    var isJITOn: Bool { jitStatus == 0 }
    var isAvailable: Bool { unavailableReason == nil }
    var localDevVPNTitle: String { isLocalDevVPNInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("iPSX2BuiltInJITStatusDidChange"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        jitStatus = iPSX2Bridge.jitStatus()
        isBusy = iPSX2BuiltInJIT.isBusy
        statusText = iPSX2BuiltInJIT.statusText
        errorText = iPSX2BuiltInJIT.errorText
        problem = iPSX2BuiltInJIT.problem
        hasPairingFile = iPSX2BuiltInJIT.hasPairingFile
        unavailableReason = iPSX2BuiltInJIT.unavailableReason
        setupCheckText = iPSX2BuiltInJIT.setupCheckText
        isLocalDevVPNInstalled = iPSX2BuiltInJIT.isLocalDevVPNInstalled
        isLocalDevVPNConnected = iPSX2BuiltInJIT.isLocalDevVPNConnected
        autoConnectLocalDevVPN = iPSX2BuiltInJIT.autoConnectLocalDevVPN
        enableAtLaunch = iPSX2BuiltInJIT.enableAtLaunch
    }

    func setAutoConnectLocalDevVPN(_ on: Bool) {
        iPSX2BuiltInJIT.autoConnectLocalDevVPN = on
        refresh()
    }

    func setEnableAtLaunch(_ on: Bool) {
        iPSX2BuiltInJIT.enableAtLaunch = on
        refresh()
    }

    func enable() {
        iPSX2BuiltInJIT.enable()
        refresh()
    }

    func checkSetup() {
        iPSX2BuiltInJIT.checkSetup()
        refresh()
    }

    func resetDeveloperDiskImage() {
        iPSX2BuiltInJIT.resetDeveloperDiskImage()
        refresh()
    }

    func openLocalDevVPN() {
        iPSX2BuiltInJIT.openLocalDevVPN()
    }

    /// Returns nil on success, otherwise the reason the file was not accepted.
    func importPairingFile(_ result: Result<URL, Error>) -> String? {
        defer { refresh() }
        switch result {
        case .success(let url):
            do {
                try iPSX2BuiltInJIT.importPairingFile(from: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .failure(let error):
            return error.localizedDescription
        }
    }

    func removePairingFile() {
        iPSX2BuiltInJIT.removePairingFile()
        refresh()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
