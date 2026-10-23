// swift-tools-version: 6.0
//
// Jarvis Apple Integrations — reusable engine modules.
//
// The SwiftUI application lives in `JarvisAppleIntegrations.xcodeproj` (generated from `project.yml`)
// and links these modules. They are also published as Swift Package products so that the broader
// Jarvis assistant can embed the Action Engine without the UI:
//
//   JarvisCore          Models, tool schemas, registry, validation, Action Engine, persistence.
//   JarvisInterpreter   Deterministic EN/ES command parser, natural-date parser, pluggable AI interpreter.
//   JarvisIntegrations  Apple integrations: Music, Notes, Reminders, Calendar, Contacts, Clock (Shortcuts).
//   JarvisIPC           Local Unix-domain-socket server/client (newline-delimited JSON).
//
// `swift test` runs the full mocked test-suite from the command line.

import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .library(name: "JarvisInterpreter", targets: ["JarvisInterpreter"]),
        .library(name: "JarvisIntegrations", targets: ["JarvisIntegrations"]),
        .library(name: "JarvisIPC", targets: ["JarvisIPC"]),
        .executable(name: "jarvisctl", targets: ["jarvisctl"]),
    ],
    targets: [
        .target(
            name: "JarvisCore",
            path: "Sources/JarvisCore"
        ),
        .target(
            name: "JarvisInterpreter",
            dependencies: ["JarvisCore"],
            path: "Sources/JarvisInterpreter"
        ),
        .target(
            name: "JarvisIntegrations",
            dependencies: ["JarvisCore"],
            path: "Sources/JarvisIntegrations"
        ),
        .target(
            name: "JarvisIPC",
            dependencies: ["JarvisCore"],
            path: "Sources/JarvisIPC"
        ),
        .executableTarget(
            name: "jarvisctl",
            dependencies: ["JarvisIPC", "JarvisCore"],
            path: "Sources/jarvisctl"
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisCoreTests"
        ),
        .testTarget(
            name: "JarvisInterpreterTests",
            dependencies: ["JarvisInterpreter", "JarvisCore"],
            path: "Tests/JarvisInterpreterTests"
        ),
        .testTarget(
            name: "JarvisIntegrationsTests",
            dependencies: ["JarvisIntegrations", "JarvisCore", "JarvisInterpreter"],
            path: "Tests/JarvisIntegrationsTests"
        ),
        .testTarget(
            name: "JarvisIPCTests",
            dependencies: ["JarvisIPC", "JarvisCore", "JarvisInterpreter"],
            path: "Tests/JarvisIPCTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
