import AppKit
import SpriteKit
import SwiftUI
import UniformTypeIdentifiers

/// The five pastel colors used across the AirPuff/AirPop bubble design
/// system (see the Figma "Bubble System — Components" section), scoped here
/// to the HUD/panel chrome rather than the gameplay bubbles themselves.
/// AirPop's own signature is lavender ("Pop Lilac"); sky blue stands in for
/// the AirPuff side of the pairing wherever this screen references it.
private enum Brand {
  static let skyBlue = Color(red: Double(0x8C) / 255, green: Double(0xC7) / 255, blue: Double(0xFA) / 255)
  static let lavender = Color(red: Double(0xBF) / 255, green: Double(0xA6) / 255, blue: Double(0xFA) / 255)
  static let mint = Color(red: Double(0x99) / 255, green: Double(0xEA) / 255, blue: Double(0xC7) / 255)
  static let pink = Color(red: Double(0xFF) / 255, green: Double(0xB8) / 255, blue: Double(0xD9) / 255)
  static let peach = Color(red: Double(0xFF) / 255, green: Double(0xD1) / 255, blue: Double(0x99) / 255)
}

struct ContentView: View {
  @StateObject private var tracker = CameraHandTracker()
  @StateObject private var cameraCoordinates = CameraCoordinateMapper()
  @StateObject private var game = GameSession()
  @StateObject private var blowServer = AirPopBonjourServer()
  @State private var showsDiagnostics = false
  @State private var hostAddress: HostAddress.Entry?
  @State private var photoSaveMessage: String?

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
            .font(.caption.bold())
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
            .font(.headline.bold())
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
    GlassPanel {
      VStack(spacing: 18) {
        Text("AIR POP")
          .font(.system(size: 54, weight: .bold, design: .default))
          .foregroundStyle(
            LinearGradient(
              colors: [.white, Brand.lavender],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        Text("바람으로 만들고, 손으로 터뜨리는 버블 게임")
          .font(.title3.weight(.semibold))

        HStack(spacing: 22) {
          roleBadge(
            "A",
            title: "아이폰으로 만들기",
            detail: "마이크에 후 불기",
            tint: Brand.skyBlue
          )
          roleBadge(
            "B",
            title: "손으로 터뜨리기",
            detail: "엄지와 검지 붙이기",
            tint: Brand.lavender
          )
        }

        VStack(alignment: .leading, spacing: 7) {
          readinessRow(
            "B · 손 인식", isReady: game.hasHands,
            detail: game.hasHands ? "\(game.handCount)개" : "카메라에 손을 보여주세요")
          readinessRow(
            "B · 제스처 인식", isReady: game.isModelReady,
            detail: tracker.classifierName)
          readinessRow(
            "A · 아이폰 연결", isReady: game.isPeerConnected,
            detail: blowStatus.label)
          readinessRow(
            "A · 마이크 보정", isReady: game.isPeerMicReady,
            detail: game.isPeerMicReady ? "완료" : "AirPuff에서 보정을 마쳐 주세요")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 16))

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
      }
      .padding(.horizontal, 20)
    }
  }

  private func roleBadge(
    _ letter: String,
    title: String,
    detail: String,
    tint: Color
  ) -> some View {
    VStack(spacing: 5) {
      Text(letter)
        .font(.system(size: 26, weight: .bold, design: .default))
        .foregroundStyle(tint)
        .frame(width: 46, height: 46)
        .background(tint.opacity(0.16), in: Circle())
      Text(title)
        .font(.subheadline.bold())
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(width: 150)
  }

  private func readinessRow(
    _ title: String,
    isReady: Bool,
    detail: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isReady ? .green : .white.opacity(0.35))
      Text(title)
        .font(.subheadline.weight(.semibold))
        .frame(width: 132, alignment: .leading)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
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
          .font(.system(size: 44, weight: .bold, design: .default))
        if game.isNewHighScore {
          Text("NEW BEST")
            .font(.headline.bold())
            .foregroundStyle(Brand.peach)
        }
        Text("\(game.score)")
          .font(.system(size: 76, weight: .bold, design: .default))
          .foregroundStyle(Brand.lavender)

        HStack(spacing: 24) {
          resultStat("버블", value: game.normalPopped, color: Brand.lavender)
          resultStat("폭탄", value: game.bombsTriggered, color: .red)
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
      .font(.caption.bold())
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
        .font(.caption.bold())
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
        .font(.caption.bold())
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
