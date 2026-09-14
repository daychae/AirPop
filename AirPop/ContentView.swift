import AppKit
import SpriteKit
import SwiftUI
import UniformTypeIdentifiers

/// The five pastel colors used across the AirPuff/AirPop bubble design
/// system, scoped here to the HUD/panel chrome rather than the gameplay
/// bubbles themselves. Backed by the designer's handoff color set
/// (`Assets.xcassets/Colors`, namespaced -- hence "Colors/Sky" rather than
/// "Sky") instead of the hand-picked hex values these five used to be:
/// skyBlue -> Sky, lavender -> Lilac (this app's own signature, already
/// nicknamed "Pop Lilac" before the real asset existed), mint -> Aqua
/// (closest cool tone in the set to the old green-mint), pink -> Blossom,
/// peach -> Apricot (both nearest-hex matches to the previous values).
private enum Brand {
  static let skyBlue = Color("Colors/Sky")
  static let lavender = Color("Colors/Lilac")
  static let mint = Color("Colors/Aqua")
  static let pink = Color("Colors/Blossom")
  static let peach = Color("Colors/Apricot")
}

/// Google Sans Flex (bundled at `Fonts/GoogleSansFlex.ttf`, registered at
/// launch in `AirPopApp.init`) for the start screen's English text --
/// "AirPop", the Puff/Pop/Pose tagline and step titles, the device labels.
/// Korean text on the same screen stays on the system font; Google Sans
/// Flex has no Hangul coverage, and Core Text falls back automatically for
/// any glyph it's missing, so a mixed-language Text still renders correctly.
///
/// `wght` is the font's own OpenType axis value (100...900 -- Thin through
/// Black), not `NSFont.Weight`. The abstract weight *trait* descriptor
/// (the technique `ResultPhotoComposer.CaptionLayout.sfProExpanded` uses
/// for SF Pro's width axis) turned out not to reliably resolve to this
/// third-party font's named instances -- "black" rendered as barely
/// heavier than regular -- so this sets the `wght` variation axis
/// directly instead, which every variable font must honor.
private func googleSansFlex(wght: CGFloat, size: CGFloat) -> Font {
  let wghtAxisTag: UInt32 = 0x77_67_68_74  // 'wght' as a big-endian tag
  let descriptor = NSFontDescriptor(fontAttributes: [
    .name: "Google Sans Flex",
    .size: size,
    .variation: [wghtAxisTag: wght],
  ])
  guard let font = NSFont(descriptor: descriptor, size: size) else {
    return .system(size: size, weight: .semibold)
  }
  return Font(font)
}

struct ContentView: View {
  @StateObject private var tracker = CameraHandTracker()
  @StateObject private var cameraCoordinates = CameraCoordinateMapper()
  @StateObject private var game = GameSession()
  @StateObject private var blowServer = AirPopBonjourServer()
  @State private var showsDiagnostics = false
  @State private var showsCredits = false
  @State private var hostAddress: HostAddress.Entry?
  @State private var photoSaveMessage: String?
  @State private var photoFlashOpacity: Double = 0
  @State private var countdownOverlayOpacity: Double = 0
  @State private var trailSparkles: [TrailSparkle] = []
  @State private var lastTrailSpawn = Date.distantPast

