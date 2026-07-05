// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Virtualization
import Observation

/// Creates a new macOS VM bundle and installs macOS into it from a local restore image (IPSW).
@MainActor
@Observable
final class MacInstaller {
    /// The stage of the install flow, with progress fraction while installing and a message on failure.
    enum Phase: Equatable {
        case idle
        case preparing
        case installing(Double)
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var progressObservation: NSKeyValueObservation?

    /// Loads the restore image, provisions the bundle, and runs the installer to completion.
    /// - Returns: The new VM's bundle identity on success, so the caller can select it; nil on failure.
    @discardableResult
    func install(name: String, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
                 displayWidth: Int, displayHeight: Int, displayPixelsPerInch: Int,
                 dynamicResolution: Bool, ipswURL: URL, into library: VMLibrary) async -> VMBundle.ID? {
        phase = .preparing
        do {
            let restoreImage = try await VZMacOSRestoreImage.image(from: ipswURL)
            guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
                throw VMError.unsupportedHardwareModel
            }
            let hardwareModel = requirements.hardwareModel
            guard hardwareModel.isSupported else { throw VMError.unsupportedHardwareModel }

            let bundle = VMBundle(url: library.availableBundleURL(forName: name))
            try bundle.createDirectory()
            try bundle.createBlankDiskImage(sizeInBytes: diskBytes)
            try hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)

            let machineIdentifier = VZMacMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: bundle.machineIdentifierURL)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL,
                                          hardwareModel: hardwareModel, options: [])

            var metadata = VMMetadata.defaultMac
            metadata.cpuCount = max(cpuCount, requirements.minimumSupportedCPUCount)
            metadata.memorySizeInBytes = max(memoryBytes, requirements.minimumSupportedMemorySize)
            metadata.displayWidthInPixels = displayWidth
            metadata.displayHeightInPixels = displayHeight
            metadata.pixelsPerInch = displayPixelsPerInch
            metadata.dynamicResolution = dynamicResolution
            metadata.needsInstall = true
            metadata.cloneGroup = UUID()
            try bundle.save(metadata)

            let platform = VZMacPlatformConfiguration()
            platform.hardwareModel = hardwareModel
            platform.machineIdentifier = machineIdentifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)

            let configuration = try MacVirtualMachineBuilder.makeConfiguration(
                bundle: bundle, metadata: metadata, platform: platform)
            let virtualMachine = VZVirtualMachine(configuration: configuration)

            let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: ipswURL)
            phase = .installing(0)
            progressObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in self?.phase = .installing(fraction) }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                installer.install { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }

            progressObservation = nil
            metadata.needsInstall = false
            try bundle.save(metadata)
            library.reload()
            phase = .finished
            // Return the reloaded row's identity, not the constructed URL — they normalize differently
            // (directory flag, trailing slash), and a mismatch would break sidebar selection.
            let targetPath = bundle.url.standardizedFileURL.path
            return library.machines.first { $0.bundle.url.standardizedFileURL.path == targetPath }?.id ?? bundle.id
        } catch {
            progressObservation = nil
            logInstallFailure(error)
            phase = .failed(installFailureMessage(error))
            return nil
        }
    }

    /// Logs the full error chain so a generic "installation failed" can be diagnosed.
    private func logInstallFailure(_ error: Error) {
        let nsError = error as NSError
        print("macOS install failed — domain=\(nsError.domain) code=\(nsError.code)")
        print("  userInfo: \(nsError.userInfo)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("  underlying — domain=\(underlying.domain) code=\(underlying.code)")
            print("  underlying userInfo: \(underlying.userInfo)")
        }
    }

    /// A user-facing message that includes the underlying restore reason when present.
    private func installFailureMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.localizedDescription) (\(underlying.localizedDescription))"
        }
        return nsError.localizedDescription
    }
}
