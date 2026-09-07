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
  case geometry = "joint geometry"
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
      return geometryPrediction(metrics: metrics)
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
        return geometryPrediction(metrics: metrics)
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
      return geometryPrediction(metrics: metrics)
    }
  }

  /// Distance-rule fallback for when the compiled model is missing or a
  /// prediction fails. It is less accurate than the classifier, but an
  /// exhibition that loses its model file should degrade to a playable game
  /// rather than to a game where no pinch is ever recognized.
  private func geometryPrediction(metrics: HandMetrics) -> GesturePrediction {
    let gesture: HandGesture
    let confidence: Double

    // Boundaries match the retrained model and the runtime's enter threshold.
    // The prototype's 0.34/0.48 pair left the same gap the model had, so the
    // fallback would have reintroduced the dead band it exists to survive.
    if metrics.pinchRatio < 0.45,
      metrics.indexExtension > 0.55,
      metrics.fingertipConfidence > 0.3
    {
      gesture = .pinch
      confidence = min(1, (0.45 - metrics.pinchRatio) / 0.45 + 0.55)
    } else if metrics.pinchRatio >= 0.45,
      metrics.indexExtension > 0.55,
      metrics.fingertipConfidence > 0.3
    {
      gesture = .open
      confidence = min(1, (metrics.pinchRatio - 0.45) + 0.60)
    } else {
      gesture = .unknown
      confidence = 0.4
    }

    return GesturePrediction(
      gesture: gesture,
      confidence: confidence,
      source: .geometry
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
