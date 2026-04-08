import ProjectDescription

let project = Project(
    name: "Viska",
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
        ]
    ),
    targets: [
        .target(
            name: "Viska",
            destinations: .macOS,
            product: .app,
            bundleId: "com.martinjonsson.Viska",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Viska",
                "LSUIElement": true,
                "NSMicrophoneUsageDescription": "Viska records short dictation clips for transcription.",
            ]),
            buildableFolders: [
                "Sources",
            ]
        ),
        .target(
            name: "ViskaTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.martinjonsson.ViskaTests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            buildableFolders: [
                "Tests",
            ],
            dependencies: [
                .target(name: "Viska"),
            ]
        ),
    ]
)
