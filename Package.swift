// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BLEUnlockLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BLEUnlockLogic", path: "RuntimeLogic"),
        .testTarget(name: "BLEUnlockLogicTests", dependencies: ["BLEUnlockLogic"], path: "Tests", exclude: ["test_release.py"])
    ]
)
