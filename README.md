# AirPop

**Blow with AirPuff. Pop with your hands.**

AirPop is a two-device, no-touch bubble game. One player blows into an iPhone
to fill the screen with bubbles; up to four hands in front of a Mac's camera
pinch them out of the air. At the end of the round, the game hands everyone a
framed photo of themselves mid-play.

It is built entirely with Apple-native frameworks -- SwiftUI, SpriteKit,
Vision, Core ML / Create ML, AVFoundation, Accelerate, and Network.framework --
and was designed to run at an exhibition booth, where the people playing have
never seen it before and nobody reads instructions.

<!-- Hero image: replace with a photo or GIF of people playing.
![Players pinching bubbles in front of the Mac](docs/images/hero.gif)
-->

## Contents

- [Motivation](#motivation)
- [How it works](#how-it-works)
- [Screenshots](#screenshots)
- [Setup on a new Mac and iPhone](#setup-on-a-new-mac-and-iphone)
- [Technical reference](#technical-reference)
- [Credits](#credits)

## Motivation

Most screen games ask you to touch glass or hold a controller. AirPop asks for
two of the most basic things a body does -- breathing out and pinching -- and
turns them into a shared game. Breath is invisible, so the iPhone makes it
visible as bubbles; hands are already in the camera, so they become the
controller with nothing to put on or pick up.

That choice shapes the whole design:

- **Cooperative by default.** One person blows, others pop. Two to four people
  can play together around a single screen, which suits a booth where groups
  arrive together.
- **Zero onboarding.** "Blow to create. Pinch to pop." is the only rule. The
  game auto-pauses when every hand leaves the frame and plays solo (with
  automatic bubbles) when no iPhone is connected, so it never gets stuck.
- **Something to take home.** The round ends with a photo souvenir that
  combines the camera image with the actual bubbles that were on screen.
- **Private by construction.** The iPhone never sends audio, only a number for
  how hard you blew. Photos are written to disk only when the player chooses.

<!-- Day: personalize this section -- why you made AirPop, who it was for,
and what you learned watching people play it. -->

## How it works

AirPop is two apps that talk over the local network:

| App | Device | Job |
| --- | --- | --- |
| **AirPop** | Mac | Shows the mirrored live camera, tracks hands, runs the SpriteKit game, and composes the result photo. |
| **AirPuff** | iPhone | Listens to the microphone, detects a blow, and sends only its strength (0 to 1) to the Mac. |

```
 iPhone (AirPuff)                          Mac (AirPop)
 ┌──────────────────┐   strength 0..1    ┌──────────────────────────────┐
 │ mic -> dBFS ->   │ ─────────────────> │ BlowSpawnRules -> bubbles    │
 │ blow detector    │  JSON over TCP,    │                              │
 └──────────────────┘  found via Bonjour │ camera -> Vision hand pose   │
                                         │   -> Core ML pinch classifier│
                                         │   -> pop                     │
                                         │                              │
                                         │ round end -> ResultPhoto-    │
                                         │   Composer -> framed photo   │
                                         └──────────────────────────────┘
```

### 1. Blowing bubbles (AirPuff)

AirPuff calibrates to the room's noise for 1.5 seconds, then measures
microphone level in dBFS (using Accelerate) and recognises a blow above that
noise floor. It sends a normalized strength value to the Mac. A soft blow
releases a few slow bubbles; a hard blow releases up to eight per second,
rising faster. The mapping is interpolated, so strength feels like a gradient
rather than three settings.

### 2. Pinching bubbles (hand tracking + Create ML)

Vision finds up to four hands in each camera frame and gives each one a stable
tracking ID. For every hand, AirPop computes four features -- thumb-to-index
pinch ratio, index extension, thumb extension, and fingertip confidence -- and
passes them to `PinchGestureClassifier`, a Create ML random-forest model that
labels the hand `open`, `pinch`, or `background`.

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

### 3. The game

- 30-second rounds with a countdown, score, combo, misses, and a saved high
  score.
- Difficulty ramps through four stages: bubbles spawn faster, rise faster, and
  bombs appear more often (up to 20% of spawns in the last stretch).
- Popping a bubble scores 1; pinching a bomb costs 3.
- Bubbles are procedural frosted-glass pastel sprites with pop and bomb
  effects and sound.
- The round pauses automatically when every hand has been missing for 1.5
  seconds, or when the iPhone link drops mid-round.

### 4. The result photo (`ResultPhotoComposer`)

At the end of a round, AirPop composites the mirrored camera frame and the
live SpriteKit bubble layer into a bubble-themed photo frame, in both a
circular and a rounded-rect window -- the player picks whichever one they
like from thumbnails before saving. Everything in the frame is fixed art
except the date, drawn fresh each time. Both results stay in memory; a file
is written only when the player chooses **PNG 저장** (Save PNG).

## Screenshots

<!-- Add images to docs/images/ and uncomment each line. -->

| Start screen | Gameplay | Result photo | AirPuff on iPhone |
| --- | --- | --- | --- |
| _coming soon_ | _coming soon_ | _coming soon_ | _coming soon_ |

<!--
| ![Start screen](docs/images/start.png) | ![Gameplay](docs/images/gameplay.png) | ![Result photo](docs/images/result.png) | ![AirPuff](docs/images/airpuff.png) |
-->

<!-- Optional: a short demo video link.
[Watch a 60-second demo](https://...)
-->

## Setup on a new Mac and iPhone

### Requirements

- A Mac with a camera (built-in or Continuity Camera), running macOS 14 or
  later, with Xcode 26 or later
- An iPhone running iOS 17 or later, connected to the Mac by cable the first
  time
- Both devices on the same local network
- A free or paid Apple Developer account signed in to Xcode

### 1. Clone and open

```bash
git clone https://github.com/daychae/AirPop.git
cd AirPop
open AirPop.xcodeproj
```

### 2. Set your own signing team

The project is configured with its original author's development team, which
your Xcode will not have. For **both** the `AirPop` and `AirPuff` targets:

1. Select the target, then open **Signing & Capabilities**.
2. Keep **Automatically manage signing** on and choose your own **Team**.
3. If Xcode reports that the bundle identifier is unavailable, change
   `com.example.AirPop` / `com.example.AirPuff` to something unique, such as
   `com.yourname.AirPop`.

### 3. Install AirPuff on the iPhone

1. On the iPhone, turn on **Settings > Privacy & Security > Developer Mode**
   if prompted, and restart.
2. In Xcode, select the `AirPuff` scheme and your iPhone, then run once.
3. With a free developer account, trust the developer certificate on the
   iPhone under **Settings > General > VPN & Device Management**.

### 4. Run AirPop on the Mac

1. Select the `AirPop` scheme and **My Mac**, then run.
2. Allow camera access, and local-network access if asked.

### 5. Connect

1. Open AirPuff on the iPhone and allow microphone and local-network access.
2. AirPuff finds the Mac automatically through the `_airpop._tcp` Bonjour
   service.
3. If it does not, open **Connection test > Direct connect** in AirPuff and
   type the address shown on the Mac's start screen.

A managed school or company network may block direct device-to-device traffic
even when both devices use the same Wi-Fi. A personal hotspot or a USB cable
between the devices usually works. AirPop also plays without an iPhone: bubbles
then spawn automatically.

### Controls on the Mac

| Key | Action |
| --- | --- |
| `D` | Toggle the diagnostics panel (address, arrival intervals, round trip, network path) |
| `[` / `]` | Tighten / loosen the pinch distance gate for the player's distance from the camera |

## Technical reference

### Data sent over the network

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

### Connecting

The Mac listens on port 51888 when it is free, falling back to an automatic
port, and advertises `_airpop._tcp`. AirPuff finds it automatically.

When a venue network blocks mDNS, open **Connection test > Direct connect** in
AirPuff and type the address shown on the Mac's start screen. Press `D` on the
Mac for a diagnostics panel with the listening address, arrival intervals,
round trip, and which physical path the phone took.

The transport does not pin an interface type, so Wi-Fi, peer-to-peer, and a
USB connection all work without a code change.

## Project layout

```
AirPop/        macOS game: camera, Vision, Core ML, SpriteKit, result photo
AirPuff/       iOS companion: microphone blow detection and connection UI
Shared/        Wire protocol, link statistics, monotonic clock
Tools/         Create ML training and validation for the pinch classifier
Assets/Sounds/ Game sound effects
```

## Credits

Made by **L & L**.
<!-- Day: replace with full names and roles, e.g.
- Day Chae -- concept, design, iOS/macOS development
- ... -- ...
-->

- **Fonts:** [Google Sans Flex](https://fonts.google.com/specimen/Google+Sans+Flex)
  (logo and English text) and [Handjet](https://fonts.google.com/specimen/Handjet)
  (date on the result photo), both under the SIL Open Font License 1.1. License
  files ship in `AirPop/Fonts/`.
- **Frameworks:** SwiftUI, SpriteKit, Vision, Core ML, Create ML, AVFoundation,
  Accelerate, Network.framework.
- **Sound effects:** in `Assets/Sounds/`.
  <!-- Day: add the source and license of each sound, or note that you made them. -->
- **Frame and countdown artwork:** <!-- Day: credit the designer. -->
