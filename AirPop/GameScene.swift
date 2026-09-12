import AppKit
import CoreImage
import SpriteKit

/// The five pastel colors used across the AirPuff/AirPop bubble design
/// system (see the Figma "Bubble System — Components" section). Fixed hex
/// values, not random hues, so every bubble reads as part of one brand
/// language rather than a rainbow.
private enum BubblePalette: CaseIterable {
  case skyBlue
  case lavender
  case mint
  case pink
  case peach

  var color: NSColor {
    switch self {
    case .skyBlue:
      return NSColor(
        calibratedRed: CGFloat(0x8C) / 255, green: CGFloat(0xC7) / 255,
        blue: CGFloat(0xFA) / 255, alpha: 1)
    case .lavender:
      return NSColor(
        calibratedRed: CGFloat(0xBF) / 255, green: CGFloat(0xA6) / 255,
        blue: CGFloat(0xFA) / 255, alpha: 1)
    case .mint:
      return NSColor(
        calibratedRed: CGFloat(0x99) / 255, green: CGFloat(0xEA) / 255,
        blue: CGFloat(0xC7) / 255, alpha: 1)
    case .pink:
      return NSColor(
        calibratedRed: CGFloat(0xFF) / 255, green: CGFloat(0xB8) / 255,
        blue: CGFloat(0xD9) / 255, alpha: 1)
    case .peach:
      return NSColor(
        calibratedRed: CGFloat(0xFF) / 255, green: CGFloat(0xD1) / 255,
        blue: CGFloat(0x99) / 255, alpha: 1)
    }
  }
}

/// Builds and caches the radial-gradient textures behind the frosted-glass
/// fill, so bubbles of the same color/size share one image instead of each
/// spawn redrawing a gradient from scratch.
private enum BubbleTextureFactory {
  private static var cache: [String: SKTexture] = [:]

  static func frostedFill(color: NSColor, diameter: CGFloat) -> SKTexture {
    // Round to a small set of buckets so nearby bubble sizes reuse a texture.
    let bucket = max(16, (diameter / 4).rounded() * 4)
    let key = "\(color)-\(bucket)"
    if let cached = cache[key] { return cached }

    let size = CGSize(width: bucket, height: bucket)
    let image = NSImage(size: size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let stops = [
        NSColor.white.withAlphaComponent(0.95).cgColor,
        color.withAlphaComponent(0.62).cgColor,
        color.withAlphaComponent(0.30).cgColor,
      ]
      guard
        let gradient = CGGradient(
          colorsSpace: colorSpace, colors: stops as CFArray, locations: [0, 0.55, 1])
      else { return false }

      // Off-center highlight so the bubble reads as glass, not a flat disc.
      let highlightCenter = CGPoint(
        x: rect.midX - rect.width * 0.16, y: rect.midY + rect.height * 0.18)
      context.drawRadialGradient(
        gradient,
        startCenter: highlightCenter, startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.52,
        options: [.drawsAfterEndLocation]
      )
      return true
    }
    let texture = SKTexture(image: image)
    cache[key] = texture
    return texture
  }
}

private final class BubbleNode: SKNode {
  let bubbleRadius: CGFloat
  let isBomb: Bool

  /// Frosted-glass gradient fill.
  private let fill: SKShapeNode
  /// Soft white rim stroke, drawn over the fill.
  private let rim: SKShapeNode
  private let baseRimColor = NSColor.white.withAlphaComponent(0.85)
  private let bombMark = SKNode()

