// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Telemprompit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "telemprompit", targets: ["TelemprompitApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/mikecann/prompter-kit.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TelemprompitApp",
            dependencies: [
                .product(name: "PrompterKit", package: "prompter-kit")
            ],
            path: "Sources/TelemprompitApp"
        ),
        .testTarget(
            name: "TelemprompitAppTests",
            dependencies: ["TelemprompitApp"],
            path: "tests/TelemprompitAppTests"
        )
    ]
)
