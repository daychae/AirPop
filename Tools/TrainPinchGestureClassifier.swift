import CreateML
import Foundation
import TabularData

struct SeededRandom {
    private var state: UInt64 = 0xB0BB1E30

    mutating func value(in range: ClosedRange<Double>) -> Double {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift TrainPinchGestureClassifier.swift <output.mlmodel>")
}

var random = SeededRandom()
var pinchRatios: [Double] = []
var indexExtensions: [Double] = []
var thumbExtensions: [Double] = []
var fingertipConfidences: [Double] = []
var labels: [String] = []

func addSamples(
    label: String,
    count: Int,
    pinchRatio: ClosedRange<Double>,
    indexExtension: ClosedRange<Double>,
    thumbExtension: ClosedRange<Double>,
    confidence: ClosedRange<Double> = 0.45...1.0
) {
    for _ in 0..<count {
        pinchRatios.append(random.value(in: pinchRatio))
        indexExtensions.append(random.value(in: indexExtension))
        thumbExtensions.append(random.value(in: thumbExtension))
        fingertipConfidences.append(random.value(in: confidence))
        labels.append(label)
    }
}

// The pinch and open ranges must touch. The previous version left 0.33...0.52
// uncovered except by a "background" block, so the forest labelled that whole
// band background at 0.53 confidence. The runtime ignores anything below 0.65
// confidence, which meant a thumb-index gap of roughly 2.7cm to 4.3cm produced
// no state change at all -- and both transitions have to pass through it.
//
// pinchRatio is the thumb-index tip distance over hand scale, both measured in
// units of image height so the value does not depend on how the hand is turned.
// With a hand scale near 8cm, 0.50 is a gap of about 4cm: a natural pinch where
// the finger pads approach without the tips having to meet.
addSamples(
    label: "pinch",
    count: 700,
    pinchRatio: 0.02...0.50,
    indexExtension: 0.70...1.90,
    thumbExtension: 0.34...1.30
)
addSamples(
    label: "open",
    count: 700,
    pinchRatio: 0.50...1.90,
    indexExtension: 0.78...1.95,
    thumbExtension: 0.58...1.60
)

// Background is now only for shapes that are not a recognizable open hand or
// pinch: a fist, or fingers too curled to read. It no longer claims an
// ambiguous middle band of pinchRatio, because ambiguity there is handled at
// runtime by hysteresis, where holding the previous state is the right answer.
addSamples(
    label: "background",
    count: 600,
    pinchRatio: 0.05...1.60,
    indexExtension: 0.10...0.62,
    thumbExtension: 0.10...0.80
)

var data = DataFrame()
data.append(column: Column(name: "pinchRatio", contents: pinchRatios))
data.append(column: Column(name: "indexExtension", contents: indexExtensions))
data.append(column: Column(name: "thumbExtension", contents: thumbExtensions))
data.append(column: Column(name: "fingertipConfidence", contents: fingertipConfidences))
data.append(column: Column(name: "label", contents: labels))

let classifier = try MLRandomForestClassifier(
    trainingData: data,
    targetColumn: "label",
    featureColumns: [
        "pinchRatio",
        "indexExtension",
        "thumbExtension",
        "fingertipConfidence"
    ]
)

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
if FileManager.default.fileExists(atPath: outputURL.path) {
    try FileManager.default.removeItem(at: outputURL)
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try classifier.write(to: outputURL, metadata: nil)

print("Created Core ML model at \(outputURL.path)")
print("Training error: \(classifier.trainingMetrics.classificationError)")

