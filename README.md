# AirPop

AirPop is an Apple-native macOS bubble game controlled by an iPhone and up to
four camera-tracked hands.

**Blow with AirPuff. Pop with your hands.**

## Apps

- **BubblePinchGame (macOS):** Displays the live camera, tracks hands with
  Vision, classifies pinch gestures with Core ML, and renders the game with
  SpriteKit.
- **AirPuff (iOS):** Measures microphone input as dBFS, detects a short blow,
  and sends only the normalized strength value to the Mac.

## Apple technologies

- SwiftUI
- SpriteKit
- Vision
- Core ML / Create ML
- AVFoundation
- Accelerate
- Network.framework and Bonjour

## Requirements

- Xcode 26 or later
- macOS 14 or later
- iOS 17 or later
- Mac and iPhone on the same local network

## Run

1. Open `BubblePinchGame.xcodeproj`.
2. Select the `AirPuff` scheme and the connected iPhone, then run once to
   install the companion app.
3. Select the `BubblePinchGame` scheme and `My Mac`, then run the game.
4. Open AirPuff directly on the iPhone.
5. Allow camera, microphone, and local-network permissions when requested.

AirPuff discovers the Mac automatically through the `_airpop._tcp` Bonjour
service. A managed school or company network may block direct device-to-device
traffic even when both devices use the same Wi-Fi.

## Data sent over the network

AirPuff does not transmit microphone audio. Each completed blow sends one
newline-delimited JSON message containing only its strength and timestamp:

```json
{
  "type": "blow",
  "strength": 0.72,
  "timestamp": 1788786000
}
```

## Machine learning

Vision extracts hand landmarks on the Mac. Four normalized features are passed
to the bundled `PinchGestureClassifier.mlmodel`, which classifies each tracked
hand as `open`, `pinch`, or `background`. Gameplay pinch events require a
valid Core ML prediction.
