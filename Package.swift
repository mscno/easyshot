// swift-tools-version: 5.10
import PackageDescription
import Foundation
let storeEdition = ProcessInfo.processInfo.environment["APP_EDITION"] == "app-store"

let package = Package(
    name: "Easyshot",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Easyshot", targets: ["Easyshot"])],
    dependencies: storeEdition ? [] : [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "EasyshotCore"),
        .executableTarget(name: "Easyshot", dependencies: [.target(name: "EasyshotCore")] + (storeEdition ? [] : [.product(name: "Sparkle", package: "Sparkle")]), linkerSettings: storeEdition ? [] : [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "EasyshotCoreTests", dependencies: ["EasyshotCore"])
    ]
)
