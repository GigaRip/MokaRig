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

/// Builds a `VZVirtualMachineConfiguration` for a Linux guest from a VM bundle.
enum LinuxVirtualMachineBuilder {
	static func makeConfiguration(bundle: VMBundle, metadata: VMMetadata) throws -> VZVirtualMachineConfiguration {
		let configuration = VZVirtualMachineConfiguration()
		configuration.cpuCount = clampedCPUCount(metadata.cpuCount)
		configuration.memorySize = clampedMemorySize(metadata.memorySizeInBytes)

		let platform = VZGenericPlatformConfiguration()
		platform.machineIdentifier = try machineIdentifier(for: bundle)
		configuration.platform = platform

		let bootLoader = VZEFIBootLoader()
		bootLoader.variableStore = try efiVariableStore(for: bundle)
		configuration.bootLoader = bootLoader

		var storageDevices: [VZStorageDeviceConfiguration] = []
		// Attach the installer ISO as a bootable USB mass storage device while installing.
		if metadata.needsInstall, let mediaPath = metadata.installerMediaPath {
			let mediaURL = URL(fileURLWithPath: mediaPath)
			guard FileManager.default.fileExists(atPath: mediaURL.path) else {
				throw VMError.installerMediaMissing
			}
			let attachment = try VZDiskImageStorageDeviceAttachment(url: mediaURL, readOnly: true)
			storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
		}
		let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: bundle.diskImageURL, readOnly: false)
		storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))
		configuration.storageDevices = storageDevices

		configuration.networkDevices = [makeNetworkDevice()]
		configuration.graphicsDevices = [makeGraphicsDevice(metadata: metadata)]
		configuration.audioDevices = [makeOutputAudioDevice()]
		configuration.keyboards = [VZUSBKeyboardConfiguration()]
		configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		configuration.consoleDevices = [makeSpiceAgentConsole()]

		do {
			try configuration.validate()
		} catch {
			throw VMError.configurationInvalid(error.localizedDescription)
		}
		return configuration
	}

	/// Loads the saved generic machine identifier, creating and persisting one if it doesn't exist yet.
	private static func machineIdentifier(for bundle: VMBundle) throws -> VZGenericMachineIdentifier {
		if FileManager.default.fileExists(atPath: bundle.machineIdentifierURL.path) {
			let data = try Data(contentsOf: bundle.machineIdentifierURL)
			guard let identifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
				throw VMError.missingBundleFile("MachineIdentifier")
			}
			return identifier
		}
		let identifier = VZGenericMachineIdentifier()
		try identifier.dataRepresentation.write(to: bundle.machineIdentifierURL)
		return identifier
	}

	/// Loads the saved EFI variable store, creating one if it doesn't exist yet.
	private static func efiVariableStore(for bundle: VMBundle) throws -> VZEFIVariableStore {
		if FileManager.default.fileExists(atPath: bundle.efiVariableStoreURL.path) {
			return VZEFIVariableStore(url: bundle.efiVariableStoreURL)
		}
		return try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL)
	}

	// MARK: - Devices

	private static func makeNetworkDevice() -> VZVirtioNetworkDeviceConfiguration {
		let device = VZVirtioNetworkDeviceConfiguration()
		device.attachment = VZNATNetworkDeviceAttachment()
		return device
	}

	private static func makeGraphicsDevice(metadata: VMMetadata) -> VZVirtioGraphicsDeviceConfiguration {
		let device = VZVirtioGraphicsDeviceConfiguration()
		device.scanouts = [
			VZVirtioGraphicsScanoutConfiguration(
				widthInPixels: metadata.displayWidthInPixels,
				heightInPixels: metadata.displayHeightInPixels)
		]
		return device
	}

	private static func makeOutputAudioDevice() -> VZVirtioSoundDeviceConfiguration {
		let device = VZVirtioSoundDeviceConfiguration()
		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()
		device.streams = [outputStream]
		return device
	}

	/// A console device carrying the SPICE agent, which enables copy/paste and dynamic resolution
	/// in the guest. Both require a SPICE guest agent (e.g. spice-vdagent) running in the guest.
	private static func makeSpiceAgentConsole() -> VZVirtioConsoleDeviceConfiguration {
		let console = VZVirtioConsoleDeviceConfiguration()
		let port = VZVirtioConsolePortConfiguration()
		port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		let attachment = VZSpiceAgentPortAttachment()
		attachment.sharesClipboard = true
		port.attachment = attachment
		console.ports[0] = port
		return console
	}

	private static func clampedCPUCount(_ requested: Int) -> Int {
		min(max(requested, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
			VZVirtualMachineConfiguration.maximumAllowedCPUCount)
	}

	private static func clampedMemorySize(_ requested: UInt64) -> UInt64 {
		min(max(requested, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
			VZVirtualMachineConfiguration.maximumAllowedMemorySize)
	}
}