  var body: some View {
    ZStack {
      CameraPreview(
        session: tracker.session,
        coordinateMapper: cameraCoordinates
      )
      .ignoresSafeArea()

      Color.black.opacity(0.16)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      SpriteView(
        scene: game.scene,
        options: [.allowsTransparency]
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      HandOverlayView(
        poses: tracker.poses,
        coordinateMapper: cameraCoordinates
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      if game.phase.showsHUD {
        hud
      }

      phaseOverlay

      if showsDiagnostics {
        diagnosticsOverlay
      }

      // Photo Booth-style final countdown: designer-provided edge bubbles
      // fade in over the still-live game, with a ring+number badge in the
      // center that pops in fresh each second (per
      // iOS_macOS_app_frames_updated_5/README.txt). Deliberately not a full
      // white flash each second -- that would hide the bubbles/hands a
      // player may still be popping. The single strong flash below is
      // reserved for the actual capture at 0.
      finalCountdownOverlay

      // Camera-flash stand-in: there's no physical flash on a Mac, so the
      // "photo taken" moment is a plain white layer that snaps to fully
      // opaque, then fades out (see the photoCaptureTrigger onChange
      // below) -- the screen-based equivalent of a shutter flash.
      Color.white
        .opacity(photoFlashOpacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    .background(.black)
    .background {
      // Hidden control so `D` toggles the diagnostics panel. It stays off by
      // default: the numbers must not cover the game during an exhibition.
      Group {
        Button("Toggle diagnostics") {
          showsDiagnostics.toggle()
        }
        .keyboardShortcut("d", modifiers: [])

        // The threshold that feels right depends on how far the player stands
        // from the camera, so it is adjustable on site rather than rebuilt.
        Button("Looser pinch") {
          tracker.adjustPinchEnterRatio(by: 0.03)
          showsDiagnostics = true
        }
        .keyboardShortcut("]", modifiers: [])

        Button("Tighter pinch") {
          tracker.adjustPinchEnterRatio(by: -0.03)
          showsDiagnostics = true
        }
        .keyboardShortcut("[", modifiers: [])
      }
      .opacity(0)
    }
    .sheet(isPresented: $showsCredits) {
      CreditsView()
    }
    .onAppear {
      hostAddress = HostAddress.preferred()
      game.setModelReady(tracker.isMLReady)
      AudioManager.shared.preload()
      let scene = game.scene
      game.resultPhotoProvider = { [weak tracker, weak scene] _, _ in
        guard
          let cameraImage = tracker?.latestCameraImage(),
          let scene
        else {
          return nil
        }
        return ResultPhotoComposer.make(
          cameraImage: cameraImage,
          overlayImage: scene.snapshotImage(),
          canvasSize: scene.size
        )
      }
      blowServer.start(
        onBlowStarted: { strength in
          game.handleBlowStarted(strength: strength)
        },
        onBlowState: { isBlowing, strength in
          game.updateBlowState(isBlowing: isBlowing, strength: strength)
        })
    }
    .onDisappear {
      game.resultPhotoProvider = nil
      blowServer.stop()
    }
    .onChange(of: blowServer.listenerPort) { _, _ in
      hostAddress = HostAddress.preferred()
    }
    .onChange(of: blowServer.isPeerConnected) { _, connected in
      game.setPeerConnected(connected)
      // A phone joining mid-round would otherwise show nothing until the next
      // phase change, which on a 30 second round can be most of it.
      if connected {
        blowServer.sendGameState(
          game.phase.wire,
          countdownValue: game.phase.countdownValue
        )
      }
    }
    .onChange(of: blowServer.isPeerMicReady) { _, ready in
      game.setPeerMicReady(ready)
    }
    .onChange(of: game.phase) { _, phase in
      // The Mac owns round state, so the phone is told rather than asked.
      blowServer.sendGameState(phase.wire, countdownValue: phase.countdownValue)
    }
    .onChange(of: game.timeRemaining) { _, remaining in
      // The edge overlay fades in once, when the countdown starts; the
      // per-second badge swap (Countdown5 -> Countdown1) is driven directly
      // by `game.timeRemaining` inside finalCountdownOverlay's own
      // `.animation(value:)`, not from here.
      guard remaining == 5 else { return }
      withAnimation(.easeOut(duration: 0.4)) {
        countdownOverlayOpacity = 1
      }
    }
    .onChange(of: game.photoCaptureTrigger) { _, _ in
      // Snap to fully opaque with no animation, then animate the fade --
      // an actual flash, not a slow cross-fade in either direction.
      photoFlashOpacity = 1
      withAnimation(.easeOut(duration: 0.3)) {
        photoFlashOpacity = 0
      }
      withAnimation(.easeIn(duration: 0.25)) {
        countdownOverlayOpacity = 0
      }
      // Placeholder for a real shutter sound: no camera_shutter.wav is
      // bundled yet, so this uses a short built-in system sound instead.
      // Swap in AudioManager.shared.play("camera_shutter") once one is
      // added to Assets/Sounds.
      NSSound(named: "Tink")?.play()
    }
    .onChange(of: showsDiagnostics) { _, isShown in
      // Interfaces come and go while the app runs, most notably when a USB
      // cable is plugged in, so re-read rather than trusting the launch value.
      if isShown { hostAddress = HostAddress.preferred() }
    }
    .onReceive(tracker.$poses) { poses in
      let viewPoints = Dictionary(
        uniqueKeysWithValues: poses.compactMap { pose in
          // The stabilized aim, not the raw fingertip midpoint: closing a
          // pinch moves the midpoint several bubble radii.
          cameraCoordinates.viewPoint(
            fromCaptureDevicePoint: pose.pointer
          ).map { (pose.id, $0) }
        })
      game.handleHandPoses(poses, viewPoints: viewPoints)
    }
  }

  private var hud: some View {
    VStack {
      HStack(spacing: 14) {
        hudCard(title: "SCORE", value: "\(game.score)", tint: Brand.lavender)

        Spacer()

        VStack(spacing: 2) {
          Text("TIME")
            .font(googleSansFlex(wght: 700, size: 12))
            .foregroundStyle(.white.opacity(0.72))
          Text("\(game.timeRemaining)")
            .font(.system(size: 40, weight: .bold, design: .default))
            .foregroundStyle(game.timeRemaining <= 5 ? .red : .white)
            .contentTransition(.numericText())
        }
        .frame(width: 130)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

        Spacer()

        hudCard(title: "BEST", value: "\(game.highScore)", tint: Brand.skyBlue)
      }
      .padding(.horizontal, 24)
      .padding(.top, 18)

      Spacer()

      HStack {
        handStatusPill
        blowStatusPill
        Spacer()
        if game.combo >= 2 {
          Text("\(game.combo) COMBO")
            .font(googleSansFlex(wght: 700, size: 17))
            .foregroundStyle(Brand.pink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.52), in: Capsule())
        }
      }
      .padding(24)
    }
  }

  @ViewBuilder
  private var finalCountdownOverlay: some View {
    if game.phase == .playing, (1...5).contains(game.timeRemaining) {
      GeometryReader { proxy in
        let shortSide = min(proxy.size.width, proxy.size.height)

        // Decorative bubbles along the screen edges; the center stays fully
        // transparent so it never competes with gameplay. Scaled to fill
        // rather than matched to the capture aspect ratio -- it is edge
        // art, so the crop from scaledToFill isn't noticeable.
        Image("CountdownOverlayCool")
          .resizable()
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
          .opacity(countdownOverlayOpacity)

        // Ring + number badge, swapped fresh each second. `.id` forces
        // SwiftUI to treat each count as a new view so the pop-in/pop-out
        // transition replays every tick instead of cross-fading digits.
        Image("Countdown\(game.timeRemaining)")
          .resizable()
          .frame(width: shortSide * 0.4, height: shortSide * 0.4)
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
          .transition(.scale(scale: 1.12).combined(with: .opacity))
          .id(game.timeRemaining)
          .animation(.easeOut(duration: 0.28), value: game.timeRemaining)

        // A nudge toward better framing, not a rule -- small and muted so
        // it doesn't compete with the ring/number for attention.
        Text("화면 중앙에 서주세요")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(.white.opacity(0.75))
          .padding(.horizontal, 28)
          .padding(.vertical, 14)
          .background(.black.opacity(0.35), in: Capsule())
          .position(x: proxy.size.width / 2, y: proxy.size.height - 80)
          .opacity(countdownOverlayOpacity)
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var phaseOverlay: some View {
    if tracker.permissionDenied {
      permissionPanel
    } else {
      switch game.phase {
      case .ready:
        startPanel
      case .countdown(let value):
        Text("\(value)")
          .font(.system(size: 150, weight: .bold, design: .default))
          .foregroundStyle(.white)
          .shadow(color: Brand.lavender, radius: 22)
          // A single big digit's own glyph bounds sit higher than the
          // font's full line box (which reserves room for descenders no
          // digit uses), so centering the text view itself still reads as
          // pushed up -- nudge it down to compensate.
          .offset(y: 12)
      case .playing:
        EmptyView()
      case .pausedHandLost:
        GlassPanel {
          VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
              .font(.system(size: 44))
              .foregroundStyle(.yellow)
            Text("손을 다시 보여주세요")
              .font(.title.bold())
            Text("한 손 이상이 안정적으로 인식되면 자동으로 계속됩니다.")
              .foregroundStyle(.secondary)
          }
          .padding(12)
        }
      case .pausedPeerLost:
        GlassPanel {
          VStack(spacing: 14) {
            Image(systemName: "iphone.slash")
              .font(.system(size: 44))
              .foregroundStyle(.orange)
            Text("아이폰 연결이 끊겼습니다")
              .font(.title.bold())
            Text("A 플레이어의 AirPuff 앱을 확인해 주세요.\n다시 연결되면 자동으로 계속됩니다.")
              .multilineTextAlignment(.center)
              .foregroundStyle(.secondary)
          }
          .padding(12)
        }
      case .result:
        resultPanel
      }
    }
  }

  private var startPanel: some View {
    ZStack {
      GlassPanel {
        VStack(spacing: 18) {
          Text("AirPop")
            .font(googleSansFlex(wght: 800, size: 58))
            .foregroundStyle(.white)

          startTagline

          HStack(spacing: 14) {
            playStep(
              1, title: "Puff", detail: "아이폰에 대고\n후 불기",
              device: "AirPuff · iPhone", tint: Brand.skyBlue)
            stepConnector
            playStep(
              2, title: "Pop", detail: "엄지·검지로\n톡 터뜨리기",
              device: "AirPop · 손동작", tint: Brand.lavender)
            stepConnector
            playStep(
              3, title: "Pose", detail: "5초 카운트다운\n뒤 촬영",
              device: "마지막 순간, 찰칵", tint: Brand.peach)
          }

          HStack(spacing: 10) {
            ReadinessPill(
              title: "손동작 인식됨",
              isReady: game.hasHands && game.isModelReady,
              tint: Brand.mint)
            ReadinessPill(
              title: "아이폰 연결됨",
              isReady: game.isPeerConnected,
              tint: Brand.skyBlue)
            ReadinessPill(
              title: game.isPeerMicReady ? "마이크 준비 완료" : "마이크 준비 중",
              isReady: game.isPeerMicReady,
              tint: Brand.pink)
          }

          if let hostAddress, blowServer.listenerPort > 0 {
            Text("\(hostAddress.address) : \(String(blowServer.listenerPort))")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.white.opacity(0.5))
              .textSelection(.enabled)
          }

          Label(
            "테스트 기능 · 종료 순간 카메라와 버블을 결과 사진으로 만듭니다",
            systemImage: "camera.aperture"
          )
          .font(.caption)
          .foregroundStyle(.white.opacity(0.62))

          Button("게임 시작") {
            game.beginCountdown()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(Brand.lavender)
          .disabled(!game.canStart)
          .keyboardShortcut(.space, modifiers: [])

          // Exhibition visitors don't go looking through a menu bar for
          // an "About" item, so the font/tech acknowledgments live one
          // tap away on the screen they'll actually be looking at.
          Button("ⓘ 크레딧") {
            showsCredits = true
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
      }

      // A trail of soft, frosted droplets follows the pointer while it
      // hovers the start screen -- purely decorative, so it never
      // intercepts clicks.
      ForEach(trailSparkles) { TrailSparkleView(sparkle: $0) }
        .allowsHitTesting(false)
    }
    .onContinuousHover { phase in
      guard case .active(let location) = phase else { return }
      let now = Date()
      // Thinned out from every 0.04s -- a dense trail read as clutter.
      guard now.timeIntervalSince(lastTrailSpawn) >= 0.16 else { return }
      lastTrailSpawn = now

      let colors = [Brand.skyBlue, Brand.lavender, Brand.peach, .white]
      let sparkle = TrailSparkle(
        position: location,
        color: colors.randomElement() ?? .white,
        size: CGFloat.random(in: 7...15),
        dx: CGFloat.random(in: -10...10),
        dy: CGFloat.random(in: -22...(-6))
      )
      trailSparkles.append(sparkle)

      DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
        trailSparkles.removeAll { $0.id == sparkle.id }
      }
    }
  }

  private var startTagline: some View {
    (
      Text("Puff").foregroundColor(Brand.skyBlue)
      + Text(", ").foregroundColor(.white.opacity(0.65))
      + Text("Pop").foregroundColor(Brand.lavender)
      + Text(" and ").foregroundColor(.white.opacity(0.65))
      + Text("Pose").foregroundColor(Brand.peach)
    )
    .font(googleSansFlex(wght: 600, size: 22))
  }

  private func playStep(
    _ number: Int,
    title: String,
    detail: String,
    device: String,
    tint: Color
  ) -> some View {
    VStack(spacing: 6) {
      Text("\(number)")
        .font(.system(size: 18, weight: .bold, design: .default))
        .foregroundStyle(.black.opacity(0.75))
        .frame(width: 40, height: 40)
        .background(
          LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom),
          in: Circle()
        )
      Text(title)
        .font(googleSansFlex(wght: 700, size: 15))
        .foregroundStyle(tint)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Text(device)
        .font(googleSansFlex(wght: 400, size: 11))
        .foregroundStyle(.white.opacity(0.4))
    }
    .frame(width: 118)
  }

  private var stepConnector: some View {
    Path { path in
      path.move(to: CGPoint(x: 0, y: 0))
      path.addLine(to: CGPoint(x: 28, y: 0))
    }
    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    .frame(width: 28, height: 1)
    .padding(.top, 20)
  }

  private var permissionPanel: some View {
    GlassPanel {
      VStack(spacing: 18) {
        Image(systemName: "camera.fill")
          .font(.system(size: 50))
          .foregroundStyle(Brand.lavender)
        Text("카메라 권한이 필요합니다")
          .font(.title.bold())
        Text("AirPop이 손동작을 인식할 수 있도록\n시스템 설정에서 카메라 접근을 허용해주세요.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
        Button("카메라 설정 열기") {
          openCameraSettings()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }

  private var resultPanel: some View {
    GlassPanel {
      VStack(spacing: 16) {
        Text("TIME UP!")
          .font(googleSansFlex(wght: 700, size: 44))
        if game.isNewHighScore {
          Text("NEW BEST")
            .font(googleSansFlex(wght: 700, size: 17))
            .foregroundStyle(Brand.peach)
        }
        Text("\(game.score)")
          .font(.system(size: 76, weight: .bold, design: .default))
          .foregroundStyle(Brand.lavender)

        // Bombs are co-op-only and disabled in the two-player mode this
        // game actually ships with, so a "폭탄" stat here always reads 0 --
        // dropped rather than shown as permanent dead weight.
        HStack(spacing: 32) {
          resultStat("버블", value: game.normalPopped, color: Brand.lavender)
          resultStat("놓침", value: game.missed, color: .gray)
          resultStat("최고 콤보", value: game.bestCombo, color: Brand.pink)
        }

        if let photo = game.resultPhoto {
          // PhotoFrameCool is a square 1200x1200 card with its own border
          // and bubbles baked in, so the preview just needs to size it --
          // no extra clip shape or stroke on top of the frame art itself.
          Image(nsImage: photo)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 320, maxHeight: 320)
            .shadow(color: Brand.skyBlue.opacity(0.28), radius: 20)

          HStack(spacing: 12) {
            Button("PNG 저장") {
              saveResultPhoto(photo)
            }
            .buttonStyle(.bordered)

            Button("다시 하기") {
              photoSaveMessage = nil
              game.returnToReady()
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.lavender)
            .keyboardShortcut(.return, modifiers: [])
          }
        } else {
          Text("결과 사진을 만들지 못했습니다. 카메라 상태를 확인해 주세요.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button("다시 하기") {
            photoSaveMessage = nil
            game.returnToReady()
          }
          .buttonStyle(.borderedProminent)
          .tint(Brand.lavender)
          .keyboardShortcut(.return, modifiers: [])
        }

        if let photoSaveMessage {
          Text(photoSaveMessage)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
        }
      }
      .padding(.horizontal, 10)
    }
  }

  private var handStatusPill: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(game.hasHands ? Color.green : Color.orange)
        .frame(width: 9, height: 9)
      Text(
        game.hasHands
          ? "\(game.handCount)/4 HANDS"
          : "손을 찾는 중"
      )
      .font(googleSansFlex(wght: 700, size: 12))
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 8)
    .background(.black.opacity(0.52), in: Capsule())
  }

  private var blowStatusPill: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(blowStatus.color)
        .frame(width: 9, height: 9)
      Text(blowStatus.label)
        .font(googleSansFlex(wght: 700, size: 12))
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 8)
    .background(.black.opacity(0.52), in: Capsule())
  }

  /// "Connected" and "actually receiving input" are different states, and only
  /// separating them makes a silent phone diagnosable at a glance.
  private var blowStatus: (color: Color, label: String) {
    switch blowServer.linkState {
    case .connected:
      if blowServer.isBlowing {
        return (.cyan, "불기 중 · \(Int(blowServer.latestStrength * 100))%")
      }
      return blowServer.isLive
        ? (.green, "IPHONE 활성")
        : (.yellow, "IPHONE 연결됨 · 입력 없음")
    case .advertising:
      return (.orange, "IPHONE 대기 중")
    case .starting, .stopped:
      return (.orange, "BONJOUR 시작 중")
    case .protocolMismatch(let version):
      return (.red, "앱 버전 불일치 (v\(version))")
    case .failed:
      return (.red, "네트워크 오류")
    }
  }

  /// Hidden behind `D`. Everything here answers one question: is a silent Mac
  /// silent because nothing arrived, or because what arrived was rejected?
  private var diagnosticsOverlay: some View {
    VStack {
      HStack {
        Spacer()
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
          VStack(alignment: .leading, spacing: 3) {
            diagnosticRow("LINK", linkSummary)
            diagnosticRow("ADDRESS", addressSummary)
            diagnosticRow("PATH", blowServer.pathDescription ?? "—")
            diagnosticRow("RECEIVED", receivedSummary)
            diagnosticRow("INTERVAL", intervalSummary)
            diagnosticRow("RTT", rttSummary)
            diagnosticRow("GAPS", gapSummary)
            diagnosticRow("STRENGTH", strengthSummary)
            diagnosticRow("HANDS", handSummary)
            diagnosticRow("GESTURE", gestureSummary)
          }
          .padding(14)
          .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 14))
          .overlay {
            RoundedRectangle(cornerRadius: 14)
              .stroke(.white.opacity(0.14), lineWidth: 1)
          }
        }
      }
      Spacer()
    }
    .padding(20)
    .allowsHitTesting(false)
  }

  private func diagnosticRow(_ title: String, _ value: String) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.45))
        .frame(width: 74, alignment: .leading)
      Text(value)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
    }
  }

  private var linkSummary: String {
    switch blowServer.linkState {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .advertising: return "advertising · no peer"
    case .connected:
      let name = blowServer.peerName ?? "peer"
      let session = blowServer.sessionShortID ?? "??????"
      let mic = blowServer.isPeerMicReady ? "mic ready" : "mic not ready"
      return "\(blowServer.isLive ? "live" : "idle") · \(name) (\(session)) · \(mic)"
    case .protocolMismatch(let version):
      return "PROTOCOL MISMATCH · peer v\(version), self v\(AirPopLink.protocolVersion)"
    case .failed(let message): return "failed · \(message)"
    }
  }

  private var addressSummary: String {
    guard blowServer.listenerPort > 0 else { return "—" }
    let host = hostAddress.map { "\($0.address) (\($0.interface))" } ?? "?"
    return "\(host) : \(String(blowServer.listenerPort))"
  }

  private var receivedSummary: String {
    guard let last = blowServer.lastMessageAtMillis else {
      return "\(blowServer.receivedCount) msgs · never"
    }
    let elapsed = Int(AirPopClock.elapsed(since: last).rounded())
    return "\(blowServer.receivedCount) msgs · \(elapsed) ms ago"
  }

  private var intervalSummary: String {
    let stats = blowServer.intervalStats
    guard stats.count > 0 else { return "—" }
    return String(
      format: "p50 %.0f · p95 %.0f · max %.0f ms (n=%d)",
      stats.p50, stats.p95, stats.maximum, stats.count
    )
  }

  private var rttSummary: String {
    guard let rtt = blowServer.peerReportedRTT else { return "—" }
    return String(format: "%.1f ms (peer reported)", rtt)
  }

  private var gapSummary: String {
    // Gaps should stay at zero: coalesced values never consume a sequence
    // number, so anything here is loss or a bug rather than normal throttling.
    "\(blowServer.sequenceGapCount) (expect 0) · coalesced by peer: "
      + "\(blowServer.peerDroppedCount)"
  }

  private var strengthSummary: String {
    String(
      format: "%.2f · %@ · %@",
      blowServer.latestStrength,
      blowServer.isBlowing ? "blowing" : "idle",
      blowServer.isLive ? "live" : "stale"
    )
  }

  /// Rejected hands are the number Vision found but the confidence gate threw
  /// away. A steady stream of them at the venue means the threshold, not the
  /// lighting, is what needs adjusting.
  private var handSummary: String {
    let pinching = tracker.poses.filter(\.isPinching).count
    // The live pinch ratio is what the enter and exit thresholds are compared
    // against, so showing it turns tuning at the venue into reading a number
    // rather than guessing.
    let ratios = tracker.poses
      .map { String(format: "%.2f", $0.pinchRatio) }
      .joined(separator: " ")
    return "\(tracker.poses.count) tracked · \(pinching) pinching · "
      + "\(tracker.rejectedHandCount) rejected · ratio [\(ratios)]"
  }

  private var gestureSummary: String {
    String(
      format: "enter %.2f · release %.2f · %@  ( [ / ] to adjust )",
      tracker.pinchEnterRatio,
      tracker.pinchEnterRatio + 0.18,
      tracker.classifierName
    )
  }

  private func hudCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(googleSansFlex(wght: 700, size: 12))
        .foregroundStyle(.white.opacity(0.68))
      Text(value)
        .font(.system(size: 32, weight: .bold, design: .default))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(width: 110, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
  }

  private func resultStat(_ title: String, value: Int, color: Color) -> some View {
    VStack(spacing: 4) {
      Text("\(value)")
        .font(.title2.bold())
        .foregroundStyle(color)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(minWidth: 72)
  }

  private func openCameraSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func saveResultPhoto(_ image: NSImage) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "AirPop-\(photoTimestamp).png"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else {
      photoSaveMessage = "PNG 변환에 실패했습니다."
      return
    }

    do {
      try png.write(to: url, options: .atomic)
      photoSaveMessage = "\(url.lastPathComponent) 저장 완료"
    } catch {
      photoSaveMessage = "저장 실패: \(error.localizedDescription)"
    }
  }

  private var photoTimestamp: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}