  init(radius: CGFloat, isBomb: Bool) {
    bubbleRadius = radius
    self.isBomb = isBomb

    let tint = BubblePalette.allCases.randomElement()?.color ?? BubblePalette.skyBlue.color

    // Soft outer glow, blurred and sitting behind everything else.
    let glowShape = SKShapeNode(circleOfRadius: radius * 0.96)
    glowShape.fillColor = tint.withAlphaComponent(0.32)
    glowShape.strokeColor = .clear
    let glow = SKEffectNode()
    glow.shouldRasterize = true
    let blur = CIFilter(name: "CIGaussianBlur")
    blur?.setValue(radius * 0.4, forKey: kCIInputRadiusKey)
    glow.filter = blur
    glow.addChild(glowShape)

    // Frosted-glass body — a radial-gradient texture rather than a flat fill,
    // so it reads as translucent rather than a solid pastel circle.
    fill = SKShapeNode(circleOfRadius: radius)
    fill.fillTexture = BubbleTextureFactory.frostedFill(color: tint, diameter: radius * 2)
    fill.fillColor = .white
    fill.strokeColor = .clear
    fill.alpha = 0.94

    rim = SKShapeNode(circleOfRadius: radius)
    rim.fillColor = .clear
    rim.strokeColor = NSColor.white.withAlphaComponent(0.85)
    rim.lineWidth = max(1.6, radius * 0.045)
    rim.glowWidth = 1.4

    super.init()

    addChild(glow)
    addChild(fill)
    addChild(rim)

    let highlight = SKShapeNode(
      ellipseOf: CGSize(
        width: radius * 0.42,
        height: radius * 0.19
      ))
    highlight.fillColor = NSColor.white.withAlphaComponent(0.65)
    highlight.strokeColor = .clear
    highlight.position = CGPoint(x: -radius * 0.30, y: radius * 0.36)
    highlight.zRotation = -0.55
    addChild(highlight)

    // Roughly a third of bubbles get a sparkle — never all of them, so it
    // stays a highlight rather than visual noise.
    if !isBomb, Double.random(in: 0...1) < 0.35 {
      addChild(Self.sparkleNode(radius: radius))
    }

    if isBomb {
      configureBombMark(radius: radius)
      bombMark.alpha = 0.08
      addChild(bombMark)
    }
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateProximity(to pointers: [CGPoint]) {
    let nearestDistance =
      pointers.map {
        hypot(position.x - $0.x, position.y - $0.y)
      }.min() ?? .greatestFiniteMagnitude

    let hovered = nearestDistance <= bubbleRadius * 1.10
    let nearby = nearestDistance <= bubbleRadius * 1.42
    setScale(hovered ? 1.08 : 1)

    if isBomb {
      bombMark.alpha = hovered ? 0.55 : (nearby ? 0.27 : 0.08)
      rim.strokeColor =
        hovered
        ? NSColor.systemRed.withAlphaComponent(0.92)
        : baseRimColor
    }
  }

  func revealBomb() {
    bombMark.alpha = 1
    rim.strokeColor = .systemRed
    fill.fillTexture = nil
    fill.fillColor = NSColor.systemRed.withAlphaComponent(0.55)
  }

  /// A small 4-point sparkle/twinkle, matching the accent mark used sparingly
  /// on bubbles in the Figma bubble system.
  private static func sparkleNode(radius: CGFloat) -> SKShapeNode {
    let starRadius = radius * 0.22
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: starRadius))
    path.addQuadCurve(to: CGPoint(x: starRadius * 0.30, y: 0), control: CGPoint(x: 0, y: 0))
    path.addQuadCurve(to: CGPoint(x: 0, y: -starRadius), control: CGPoint(x: 0, y: 0))
    path.addQuadCurve(to: CGPoint(x: -starRadius * 0.30, y: 0), control: CGPoint(x: 0, y: 0))
    path.addQuadCurve(to: CGPoint(x: 0, y: starRadius), control: CGPoint(x: 0, y: 0))
    path.closeSubpath()

