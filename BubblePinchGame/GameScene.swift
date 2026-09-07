import AppKit
import SpriteKit

private final class BubbleNode: SKNode {
  let bubbleRadius: CGFloat
  let isBomb: Bool

  private let shell: SKShapeNode
  private let baseStrokeColor: NSColor
  private let bombMark = SKNode()

  init(radius: CGFloat, isBomb: Bool) {
    bubbleRadius = radius
    self.isBomb = isBomb

    let hue = CGFloat.random(in: 0...1)
    baseStrokeColor = NSColor(
      hue: hue,
      saturation: 0.48,
      brightness: 1,
      alpha: 0.92
    )
    shell = SKShapeNode(circleOfRadius: radius)

    super.init()

    shell.fillColor = NSColor(
      hue: hue,
      saturation: 0.28,
      brightness: 1,
      alpha: 0.13
    )
    shell.strokeColor = baseStrokeColor
    shell.lineWidth = 2.6
    shell.glowWidth = 1.8
    addChild(shell)

    let innerRing = SKShapeNode(circleOfRadius: radius * 0.86)
    innerRing.fillColor = .clear
    innerRing.strokeColor = NSColor.white.withAlphaComponent(0.28)
    innerRing.lineWidth = 0.9
    innerRing.position = CGPoint(x: -radius * 0.07, y: radius * 0.05)
    addChild(innerRing)

    let highlight = SKShapeNode(
      ellipseOf: CGSize(
        width: radius * 0.42,
        height: radius * 0.19
      ))
    highlight.fillColor = NSColor.white.withAlphaComponent(0.62)
    highlight.strokeColor = .clear
    highlight.position = CGPoint(x: -radius * 0.30, y: radius * 0.36)
    highlight.zRotation = -0.55
    addChild(highlight)

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
      shell.strokeColor =
        hovered
        ? NSColor.systemRed.withAlphaComponent(0.92)
        : baseStrokeColor
    }
  }

  func revealBomb() {
    bombMark.alpha = 1
    shell.strokeColor = .systemRed
    shell.fillColor = NSColor.systemRed.withAlphaComponent(0.20)
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

  func prepareForReady() {
    isRoundRunning = false
    isRoundPaused = false
    elapsed = 0
    lastUpdateTime = 0
    pointerPositions = []
    removeAllBubbles(animated: false)
    removeEffectNodes()
    onTimeChanged?(Int(GameRules.roundDuration))
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

  /// Creates an extra bubble using the strength received from the iPhone.
  func spawnBubble(strength: CGFloat = 0.55) {
    guard isRoundRunning, !isRoundPaused else { return }
    let difficulty = GameRules.difficulty(at: elapsed)
    spawnBubble(difficulty: difficulty, strength: strength)
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
    spawnBubblesIfNeeded()
    moveBubbles(deltaTime: delta)
    updateBubbleReveal()
  }

  private func publishRemainingTimeIfNeeded() {
    let remaining = max(0, Int(ceil(GameRules.roundDuration - elapsed)))
    guard remaining != lastPublishedSecond else { return }
    lastPublishedSecond = remaining
    onTimeChanged?(remaining)
  }

  private func spawnBubblesIfNeeded() {
    while elapsed >= nextSpawnTime, bubbles.count < GameRules.maximumBubbles {
      let difficulty = GameRules.difficulty(at: elapsed)
      spawnBubble(difficulty: difficulty)
      nextSpawnTime += difficulty.spawnInterval
    }
  }

  private func spawnBubble(
    difficulty: Difficulty,
    strength: CGFloat = 0.55
  ) {
    guard size.width > 1, size.height > 1 else { return }

    let activeBombs = bubbles.lazy.filter { $0.node.isBomb }.count
    let canSpawnBomb =
      elapsed >= 5
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
        speed: CGFloat.random(in: difficulty.speedRange) * size.height,
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
      NSHapticFeedbackManager.defaultPerformer.perform(
        .generic,
        performanceTime: .now
      )
      onBombTriggered?()
    } else {
      showPopEffect(at: effectPosition, radius: bubble.node.bubbleRadius)
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
    removeAllBubbles(animated: true)
    onRoundEnded?()
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
