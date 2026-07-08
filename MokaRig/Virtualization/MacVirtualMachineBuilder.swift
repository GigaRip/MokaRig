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

/// Builds a `VZVirtualMachineConfiguration` for a macOS guest from a VM bundle.
enum MacVirtualMachineBuilder {
	/// Builds a configuration for a macOS VM whose platform data already exists in the bundle.
	static func makeConfiguration(bundle: VMBundle, metadata: VMMetadata) throws -> VZVirtualMachineConfiguration {
		let platform = try makePlatform(bundle: bundle)
		return try makeConfiguration(bundle: bundle, metadata: metadata, platform: platform)
	}

	/// Builds a configuration using an explicit platform (used during first-time installation).
	static func makeConfiguration(bundle: VMBundle, metadata: VMMetadata,
								  platform: VZMacPlatformConfiguration) throws -> VZVirtualMachineConfiguration {
		let configuration = VZVirtualMachineConfiguration()
		configuration.platform = platform
		configuration.bootLoader = VZMacOSBootLoader()
		configuration.cpuCount = clampedCPUCount(metadata.cpuCount)
		configuration.memorySize = clampedMemorySize(metadata.memorySizeInBytes)

		let graphics = VZMacGraphicsDeviceConfiguration()
		graphics.displays = [
			VZMacGraphicsDisplayConfiguration(
				widthInPixels: metadata.displayWidthInPixels,
				heightInPixels: metadata.displayHeightInPixels,
				pixelsPerInch: metadata.pixelsPerInch)
		]
		configuration.graphicsDevices = [graphics]

		let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: bundle.diskImageURL, readOnly: false)
		configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

		let network = VZVirtioNetworkDeviceConfiguration()
		network.attachment = VZNATNetworkDeviceAttachment()
		configuration.networkDevices = [network]

		configuration.keyboards = [VZUSBKeyboardConfiguration()]
		configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

		let audio = VZVirtioSoundDeviceConfiguration()
		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()
		audio.streams = [outputStream]
		configuration.audioDevices = [audio]

		do {
			try configuration.validate()
		} catch {
			throw VMError.configurationInvalid(error.localizedDescription)
		}
		return configuration
	}

	/// Reconstructs the Mac platform configuration from the data saved in the bundle.
	static func makePlatform(bundle: VMBundle) throws -> VZMacPlatformConfiguration {
		guard FileManager.default.fileExists(atPath: bundle.hardwareModelURL.path),
			  let hardwareModelData = try? Data(contentsOf: bundle.hardwareModelURL),
			  let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
			throw VMError.missingBundleFile("HardwareModel")
		}
		guard hardwareModel.isSupported else { throw VMError.unsupportedHardwareModel }

		guard let identifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
			  let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
			throw VMError.missingBundleFile("MachineIdentifier")
		}

		let platform = VZMacPlatformConfiguration()
		platform.hardwareModel = hardwareModel
		platform.machineIdentifier = machineIdentifier
		platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
		return platform
	}

	static func clampedCPUCount(_ requested: Int) -> Int {
		min(max(requested, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
			VZVirtualMachineConfiguration.maximumAllowedCPUCount)
	}

	static func clampedMemorySize(_ requested: UInt64) -> UInt64 {
		min(max(requested, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
			VZVirtualMachineConfiguration.maximumAllowedMemorySize)
	}
}
