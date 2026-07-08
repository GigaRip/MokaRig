// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

extension View {
	/// The shared alert shown when a VM can't start because a copy it shares an identity with is
	/// already running. Both start paths — the detail Run button and the sidebar double-click — use
	/// this so the wording stays in one place.
	/// - Parameters:
	///	  - isPresented: Whether the alert is showing.
	///	  - vmName: The name of the VM the user tried to start.
	///	  - runningSiblingName: The name of the already-running VM it conflicts with.
	func cannotStartCloneAlert(isPresented: Binding<Bool>, vmName: String, runningSiblingName: String) -> some View {
		confirmationDialog("Cannot start “\(vmName)”", isPresented: isPresented, titleVisibility: .visible) {
			Button("OK", role: .cancel) { }
		} message: {
			Text("This virtual machine is a copy that shares its guest OS identity with “\(runningSiblingName)”, which is running. Running both virtual machines would collide on the network.\n\nTo run both, make this virtual machine independent first.")
		}
	}
}
