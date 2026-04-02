import ProjectDescription

let project = Project(
    name: "VoiceCompanion",
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
        ]
    ),
    targets: [
        .target(
            name: "VoiceCompanion",
            destinations: .macOS,
            product: .app,
            bundleId: "com.martinjonsson.VoiceCompanion",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "VoiceCompanion",
                "LSUIElement": true,
                "NSMicrophoneUsageDescription": "VoiceCompanion records short dictation clips for transcription.",
            ]),
            buildableFolders: [
                "Sources",
            ]
        ),
        .target(
            name: "VoiceCompanionTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.martinjonsson.VoiceCompanionTests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            buildableFolders: [
                "Tests",
            ],
            dependencies: [
                .target(name: "VoiceCompanion"),
            ]
        ),
    ]
)
