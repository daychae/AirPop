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

At the end of a round, AirPop composites the mirrored camera frame and the
live SpriteKit bubble layer into a bubble-themed photo frame, in both a
circular and a rounded-rect window -- the player picks whichever one they
like from thumbnails before saving. Everything in the frame is fixed art
except the date, drawn fresh each time. Both results stay in memory; a file
is written only when the player chooses **PNG 저장**.

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

## Setting up on a new Mac or iPhone

The project builds on a fresh machine without any local paths: every file
reference is relative to the repository, and both schemes (`AirPop` and
`AirPuff`) are shared, so they appear as soon as the project is opened. What
does not travel with the repository is code signing and a few one-time device
settings.

**Signing (Xcode, once per Apple ID)**

1. Sign in under **Xcode > Settings > Accounts**.
2. Both targets are pinned to development team `489Y33LB79`. If you build
   with a different Apple ID, select each target, open **Signing &
   Capabilities**, and pick your own team.
3. The bundle identifiers are `com.example.AirPop` and `com.example.AirPuff`.
   With a different team, Xcode usually refuses these because they are already
   registered elsewhere. Change them to something unique, such as
   `com.<yourname>.AirPop` and `com.<yourname>.AirPuff`. The two apps find each
   other through Bonjour, not through their bundle identifiers, so nothing
   else needs to change.

**iPhone (once per phone)**

1. Turn on **Settings > Privacy & Security > Developer Mode** and restart the
   phone (iOS 16 and later; the option appears after the phone has been
   connected to Xcode once).
2. With a free Apple ID, trust the developer certificate under **Settings >
   General > VPN & Device Management** before AirPuff will open. Free-account
   builds expire after 7 days and need to be run from Xcode again.
3. Allow **Microphone** and **Local Network** when AirPuff asks. If Local
   Network was declined, AirPuff now says so; turn it back on under
   **Settings > Privacy & Security > Local Network**.

**Mac (once per Mac)**

1. Allow **Camera** when AirPop asks. If it was declined, turn it on under
   **System Settings > Privacy & Security > Camera**.
2. On macOS 15 and later, also allow **Local Network**
   (**System Settings > Privacy & Security > Local Network**). Without it the
   iPhone cannot see the game.
3. If the macOS firewall is on with "Block all incoming connections", AirPuff
   cannot connect. Allow incoming connections for AirPop instead.

**Before a demo**

- Put both devices on the same network, ideally a phone hotspot or a home
  router you control. School, venue and guest Wi-Fi often isolate clients or
  block Bonjour.
- If AirPuff keeps searching, use **Direct connect** with the address and port
  shown on the Mac (port 51888 unless something else held it).
- A USB cable between the iPhone and the Mac also works: the link is not tied
  to Wi-Fi.

## Connection reliability

What the link already does:

- TCP keepalive probes every second after 2 seconds of silence, so a phone or
  Mac that vanishes without closing the connection is noticed in about
  4 seconds instead of minutes.
- Every connection starts a fresh session, so a reconnect never replays old
  input.
- The phone requests an acknowledgement once a second and marks the Mac as
  not responding after 2.5 seconds without one.

What changed after the fresh-device audit:

- **Reconnects after the Mac closes the link.** Previously, if the Mac app was
  restarted or the TCP connection ended while the Mac kept advertising,
  AirPuff stayed on "searching" until it was relaunched, because the Bonjour
  results never changed. It now reconnects within about a second, and
  direct-connect mode retries the typed address the same way.
- **Retries a refused connection.** Opening AirPuff before the Mac game, or
  typing an address with nothing listening yet, used to leave the connection
  waiting for a network change that might never come. It now retries every
  second.
- **Ignores events from replaced connections.** Pressing restart, switching
  to direct connect, or a quick reconnect could let the old connection's
  late "cancelled" event tear down the new session.
- **Restarts the Mac listener after a failure.** If the listener failed after
  its fallback port (for example after sleep or a Wi-Fi change), the game
  stayed unreachable until relaunch. It now tries again after 2 seconds.
- **Keeps the iPhone screen awake.** Players blow without touching the
  phone, so auto-lock used to send AirPuff to the background mid-round and
  drop the link. AirPuff now disables auto-lock while it is open.

Known limits:

- One phone at a time. A second phone takes over the session, and the first
  one will then reconnect and take it back, so keep only one AirPuff open.
- AirPuff still disconnects if it is sent to the background (switching apps or
  pressing the side button). It reconnects when reopened.

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

The model is generated, not learned from recorded hands:
`Tools/PinchClassifierTools` synthesizes a labelled feature distribution and
fits a random forest to it. That makes the training tool the only place the
model's behavior can actually be changed, since the `.mlmodel` itself is a
binary.

```bash
cd Tools/PinchClassifierTools
swift run TrainPinchGestureClassifier ../../AirPop/PinchGestureClassifier.mlmodel
xcrun coremlc compile ../../AirPop/PinchGestureClassifier.mlmodel /tmp/airpop
swift run ValidatePinchGestureClassifier /tmp/airpop/PinchGestureClassifier.mlmodelc
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
