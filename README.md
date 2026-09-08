# AirPop

AirPop is an Apple-native macOS bubble game controlled by an iPhone and up to
four camera-tracked hands.

**Blow with AirPuff. Pop with your hands.**

## Apps

- **AirPop (macOS):** Displays the live camera, tracks hands with
  Vision, classifies pinch gestures with Core ML, and renders the game with
  SpriteKit.
- **AirPuff (iOS):** Measures microphone input as dBFS, detects a short blow,
  and sends only the normalized strength value to the Mac.

At the end of a round, AirPop creates an in-memory result photo by compositing
the mirrored camera frame with the live SpriteKit bubble layer and a score
footer. A file is written only when the player chooses **PNG 저장**.

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

1. Open `AirPop.xcodeproj`.
2. Select the `AirPuff` scheme and the connected iPhone, then run once to
   install the companion app.
3. Select the `AirPop` scheme and `My Mac`, then run the game.
4. Open AirPuff directly on the iPhone.
5. Allow camera, microphone, and local-network permissions when requested.

AirPuff discovers the Mac automatically through the `_airpop._tcp` Bonjour
service. A managed school or company network may block direct device-to-device
traffic even when both devices use the same Wi-Fi.

## Data sent over the network

AirPuff does not transmit microphone audio. Messages are newline-delimited
JSON on a TCP connection, and carry only strength, timing, and bookkeeping:

```json
{
  "v": 2,
  "type": "blow",
  "sessionID": "8C3F...",
  "sequence": 42,
  "strength": 0.72,
  "sentAtMillis": 128374,
  "wantsAck": false
}
```

Timestamps are monotonic milliseconds relative to each app's own start, never
wall-clock time, so the two devices need no clock synchronization.

The Mac replies only when the phone sets `wantsAck` -- on `hello`, on every
diagnostic message, and once per second during play. That reply is what proves
the Mac app is still consuming input: a TCP connection reports `.ready` and
keeps accepting sends long after the peer has stopped reading.

Each connection claims a fresh `sessionID` with the sequence rewound to zero.
The Mac serves one session at a time and drops anything from a replaced
connection, so reconnecting never replays input produced before the drop.

## Connecting

The Mac listens on port 51888 when it is free, falling back to an automatic
port, and advertises `_airpop._tcp`. AirPuff finds it automatically.

When a venue network blocks mDNS, open **Connection test > Direct connect** in
AirPuff and type the address shown on the Mac's start screen. Press `D` on the
Mac for a diagnostics panel with the listening address, arrival intervals,
round trip, and which physical path the phone took.

The transport does not pin an interface type, so Wi-Fi, peer-to-peer, and a
USB connection all work without a code change.

## Machine learning

Vision extracts hand landmarks on the Mac. Four normalized features are passed
to the bundled `PinchGestureClassifier.mlmodel`, which classifies each tracked
hand as `open`, `pinch`, or `background`.

The model is generated, not learned from recorded hands: `Tools` synthesizes a
labelled feature distribution and fits a random forest to it. That makes the
training script the only place the model's behavior can actually be changed,
since the `.mlmodel` itself is a binary.

```bash
swift Tools/TrainPinchGestureClassifier.swift AirPop/PinchGestureClassifier.mlmodel
xcrun coremlc compile AirPop/PinchGestureClassifier.mlmodel /tmp/airpop
swift Tools/ValidatePinchGestureClassifier.swift /tmp/airpop/PinchGestureClassifier.mlmodelc
```

Every distance is measured in units of image height. Vision normalizes each
axis independently, so at 1280x720 the same physical gap measures 1.78x larger
vertically than horizontally -- and a pinch gap runs mostly vertical while palm
width runs mostly horizontal. Uncorrected, that inflated the ratio by up to
that factor and the fingertips had to nearly touch before a pinch registered.

Pinch state uses the Core ML prediction together with geometric hysteresis. A
pinch may enter only when the model predicts `pinch` with at least `0.65`
confidence and the normalized thumb-index gap is no more than `0.85`; it
releases above `1.03`. Entry takes one frame and release takes two, because a
late pop feels broken while a one-frame dropout mid-gesture pops a second
bubble. Press `[` and `]` during play to tighten or loosen the geometric gate,
since the right value depends on how far the player stands from the camera.

When the compiled model is missing, the ready screen remains blocked. A failed
prediction becomes `unknown`; there is no geometry-only gameplay fallback.

Each tracked hand carries its own smoothed pointer, which is held still while
the fingers close. Pinching moves both fingertips, so an unheld midpoint
travels several bubble radii during the gesture and pops whatever the hand
drifted onto.
