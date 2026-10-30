// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "GuestAgent",
	platforms: [.macOS(.v15)],
	products: [
		.executable(name: "mokarig-guest-agent", targets: ["mokarig-guest-agent"]),
	],
	targets: [
		.target(name: "GuestAgentCore"),
		.executableTarget(name: "mokarig-guest-agent", dependencies: ["GuestAgentCore"]),
		.testTarget(name: "GuestAgentCoreTests", dependencies: ["GuestAgentCore"]),
	]
)
