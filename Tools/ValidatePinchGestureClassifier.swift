import CoreML
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift ValidatePinchGestureClassifier.swift <compiled.mlmodelc>")
}

let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let model = try MLModel(contentsOf: modelURL)

struct TestCase {
    let name: String
    let expected: String
    let pinchRatio: Double
    let indexExtension: Double
    let thumbExtension: Double
}

let tests = [
    TestCase(name: "clear pinch", expected: "pinch", pinchRatio: 0.12, indexExtension: 1.25, thumbExtension: 0.82),
    TestCase(name: "open hand", expected: "open", pinchRatio: 1.05, indexExtension: 1.35, thumbExtension: 1.10),
    TestCase(name: "closed fist", expected: "background", pinchRatio: 0.48, indexExtension: 0.34, thumbExtension: 0.42),

    // The band that used to be dead. Every one of these was labelled
    // background at 0.53 confidence, below the runtime's threshold, so a hand
    // moving slowly between open and pinch produced no state change at all.
    TestCase(name: "cautious pinch 0.36", expected: "pinch", pinchRatio: 0.36, indexExtension: 1.10, thumbExtension: 0.85),
    TestCase(name: "cautious pinch 0.42", expected: "pinch", pinchRatio: 0.42, indexExtension: 1.10, thumbExtension: 0.85),
    TestCase(name: "natural pinch 0.48", expected: "pinch", pinchRatio: 0.48, indexExtension: 1.10, thumbExtension: 0.85),
    TestCase(name: "boundary open 0.56", expected: "open", pinchRatio: 0.56, indexExtension: 1.15, thumbExtension: 0.90)
]

guard let labelName = model.modelDescription.predictedFeatureName else {
    fatalError("The model has no predicted label feature")
}

for test in tests {
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "pinchRatio": MLFeatureValue(double: test.pinchRatio),
        "indexExtension": MLFeatureValue(double: test.indexExtension),
        "thumbExtension": MLFeatureValue(double: test.thumbExtension),
        "fingertipConfidence": MLFeatureValue(double: 0.92)
    ])
    let output = try model.prediction(from: input)
    let label = output.featureValue(for: labelName)?.stringValue ?? "<missing>"
    guard label == test.expected else {
        fatalError("\(test.name): expected \(test.expected), got \(label)")
    }
    print("PASS \(test.name): \(label)")
}

