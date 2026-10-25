// iPSX2JITHelper.swift — the debugger half of iPSX2's built-in JIT
// SPDX-License-Identifier: GPL-3.0+
//
// iPSX2 can't attach a debugger to itself, so it starts this app extension (a separate
// process) and sends it iPSX2's PID and the pairing file. StikJIT, compiled into this
// extension from its MPL-2.0 sources (scripts/fetch_stikjit.sh), attaches to iPSX2 over
// LocalDevVPN and runs legacy.js, the script StikDebug runs for iPSX2. The request ends when
// legacy.js detaches, after iPSX2's brk #0x69 handshake (cpp/iPSX2BuiltInJIT.mm).
//
// Modelled on Husk's HuskJITHelper (GPL-2.0-or-later) and StikJIT's INTEGRATION.md.

import Foundation

/// JSON sent by iPSX2 in userInfo["ipsx2-jit-request"] of the extension request's item.
private struct HelperRequest: Decodable {
    enum Operation: String, Decodable {
        /// Check LocalDevVPN and download, mount and verify the Developer Disk Image.
        case prepare
        /// Attach to `targetPID` and run legacy.js until it detaches.
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let forceScript: Bool?
    /// Prefix of the Darwin notifications that report progress back to iPSX2.
    let progressName: String?
}

/// JSON returned in userInfo["ipsx2-jit-response"]; iPSX2 writes `log` to pcsx2_log.txt.
private struct HelperResponse: Encodable {
    let success: Bool
    let message: String
    let txmPresent: Bool?
    let log: [String]
}

private struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Collects StikJIT's progress lines for the response (never the pairing data).
private final class HelperLog {
    private(set) var lines: [String] = []

    func add(_ line: String) {
        NSLog("[iPSX2JIT] %@", line)
        lines.append(line)
        if lines.count > 120 {
            lines.removeFirst(lines.count - 120)
        }
    }
}

/// Tells iPSX2 which step is running, through Darwin notifications "<progressName>.<stage>".
private final class ProgressReporter {
    private let name: String?
    private var lastStage: String?

    init(name: String?) { self.name = name }

    func report(_ stage: StikJIT.PreparationStage) {
        switch stage {
        case .checkingReachability: report("connecting")
        case .checkingDDI: report("checking-ddi")
        case .downloadingDDI: report("downloading-ddi")
        case .mountingDDI: report("mounting-ddi")
        case .verifyingDDI: report("verifying-ddi")
        case .ready: report("ready")
        }
    }

    func report(_ stage: String) {
        guard let name, !name.isEmpty, stage != lastStage else { return }
        lastStage = stage
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("\(name).\(stage)" as CFString),
                                             nil, nil, true)
    }
}

private enum HelperWork {
    /// StikJIT's calls block: run them one at a time on one serial queue (INTEGRATION.md).
    static let queue = DispatchQueue(label: "ipsx2.jit-helper")

    static func handle(_ request: HelperRequest) -> HelperResponse {
        let log = HelperLog()
        let progress = ProgressReporter(name: request.progressName)
        let manager = FileManager.default
        // The helper's own Library folder keeps the Developer Disk Image between launches.
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return HelperResponse(success: true, message: "The Developer Disk Image was reset. It is downloaded again next time.",
                                      txmPresent: StikJIT.isTXMPresent, log: log.lines)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw HelperError("The pairing file was not provided.")
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            let stage: (StikJIT.PreparationStage) -> Void = { stage in
                progress.report(stage)
                log.add("prepare: \(stage)")
            }

            switch request.operation {
            case .prepare:
                switch StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths, progress: stage) {
                case .ready(let security):
                    return HelperResponse(success: true,
                                          message: "LocalDevVPN is connected and the Developer Disk Image is mounted.",
                                          txmPresent: security.isTXMPresent, log: log.lines)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return HelperResponse(success: false, message: reason, txmPresent: StikJIT.isTXMPresent, log: log.lines)
                }
            case .enable:
                guard let targetPID = request.targetPID, targetPID > 0 else {
                    throw HelperError("iPSX2's process ID was not provided.")
                }
                let forceScript = request.forceScript ?? false
                log.add("enable: pid \(targetPID), forceScript \(forceScript), TXM \(String(describing: StikJIT.isTXMPresent))")
                try StikJIT.enableJIT(targetPID: targetPID,
                                      pairingFile: pairingURL,
                                      ddiPaths: paths,
                                      script: .legacy,
                                      forceScript: forceScript,
                                      preparationProgress: { preparation in
                                          stage(preparation)
                                          if case .ready = preparation {
                                              progress.report("attaching")
                                          }
                                      },
                                      progress: { log.add($0) })
                return HelperResponse(success: true, message: "JIT is on. The helper has detached from iPSX2.",
                                      txmPresent: StikJIT.isTXMPresent, log: log.lines)
            case .resetDDI:
                preconditionFailure("handled above")
            }
        } catch {
            log.add("error: \(error.localizedDescription)")
            return HelperResponse(success: false, message: error.localizedDescription,
                                  txmPresent: StikJIT.isTXMPresent, log: log.lines)
        }
    }
}

/// NSExtensionPrincipalClass (JITHelper/Info.plist.in). The request arrives as JSON in the
/// first input item; the response goes back as JSON in the item the request completes with.
/// Enable completes only once legacy.js has detached, so the request, and this process, last
/// as long as the debugger does.
@objc(iPSX2JITHelperHandler)
final class iPSX2JITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?["ipsx2-jit-request"] as? Data
        HelperWork.queue.async {
            let response: HelperResponse
            if let data, let request = try? JSONDecoder().decode(HelperRequest.self, from: data) {
                response = HelperWork.handle(request)
            } else {
                response = HelperResponse(success: false, message: "iPSX2's JIT helper received no request.",
                                          txmPresent: nil, log: [])
            }
            let item = NSExtensionItem()
            item.userInfo = ["ipsx2-jit-response": (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
