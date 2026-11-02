// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacToolbox",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MacToolboxCore", targets: ["MacToolboxCore"]),
               .executable(name: "MacToolboxApp", targets: ["MacToolboxApp"])],
    targets: [
        .target(name: "MacToolboxKeychainCompatibility", path: "NativeCompatibility", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Security")]),
        .target(name: "MacToolboxCore", dependencies: ["MacToolboxKeychainCompatibility"], path: "MacToolbox", exclude: ["App"]),
        .executableTarget(name: "MacToolboxApp", dependencies: ["MacToolboxCore"], path: "MacToolbox/App"),
        .testTarget(name: "MacToolboxTests", dependencies: ["MacToolboxCore"], path: "MacToolboxTests")
    ],
    swiftLanguageModes: [.v6]
)
