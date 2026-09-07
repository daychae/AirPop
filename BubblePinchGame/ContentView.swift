import AppKit
import SpriteKit
import SwiftUI

struct ContentView: View {
  @StateObject private var tracker = CameraHandTracker()
  @StateObject private var cameraCoordinates = CameraCoordinateMapper()
  @StateObject private var game = GameSession()
  @StateObject private var blowServer = AirPopBonjourServer()
  @State private var showsDiagnostics = false
  @State private var hostAddress: HostAddress.Entry?

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
      Button("Toggle diagnostics") {
        showsDiagnostics.toggle()
      }
      .keyboardShortcut("d", modifiers: [])
      .opacity(0)
    }
    .onAppear {
      hostAddress = HostAddress.preferred()
      blowServer.start { strength in
        game.handleBlow(strength: strength)
      }
    }
    .onDisappear {
      blowServer.stop()
    }
    .onChange(of: blowServer.listenerPort) { _, _ in
      hostAddress = HostAddress.preferred()
    }
    .onChange(of: showsDiagnostics) { _, isShown in
      // Interfaces come and go while the app runs, most notably when a USB
      // cable is plugged in, so re-read rather than trusting the launch value.
      if isShown { hostAddress = HostAddress.preferred() }
    }
    .onReceive(tracker.$poses) { poses in
      let viewPoints = Dictionary(
        uniqueKeysWithValues: poses.compactMap { pose in
          cameraCoordinates.viewPoint(
            fromCaptureDevicePoint: pose.pinchPoint
          ).map { (pose.id, $0) }
        })
      game.handleHandPoses(poses, viewPoints: viewPoints)
    }
  }

  private var hud: some View {
    VStack {
      HStack(spacing: 14) {
        hudCard(title: "SCORE", value: "\(game.score)", tint: .cyan)

        Spacer()

        VStack(spacing: 2) {
          Text("TIME")
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.72))
          Text("\(game.timeRemaining)")
            .font(.system(size: 40, weight: .black, design: .rounded))
            .foregroundStyle(game.timeRemaining <= 5 ? .red : .white)
            .contentTransition(.numericText())
        }
        .frame(width: 130)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

        Spacer()

        hudCard(title: "BEST", value: "\(game.highScore)", tint: .purple)
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
            .foregroundStyle(.yellow)
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
          .font(.system(size: 150, weight: .black, design: .rounded))
          .foregroundStyle(.white)
          .shadow(color: .cyan, radius: 22)
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
      case .result:
        resultPanel
      }
    }
  }

  private var startPanel: some View {
    GlassPanel {
      VStack(spacing: 18) {
        Text("AIR POP")
          .font(.system(size: 54, weight: .black, design: .rounded))
          .foregroundStyle(
            LinearGradient(
              colors: [.white, .cyan],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        Text("바람으로 만들고, 손으로 터뜨리는 버블 게임")
          .font(.title3.weight(.semibold))

        Text("엄지와 검지를 붙여 버블을 터뜨리세요\n폭탄은 -3점 · 제한 시간은 30초")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)

        HStack(spacing: 10) {
          Circle()
            .fill(game.hasHands ? Color.green : Color.orange)
            .frame(width: 10, height: 10)
          Text(
            game.hasHands
              ? "\(game.handCount)개의 손 인식 완료"
              : "카메라에 한 손 이상을 보여주세요"
          )
          .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.30), in: Capsule())

        blowStatusPill

        if let hostAddress, blowServer.listenerPort > 0 {
          Text("\(hostAddress.address) : \(String(blowServer.listenerPort))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .textSelection(.enabled)
        }

        Text(
          tracker.isMLReady
            ? "입력 엔진: \(tracker.classifierName) · 최대 4손"
            : tracker.classifierName
        )
        .font(.caption)
        .foregroundStyle(tracker.isMLReady ? .white.opacity(0.64) : .red)

        Button("게임 시작") {
          game.beginCountdown()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.cyan)
        .disabled(!game.hasHands || !tracker.isMLReady)
        .keyboardShortcut(.space, modifiers: [])
      }
      .padding(.horizontal, 20)
    }
  }

  private var permissionPanel: some View {
    GlassPanel {
      VStack(spacing: 18) {
        Image(systemName: "camera.fill")
          .font(.system(size: 50))
          .foregroundStyle(.cyan)
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
          .font(.system(size: 44, weight: .black, design: .rounded))
        if game.isNewHighScore {
          Text("NEW BEST")
            .font(.headline.bold())
            .foregroundStyle(.yellow)
        }
        Text("\(game.score)")
          .font(.system(size: 76, weight: .black, design: .rounded))
          .foregroundStyle(.cyan)

        HStack(spacing: 24) {
          resultStat("버블", value: game.normalPopped, color: .cyan)
          resultStat("폭탄", value: game.bombsTriggered, color: .red)
          resultStat("놓침", value: game.missed, color: .gray)
          resultStat("최고 콤보", value: game.bestCombo, color: .yellow)
        }

        Button("다시 하기") {
          game.returnToReady()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.cyan)
        .keyboardShortcut(.return, modifiers: [])
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
      return "\(blowServer.isLive ? "live" : "idle") · \(name) (\(session))"
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
      format: "%.2f · %@",
      blowServer.latestStrength,
      blowServer.isLive ? "live" : "stale"
    )
  }

  private func hudCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(.white.opacity(0.68))
      Text(value)
        .font(.system(size: 32, weight: .black, design: .rounded))
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
}

private struct GlassPanel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(30)
      .foregroundStyle(.white)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
      .overlay {
        RoundedRectangle(cornerRadius: 28)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
  }
}