private struct GlassPanel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(30)
      .foregroundStyle(.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
      .background {
        // A faint sky blue → lavender wash over the system material, so
        // panels read as part of the bubble family rather than plain
        // macOS chrome.
        RoundedRectangle(cornerRadius: 28)
          .fill(
            LinearGradient(
              colors: [Brand.skyBlue.opacity(0.10), Brand.lavender.opacity(0.10)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 28)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
  }
}

/// A 4-point sparkle/twinkle outline, matching the shape used for the bubble
/// accent in GameScene (`sparkleStarPath`) -- all four outer points sit at
/// the same radius, with the concave waist pulled toward the diagonals, so
/// it reads as a symmetric twinkle rather than a squashed lens.
private struct SparkleShape: Shape {
  func path(in rect: CGRect) -> Path {
    let r = min(rect.width, rect.height) / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let waist = r * 0.32
    let top = CGPoint(x: c.x, y: c.y - r)
    let right = CGPoint(x: c.x + r, y: c.y)
    let bottom = CGPoint(x: c.x, y: c.y + r)
    let left = CGPoint(x: c.x - r, y: c.y)

    var path = Path()
    path.move(to: top)
    path.addQuadCurve(to: right, control: CGPoint(x: c.x + waist, y: c.y - waist))
    path.addQuadCurve(to: bottom, control: CGPoint(x: c.x + waist, y: c.y + waist))
    path.addQuadCurve(to: left, control: CGPoint(x: c.x - waist, y: c.y + waist))
    path.addQuadCurve(to: top, control: CGPoint(x: c.x - waist, y: c.y - waist))
    path.closeSubpath()
    return path
  }
}

/// A small rounded-pill readiness indicator -- a lighter-weight readout than
/// the previous detailed diagnostic rows, matching the "Puff, Pop, Pose"
/// mockup's three status chips. Deeper diagnostics (model name, connection
/// detail) stay available in the hidden `D`-toggled diagnostics overlay.
private struct ReadinessPill: View {
  let title: String
  let isReady: Bool
  /// Identifies which of the three conditions this pill is (hand/gesture,
  /// iPhone, mic) via its border and wash, distinct from the dot's own
  /// green/gray, which stays the one signal for "ready or not" -- color
  /// variety without muddying that at-a-glance status read.
  let tint: Color
  @State private var isPulsing = false

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(isReady ? Color.green : Color.white.opacity(0.35))
        .frame(width: 7, height: 7)
        .opacity(isReady || isPulsing ? 1 : 0.4)
        .onAppear {
          guard !isReady else { return }
          withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            isPulsing = true
          }
        }
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.75))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(tint.opacity(0.14), in: Capsule())
    .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
  }
}