    let sparkle = SKShapeNode(path: path)
    sparkle.fillColor = .white
    sparkle.strokeColor = .clear
    sparkle.glowWidth = 1.2
    sparkle.alpha = 0.92
    sparkle.position = CGPoint(
      x: radius * CGFloat.random(in: 0.40...0.58),
      y: radius * CGFloat.random(in: 0.42...0.62)
    )
    sparkle.zRotation = CGFloat.random(in: -0.3...0.3)
    return sparkle
  }

  private func configureBombMark(radius: CGFloat) {
    let body = SKShapeNode(circleOfRadius: radius * 0.30)
    body.fillColor = NSColor(calibratedWhite: 0.07, alpha: 0.92)
    body.strokeColor = NSColor.systemRed.withAlphaComponent(0.9)
    body.lineWidth = 2
    bombMark.addChild(body)

    let fusePath = CGMutablePath()
    fusePath.move(to: CGPoint(x: radius * 0.16, y: radius * 0.25))
    fusePath.addCurve(
      to: CGPoint(x: radius * 0.33, y: radius * 0.50),
      control1: CGPoint(x: radius * 0.20, y: radius * 0.38),
      control2: CGPoint(x: radius * 0.33, y: radius * 0.35)
    )
    let fuse = SKShapeNode(path: fusePath)
    fuse.strokeColor = .white
    fuse.lineWidth = max(2, radius * 0.055)
    fuse.lineCap = .round
    bombMark.addChild(fuse)

    let spark = SKShapeNode(circleOfRadius: radius * 0.065)
    spark.position = CGPoint(x: radius * 0.34, y: radius * 0.52)
    spark.fillColor = .systemYellow
    spark.strokeColor = .white
    spark.glowWidth = 3
    bombMark.addChild(spark)
  }
}

final class GameScene: SKScene {
  var onNormalPopped: (() -> Void)?
  var onBombTriggered: (() -> Void)?
  var onNormalMissed: (() -> Void)?
  var onTimeChanged: ((Int) -> Void)?
  var onRoundEnded: (() -> Void)?

  private struct BubbleEntity {
    let node: BubbleNode
    let baseX: CGFloat
    let speed: CGFloat
    let driftAmplitude: CGFloat
    let driftRate: CGFloat
    let phase: CGFloat
  }

  private let cameraNode = SKCameraNode()
  private var bubbles: [BubbleEntity] = []
  private var pointerPositions: [CGPoint] = []
  private var elapsed: TimeInterval = 0
  private var lastUpdateTime: TimeInterval = 0
  private var nextSpawnTime: TimeInterval = 0
  private var lastPublishedSecond = Int(GameRules.roundDuration)
  private var isRoundRunning = false
  private var isRoundPaused = false
  private var lastSpawnWasBomb = false

  /// Set while an iPhone is supplying input. Automatic spawning stays on
  /// without one so a round can still be played and tested solo.
  private var isCooperative = false
  private var isBlowing = false
  private var blowStrength: Double = 0
  private var spawnCredit: Double = 0

