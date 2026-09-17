// swift-tools-version:5.9
import PackageDescription

// AirChatKit holds every piece of AirChat that is not the app shell, so the protocol core can be
// unit-tested in isolation and the app target stays a thin SwiftUI layer.
//
// The package declares iOS 17 as its floor to keep the modules reusable and SwiftPM-friendly;
// the shipped app itself targets iOS 26 (see ios/project.yml).
let package = Package(
    name: "AirChatKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "AirChatProtocol", targets: ["AirChatProtocol"]),
        .library(name: "AirChatBLE", targets: ["AirChatBLE"]),
        .library(name: "AirChatData", targets: ["AirChatData"]),
    ],
    targets: [
        // Pure Swift, no CoreBluetooth and no UIKit: byte-exact wire format, crypto and the
        // session/node state machines.
        .target(name: "AirChatProtocol"),
        // CoreBluetooth transport: advertising, scanning, GATT server and central.
        .target(name: "AirChatBLE", dependencies: ["AirChatProtocol"]),
        // SQLite persistence using the system libsqlite3 (no third-party dependency).
        .target(
            name: "AirChatData",
            dependencies: ["AirChatProtocol"],
            // System SQLite only: no third-party dependency, so a fresh checkout builds offline.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AirChatProtocolTests",
            dependencies: ["AirChatProtocol"],
            path: "Tests/AirChatProtocolTests"
        ),
    ]
)
