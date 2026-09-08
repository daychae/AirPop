import CoreML
import Foundation

enum HandGesture: Equatable {
  case open
  case pinch
  case unknown
}

struct HandMetrics {
  let pinchRatio: Double
  let indexExtension: Double
  let thumbExtension: Double
  let fingertipConfidence: Double
}

enum GestureSource: String {
  case coreML = "Core ML"
  case unavailable = "Core ML unavailable"
}

struct GesturePrediction {
  let gesture: HandGesture
  let confidence: Double
  let source: GestureSource
}

final class HandGestureClassifier {
  private let model: MLModel?

  let loadError: String?

  var isReady: Bool { model != nil }

  init(bundle: Bundle = .main) {
    guard
      let modelURL = bundle.url(
        forResource: "PinchGestureClassifier",
        withExtension: "mlmodelc"
      )
    else {
      model = nil
      loadError = "PinchGestureClassifier.mlmodelc was not found."
      return
    }

    do {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .all
      model = try MLModel(contentsOf: modelURL, configuration: configuration)
      loadError = nil
    } catch {
      model = nil
      loadError = error.localizedDescription
    }
  }

  func predict(metrics: HandMetrics) -> GesturePrediction {
    guard let model else {
      return unavailablePrediction
    }

    do {
      let input = try MLDictionaryFeatureProvider(dictionary: [
        "pinchRatio": MLFeatureValue(double: metrics.pinchRatio),
        "indexExtension": MLFeatureValue(double: metrics.indexExtension),
        "thumbExtension": MLFeatureValue(double: metrics.thumbExtension),
        "fingertipConfidence": MLFeatureValue(
          double: metrics.fingertipConfidence
        ),
      ])
      let output = try model.prediction(from: input)

      guard
        let labelName = model.modelDescription.predictedFeatureName,
        let label = output.featureValue(for: labelName)?.stringValue
      else {
        return unavailablePrediction
      }

      let gesture: HandGesture
      switch label.lowercased() {
      case "pinch":
        gesture = .pinch
      case "open":
        gesture = .open
      default:
        gesture = .unknown
      }

      return GesturePrediction(
        gesture: gesture,
        confidence: probability(
          for: label,
          output: output,
          probabilityName: model.modelDescription.predictedProbabilitiesName
        ),
        source: .coreML
      )
    } catch {
      return unavailablePrediction
    }
  }

  /// A missing model or failed prediction must never become a gameplay pinch.
  /// The ready screen stays blocked when the model cannot be loaded, while a
  /// transient prediction failure is represented as an unknown gesture.
  private var unavailablePrediction: GesturePrediction {
    GesturePrediction(
      gesture: .unknown,
      confidence: 0,
      source: .unavailable
    )
  }

  private func probability(
    for label: String,
    output: MLFeatureProvider,
    probabilityName: String?
  ) -> Double {
    guard
      let probabilityName,
      let probabilities = output.featureValue(
        for: probabilityName
      )?.dictionaryValue
    else {
      return 1
    }

    for (key, value) in probabilities where String(describing: key) == label {
      return value.doubleValue
    }
    return 0
  }
}
