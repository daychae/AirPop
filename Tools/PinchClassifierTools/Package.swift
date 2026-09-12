// swift-tools-version:5.9
import PackageDescription

/// Command-line tools for the PinchGestureClassifier Core ML model, kept as
/// their own package rather than added to the AirPop/AirPuff app targets:
/// each tool has top-level executable statements, and only one such file is
/// allowed per compiled target, so they can't live alongside AirPopApp.swift
/// / AirPuffApp.swift. As a local package, Xcode gives each product its own
/// runnable scheme instead.
let package = Package(
  name: "PinchClassifierTools",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "TrainPinchGestureClassifier",
      path: "Sources/TrainPinchGestureClassifier"
    ),
    .executableTarget(
      name: "ValidatePinchGestureClassifier",
      path: "Sources/ValidatePinchGestureClassifier"
    ),
  ]
)