  override init(size: CGSize) {
    super.init(size: size)
    scaleMode = .resizeFill
    backgroundColor = .clear
    cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
    addChild(cameraNode)
    camera = cameraNode
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMove(to view: SKView) {
    view.allowsTransparency = true
  }

  override func didChangeSize(_ oldSize: CGSize) {
    super.didChangeSize(oldSize)
    cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
  }

  /// Renders only the transparent SpriteKit layer. ResultPhotoComposer places
  /// it over the mirrored camera frame, preserving the actual bubble graphics
  /// without requiring Screen Recording permission.
  func snapshotImage() -> CGImage? {
    guard let texture = view?.texture(from: self) else { return nil }
    return texture.cgImage()
  }

  func prepareForReady() {
    isRoundRunning = false
    isRoundPaused = false
    elapsed = 0
    lastUpdateTime = 0
    pointerPositions = []
    removeAllBubbles(animated: false)
    removeEffectNodes()
    onTimeChanged?(Int(GameRules.roundDuration))
    isBlowing = false
    blowStrength = 0
    spawnCredit = 0
  }

  func startRound() {
    removeAllBubbles(animated: false)
    removeEffectNodes()
    elapsed = 0
    lastUpdateTime = 0
    nextSpawnTime = 0
    lastPublishedSecond = Int(GameRules.roundDuration)
    lastSpawnWasBomb = false
    isRoundPaused = false
    isRoundRunning = true
    onTimeChanged?(Int(GameRules.roundDuration))
    isBlowing = false
    blowStrength = 0
    spawnCredit = 0
  }

  func setRoundPaused(_ paused: Bool) {
    isRoundPaused = paused
    lastUpdateTime = 0
  }

  func updateHandPoses(_ poses: [HandPose], viewPoints: [Int: CGPoint]) {
    let scenePoints = Dictionary(
      uniqueKeysWithValues: viewPoints.map { id, point in
        (id, CGPoint(x: point.x, y: size.height - point.y))
      })
    pointerPositions = poses.compactMap { scenePoints[$0.id] }

    guard isRoundRunning, !isRoundPaused else {
      updateBubbleReveal()
      return
    }

    for pose in poses where pose.pinchBegan {
      guard let point = scenePoints[pose.id] else { continue }
      popBubble(at: point)
    }
    updateBubbleReveal()
  }

  /// Whether iPhone input drives bubble creation. Turning this on stops the
  /// timed difficulty curve from adding bubbles of its own, so the two sources
  /// never compete for the same screen.
  func setCooperative(_ cooperative: Bool) {
    guard isCooperative != cooperative else { return }
    isCooperative = cooperative
    spawnCredit = 0
    if !cooperative {
      isBlowing = false
      blowStrength = 0
      nextSpawnTime = elapsed
    }
  }

  /// The first bubble of a blow appears immediately. Waiting for the rate
  /// accumulator would put a visible gap between the player blowing and
  /// anything happening.
  func handleBlowStarted(strength: Double) {
    guard isRoundRunning, !isRoundPaused else { return }
    isBlowing = true
    blowStrength = min(max(strength, 0), 1)
    spawnCredit = 0
    spawnBlowBubble(strength: blowStrength)
  }

  func updateBlowState(isBlowing: Bool, strength: Double) {
    self.isBlowing = isBlowing
    blowStrength = isBlowing ? min(max(strength, 0), 1) : 0
    if !isBlowing { spawnCredit = 0 }
  }

  override func update(_ currentTime: TimeInterval) {
    guard isRoundRunning, !isRoundPaused else {
      lastUpdateTime = 0
      return
    }

    guard lastUpdateTime > 0 else {
      lastUpdateTime = currentTime
      return
    }

    let delta = min(currentTime - lastUpdateTime, 1.0 / 15.0)
    lastUpdateTime = currentTime
    elapsed += delta

    if elapsed >= GameRules.roundDuration {
      finishRound()
      return
    }

    publishRemainingTimeIfNeeded()
    if isCooperative {
      spawnFromBlow(deltaTime: delta)
    } else {
      spawnBubblesIfNeeded()
    }
    moveBubbles(deltaTime: delta)
    updateBubbleReveal()
  }

  private func publishRemainingTimeIfNeeded() {
    let remaining = max(0, Int(ceil(GameRules.roundDuration - elapsed)))
    guard remaining != lastPublishedSecond else { return }
    lastPublishedSecond = remaining
    onTimeChanged?(remaining)
  }

  /// Rate-driven creation. Credit never banks past a single bubble, so a full
  /// screen or a paused round drops the requests instead of releasing a burst
  /// once there is room again.
  private func spawnFromBlow(deltaTime: TimeInterval) {
    guard isBlowing, blowStrength > 0 else {
      spawnCredit = 0
      return
    }
    guard bubbles.count < GameRules.maximumBubbles else {
      spawnCredit = 0
      return
    }

    spawnCredit = min(
      spawnCredit + BlowSpawnRules.spawnRate(for: blowStrength) * deltaTime,
      1
    )
    guard spawnCredit >= 1 else { return }
    spawnCredit -= 1
    spawnBlowBubble(strength: blowStrength)
  }

  private func spawnBlowBubble(strength: Double) {
    guard bubbles.count < GameRules.maximumBubbles else { return }
    spawnBubble(
      difficulty: GameRules.difficulty(at: elapsed),
      strength: CGFloat(strength),
      riseSpeed: CGFloat(BlowSpawnRules.riseSpeed(for: strength))
    )
  }

  private func spawnBubblesIfNeeded() {
    while elapsed >= nextSpawnTime, bubbles.count < GameRules.maximumBubbles {
      let difficulty = GameRules.difficulty(at: elapsed)
      spawnBubble(difficulty: difficulty)
      nextSpawnTime += difficulty.spawnInterval
    }
  }

  /// `riseSpeed` is a fraction of the screen height per second. When it is nil
  /// the timed difficulty curve picks the speed, which is what the solo test
  /// mode uses.
  private func spawnBubble(
    difficulty: Difficulty,
    strength: CGFloat = 0.55,
    riseSpeed: CGFloat? = nil
  ) {
    guard size.width > 1, size.height > 1 else { return }

    let activeBombs = bubbles.lazy.filter { $0.node.isBomb }.count
    // No bombs in co-op. A hard blow creates eight bubbles a second, and a 20%
    // bomb chance on top of that turns a cooperative game into a minefield.
    // Difficulty options can bring them back later.
    let canSpawnBomb =
      !isCooperative
      && elapsed >= 5
      && activeBombs < GameRules.maximumBombs
      && !lastSpawnWasBomb
    let isBomb =
      canSpawnBomb
      && Double.random(in: 0...1) < difficulty.bombProbability

    let clampedStrength = max(0, min(strength, 1))
    let radius = CGFloat.random(in: 38...58) * (0.88 + clampedStrength * 0.22)
    let x = spawnX(radius: radius)
    let node = BubbleNode(radius: radius, isBomb: isBomb)
    node.position = CGPoint(x: x, y: -radius - 8)
    node.zPosition = 20
    node.alpha = 0
    node.setScale(0.85)
    addChild(node)
    node.run(
      .group([
        .fadeIn(withDuration: 0.22),
        .scale(to: 1, duration: 0.22),
      ]))

    bubbles.append(
      BubbleEntity(
        node: node,
        baseX: x,
        speed: (riseSpeed ?? CGFloat.random(in: difficulty.speedRange))
          * size.height,
        driftAmplitude: CGFloat.random(in: 0.02...0.05) * size.width,
        driftRate: CGFloat.random(in: 0.8...1.35),
        phase: CGFloat.random(in: 0...(2 * .pi))
      ))
    lastSpawnWasBomb = isBomb
  }

  private func spawnX(radius: CGFloat) -> CGFloat {
    let lowerBound = radius + 24
    let upperBound = max(lowerBound + 1, size.width - radius - 24)
    let range = lowerBound...upperBound
    var candidate = CGFloat.random(in: range)

    for _ in 0..<6 {
      let overlaps = bubbles.contains {
        $0.node.position.y < 150
          && abs($0.node.position.x - candidate)
            < ($0.node.bubbleRadius + radius) * 1.15
      }
      if !overlaps { return candidate }
      candidate = CGFloat.random(in: range)
    }
    return candidate
  }

  private func moveBubbles(deltaTime: TimeInterval) {
    var escapedIndices: [Int] = []

    for index in bubbles.indices {
      let bubble = bubbles[index]
      bubble.node.position.y += bubble.speed * CGFloat(deltaTime)
      let drift =
        sin(CGFloat(elapsed) * bubble.driftRate + bubble.phase)
        * bubble.driftAmplitude
      bubble.node.position.x = min(
        max(bubble.baseX + drift, bubble.node.bubbleRadius),
        size.width - bubble.node.bubbleRadius
      )

      if bubble.node.position.y - bubble.node.bubbleRadius > size.height {
        escapedIndices.append(index)
      }
    }

    for index in escapedIndices.reversed() {
      let bubble = bubbles.remove(at: index)
      bubble.node.removeFromParent()
      if !bubble.node.isBomb {
        onNormalMissed?()
      }
    }
  }

  private func updateBubbleReveal() {
    for bubble in bubbles {
      bubble.node.updateProximity(to: pointerPositions)
    }
  }

  private func popBubble(at point: CGPoint) {
    let candidates = bubbles.enumerated().compactMap { index, bubble -> (Int, CGFloat)? in
      let distance = hypot(
        bubble.node.position.x - point.x,
        bubble.node.position.y - point.y
      )
      return distance <= bubble.node.bubbleRadius * 1.18
        ? (index, distance)
        : nil
    }

    guard let target = candidates.min(by: { $0.1 < $1.1 }) else { return }
    let bubble = bubbles.remove(at: target.0)
    let effectPosition = bubble.node.position

    bubble.node.removeAllActions()
    if bubble.node.isBomb {
      bubble.node.revealBomb()
      showBombEffect(at: effectPosition, radius: bubble.node.bubbleRadius)
      AudioManager.shared.play(GameSound.bomb)
      NSHapticFeedbackManager.defaultPerformer.perform(
        .generic,
        performanceTime: .now
      )
      onBombTriggered?()
    } else {
      showPopEffect(at: effectPosition, radius: bubble.node.bubbleRadius)
      AudioManager.shared.play(GameSound.pops.randomElement() ?? GameSound.pops[0])
      onNormalPopped?()
    }

    bubble.node.run(
      .sequence([
        .group([
          .scale(to: 1.28, duration: 0.09),
          .fadeOut(withDuration: 0.09),
        ]),
        .removeFromParent(),
      ]))
  }

  private func showPopEffect(at position: CGPoint, radius: CGFloat) {
    let ring = SKShapeNode(circleOfRadius: radius)
    ring.name = "effect"
    ring.position = position
    ring.fillColor = .clear
    ring.strokeColor = NSColor.white.withAlphaComponent(0.82)
    ring.lineWidth = 2.2
    ring.zPosition = 120
    addChild(ring)
    ring.run(
      .sequence([
        .group([
          .scale(to: 1.62, duration: 0.18),
          .fadeOut(withDuration: 0.18),
        ]),
        .removeFromParent(),
      ]))

    for index in 0..<8 {
      let particle = SKShapeNode(circleOfRadius: max(2.5, radius * 0.07))
      particle.name = "effect"
      particle.position = position
      particle.fillColor = .white
      particle.strokeColor = .clear
      particle.zPosition = 121
      addChild(particle)

      let angle = CGFloat(index) / 8 * 2 * .pi
      let distance = radius * CGFloat.random(in: 1.0...1.65)
      particle.run(
        .sequence([
          .group([
            .moveBy(
              x: cos(angle) * distance,
              y: sin(angle) * distance,
              duration: 0.20
            ),
            .fadeOut(withDuration: 0.20),
            .scale(to: 0.25, duration: 0.20),
          ]),
          .removeFromParent(),
        ]))
    }
  }

  private func showBombEffect(at position: CGPoint, radius: CGFloat) {
    let flash = SKShapeNode(rectOf: size)
    flash.name = "effect"
    flash.position = CGPoint(x: size.width / 2, y: size.height / 2)
    flash.fillColor = NSColor.systemRed.withAlphaComponent(0.25)
    flash.strokeColor = .clear
    flash.zPosition = 150
    addChild(flash)
    flash.run(
      .sequence([
        .fadeOut(withDuration: 0.24),
        .removeFromParent(),
      ]))

    let ring = SKShapeNode(circleOfRadius: radius * 0.75)
    ring.name = "effect"
    ring.position = position
    ring.fillColor = NSColor.systemOrange.withAlphaComponent(0.30)
    ring.strokeColor = .systemYellow
    ring.lineWidth = 5
    ring.glowWidth = 8
    ring.zPosition = 151
    addChild(ring)
    ring.run(
      .sequence([
        .group([
          .scale(to: 2.3, duration: 0.24),
          .fadeOut(withDuration: 0.24),
        ]),
        .removeFromParent(),
      ]))

    cameraNode.run(
      .sequence([
        .moveBy(x: 8, y: 0, duration: 0.035),
        .moveBy(x: -15, y: 3, duration: 0.05),
        .moveBy(x: 10, y: -6, duration: 0.05),
        .move(to: CGPoint(x: size.width / 2, y: size.height / 2), duration: 0.05),
      ]))
  }

  private func finishRound() {
    guard isRoundRunning else { return }
    isRoundRunning = false
    isRoundPaused = false
    onTimeChanged?(0)
    // Capture callbacks run before nodes begin fading so the result photo
    // preserves the final camera-and-bubble frame.
    onRoundEnded?()
    removeAllBubbles(animated: true)
  }

  private func removeAllBubbles(animated: Bool) {
    for bubble in bubbles {
      if animated {
        bubble.node.run(
          .sequence([
            .fadeOut(withDuration: 0.18),
            .removeFromParent(),
          ]))
      } else {
        bubble.node.removeFromParent()
      }
    }
    bubbles.removeAll()
  }

  private func removeEffectNodes() {
    enumerateChildNodes(withName: "effect") { node, _ in
      node.removeFromParent()
    }
  }
}
