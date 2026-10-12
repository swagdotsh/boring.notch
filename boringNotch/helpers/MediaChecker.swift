//
//  MediaChecker.swift
//  boringNotch
//
//  Created by Alexander on 2025-07-26.
//

import Foundation

final class MediaChecker: Sendable {

    enum MediaCheckerError: Error {
        case missingResources
        case processExecutionFailed
        case timeout
    }

    func checkDeprecationStatus() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
                  let nowPlayingTestClientPath = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path,
                  let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
            else {
                throw MediaCheckerError.missingResources
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkPath, nowPlayingTestClientPath, "test"]

            do {
                try process.run()
            } catch {
                throw MediaCheckerError.processExecutionFailed
            }

            try await Self.waitForExit(process, timeout: .seconds(10))

            switch process.terminationStatus {
            case 0: return false
            case 1: return true
            default: throw MediaCheckerError.processExecutionFailed
            }
        }.value
    }
    static func waitForExit(_ process: Process, timeout: Duration) async throws {
        defer {
            if process.isRunning { process.terminate() }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                throw MediaCheckerError.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

}