/// One soft, frosted droplet spawned under the pointer while it hovers the
/// start screen -- modeled on the actual app icon's bubbles (glow bloom,
/// wide soft highlight, faint rim, tiny white twinkle) rather than a plain
/// translucent dot, so the trail reads as the same glass bubbles instead of
/// generic air bubbles.
private struct TrailSparkle: Identifiable {
  let id = UUID()
  let position: CGPoint
  let color: Color
  let size: CGFloat
  let dx: CGFloat
  let dy: CGFloat
}

private struct TrailSparkleView: View {
  let sparkle: TrailSparkle
  @State private var scale: CGFloat = 0.4
  @State private var opacity: Double = 0.9
  @State private var offset: CGSize = .zero

  var body: some View {
    ZStack {
      // Soft outer bloom -- the app icon's bubbles glow past their own
      // edge rather than stopping at a hard boundary.
      Circle()
        .fill(sparkle.color.opacity(0.35))
        .frame(width: sparkle.size * 2, height: sparkle.size * 2)
        .blur(radius: sparkle.size * 0.4)

      // The glassy sphere: a wide, soft highlight easing into the tint
      // rather than fading to nothing, plus the faint rim the icon's
      // bubbles show at their edge.
      Circle()
        .fill(
          RadialGradient(
            colors: [
              .white.opacity(0.95),
              sparkle.color.opacity(0.85),
              sparkle.color.opacity(0.55),
            ],
            center: UnitPoint(x: 0.32, y: 0.28),
            startRadius: 0,
            endRadius: sparkle.size * 0.62
          )
        )
        .overlay(
          Circle().strokeBorder(.white.opacity(0.5), lineWidth: max(0.6, sparkle.size * 0.05))
        )
        .frame(width: sparkle.size, height: sparkle.size)

      // The small 4-point twinkle every bubble on the app icon carries.
      SparkleShape()
        .fill(.white)
        .frame(width: sparkle.size * 0.34, height: sparkle.size * 0.34)
        .offset(x: -sparkle.size * 0.14, y: -sparkle.size * 0.10)
    }
    .scaleEffect(scale)
    .offset(offset)
    .opacity(opacity)
    .position(sparkle.position)
    .onAppear {
        withAnimation(.easeOut(duration: 0.35)) {
          scale = 1.2
          offset = CGSize(width: sparkle.dx * 0.5, height: sparkle.dy * 0.5)
        }
        // Grows and fades rather than shrinking away, echoing the same
        // "dissolves like a breath" exit used for the pop effect's sparkles
        // -- slowed down so it drifts rather than darts.
        withAnimation(.easeOut(duration: 0.85).delay(0.35)) {
          scale = 1.7
          opacity = 0
          offset = CGSize(width: sparkle.dx, height: sparkle.dy)
        }
      }
  }
}
