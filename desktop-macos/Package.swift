// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PromptMeet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PromptMeet", targets: ["PromptMeet"])
    ],
    targets: [
        .executableTarget(name: "PromptMeet"),
        .testTarget(name: "PromptMeetTests", dependencies: ["PromptMeet"])
    ]
)
