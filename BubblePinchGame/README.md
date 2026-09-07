# AirPop

AirPop is a macOS SpriteKit game built with Apple-native frameworks.

## Interaction concept

- **Air:** the AirPuff iPhone companion creates bubbles from detected blows.
- **Pop:** up to four tracked hands can pinch bubbles independently.
- Player-facing phrase: **Blow to create. Pinch to pop.**

Until the iPhone input is connected, the macOS game automatically creates
bubbles so the full round can be tested.

## Current features

- Live mirrored camera preview behind the game
- Vision hand-pose detection for up to four hands
- Core ML pinch classification for every detected hand
- Per-hand tracking IDs, prediction stabilization, and independent pinch events
- Exact preview-layer coordinate conversion for crop and mirroring
- 30-second rounds with countdown, score, combo, misses, bombs, and high score
- Automatic pause when every hand has been missing for 1.5 seconds
- Procedural SpriteKit vector bubbles and pop/bomb effects
- AirPuff iPhone companion with live dBFS blow detection and calibration
- Bonjour discovery and strength-only event transfer to the Mac game
- `GameScene.spawnBubble(strength:)` entry point for received iPhone events

## Machine learning pipeline

Vision extracts hand landmarks first. AirPop then calculates four normalized
features for each hand and sends them to `PinchGestureClassifier.mlmodel`:

- Thumb-to-index pinch ratio
- Index extension
- Thumb extension
- Fingertip confidence

The bundled Core ML random-forest model classifies each sample as `open`,
`pinch`, or `background`. A prediction needs at least `0.65` confidence and must
remain consistent for two frames before that hand's stable gesture changes.
There is no geometry-only pinch fallback, so gameplay pinch events require the
Core ML model to be loaded and producing predictions.
