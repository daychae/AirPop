import SwiftUI
import UIKit

/// The five pastel colors used across the AirPuff/AirPop bubble design
/// system (see the Figma "Bubble System — Components" section). Fixed hex
/// values, matching the ones used for the gameplay bubbles in AirPop, so the
/// two apps read as one visual language.
private enum BubbleColor {
  static let skyBlue = Color(
    red: Double(0x8C) / 255, green: Double(0xC7) / 255, blue: Double(0xFA) / 255)
  static let lavender = Color(
    red: Double(0xBF) / 255, green: Double(0xA6) / 255, blue: Double(0xFA) / 255)
  static let mint = Color(
    red: Double(0x99) / 255, green: Double(0xEA) / 255, blue: Double(0xC7) / 255)
  static let pink = Color(
    red: Double(0xFF) / 255, green: Double(0xB8) / 255, blue: Double(0xD9) / 255)
  static let peach = Color(
    red: Double(0xFF) / 255, green: Double(0xD1) / 255, blue: Double(0x99) / 255)
}

/// A frosted-glass pastel bubble: radial-gradient fill, soft white rim, and
/// an outer glow/blur, matching the Bubble component spec from Figma.
/// Optionally carries a small white sparkle accent.
private struct FrostedBubble: View {
  let color: Color
  var sparkle = false

  var body: some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.38))
        .blur(radius: 14)
        .scaleEffect(1.08)

      Circle()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.95), color.opacity(0.65), color.opacity(0.32)],
            center: UnitPoint(x: 0.36, y: 0.32),
            startRadius: 0,
            endRadius: 90
          )
        )
        .overlay {
          Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2)
        }

      if sparkle {
        Image(systemName: "sparkle")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(.white)
          .offset(x: 22, y: -24)
      }
    }
  }
}

struct BlowMeterView: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var detector = BlowDetector()
  @StateObject private var connection = AirPopConnection()
  @State private var manualHost = ""
  @State private var manualPort = String(AirPopLink.preferredPort.rawValue)
  @State private var showsManualEntry = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          breathIllustration
          roleCard
          connectionCard
          diagnosticsCard
          statusCard
          meterCard
          measurementGrid
          sensitivityCard
          controls
          usageNote
        }
        .padding()
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("AirPuff")
    }
    .onAppear {
      // Straight from the detection state machine to the transport. Routing
      // this through a published property and .onChange meant nothing was sent
      // until the blow had already finished.
      detector.onEvent = { [connection] type, strength in
        connection.sendBlowEvent(type, strength: strength)
      }
      connection.start()
      detector.requestPermissionAndStart()
    }
    .onChange(of: detector.isReadyForPlay) { _, ready in
      connection.sendStatus(micReady: ready)
    }
    .onChange(of: connection.isConnected) { _, connected in
      // The Mac forgets readiness when a session ends, so re-announce it.
      if connected { connection.sendStatus(micReady: detector.isReadyForPlay) }
    }
    .onDisappear {
      connection.stop()
      detector.stopMonitoring()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        connection.start()
        detector.requestPermissionAndStart()
      } else {
        connection.stop()
        detector.stopMonitoring()
      }
    }
  }

  /// The brand-facing hero moment: a large frosted bubble that swells while
  /// the player blows, surrounded by small pastel support bubbles. Purely
  /// illustrative — the functional meter/diagnostics below are unchanged.
  private var breathIllustration: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("airpuff")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      Text("Take a breath.")
        .font(.system(size: 30, weight: .semibold, design: .rounded))

      Text("Blow gently toward your iPhone.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      ZStack {
        FrostedBubble(color: BubbleColor.skyBlue, sparkle: true)
          .frame(width: heroDiameter, height: heroDiameter)
          .animation(.spring(response: 0.3, dampingFraction: 0.7), value: heroDiameter)

        FrostedBubble(color: BubbleColor.lavender)
          .frame(width: 46, height: 46)
          .offset(x: -66, y: 74)

        FrostedBubble(color: BubbleColor.pink)
          .frame(width: 28, height: 28)
          .offset(x: -84, y: 100)

        FrostedBubble(color: BubbleColor.skyBlue)
          .frame(width: 18, height: 18)
          .offset(x: -98, y: 114)
      }
      .frame(maxWidth: .infinity, minHeight: 230)
      .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  /// Base size plus a boost from the live meter level, so the hero bubble
  /// visibly swells as the blow gets stronger instead of just popping to one
  /// fixed size.
  private var heroDiameter: CGFloat {
    let base: CGFloat = 150
    let boost = CGFloat(detector.meterLevel) * 40
    return detector.isBlowing ? base + boost + 20 : base
  }

  /// The player holding this phone is looking at the Mac screen, so this card
  /// only has to answer two things: what is my job, and what is the game doing
  /// right now.
  private var roleCard: some View {
    HStack(spacing: 14) {
      Text("A")
        .font(.system(size: 30, weight: .black, design: .rounded))
        .foregroundStyle(.orange)
        .frame(width: 54, height: 54)
        .background(.orange.opacity(0.15), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text("불어서 버블 만들기")
          .font(.headline)
        Text("B 플레이어가 Mac 화면에서 손으로 터뜨립니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
    .overlay(alignment: .bottom) {
      if let roundText = roundStateText {
        Text(roundText)
          .font(.caption.bold())
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .background(roundStateTint, in: Capsule())
          .offset(y: 12)
      }
    }
    .padding(.bottom, connection.remotePhase == nil ? 0 : 12)
  }

  private var roundStateText: String? {
    switch connection.remotePhase {
    case .none: return nil
    case .ready: return "Mac에서 시작을 기다리는 중"
    case .countdown:
      return connection.remoteCountdown.map { "곧 시작합니다 · \($0)" }
        ?? "곧 시작합니다"
    case .playing: return "진행 중 · 지금 불어 주세요"
    case .pausedHandsLost: return "일시정지 · B의 손을 인식하지 못했습니다"
    case .pausedPeerLost: return "일시정지 · 연결 확인 중"
    case .result: return "라운드 종료"
    }
  }

  private var roundStateTint: Color {
    switch connection.remotePhase {
    case .playing: return .green
    case .countdown: return .cyan
    case .pausedHandsLost, .pausedPeerLost: return .orange
    case .result: return .purple
    default: return .gray
    }
  }

  private var connectionCard: some View {
    HStack(spacing: 12) {
      Image(systemName: connection.isLinkUsable ? "macbook.and.iphone" : "wifi")
        .font(.title2)
        .foregroundStyle(connectionTint)

      VStack(alignment: .leading, spacing: 2) {
        Text(connection.statusTitle)
          .font(.headline)
        Text(connection.statusDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !connection.isConnected {
        Button("다시 검색") {
          connection.restart()
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  /// Exercises the exact send path the blow stream will use, without the
  /// microphone. This separates "the two devices cannot reach each other" from
  /// "the link is fine but detection is slow" before any tuning starts.
  private var diagnosticsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("연결 테스트", systemImage: "waveform.path.ecg")
          .font(.headline)
        Spacer()
        Button("초기화") {
          connection.resetCounters()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text("마이크 권한 없이도 이 카드만으로 연결과 지연을 확인할 수 있습니다.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Button {
          connection.sendPing()
        } label: {
          Label("단발 전송", systemImage: "paperplane.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!connection.isLinkUsable)

        Button {
          if connection.isStreaming {
            connection.stopTestStream()
          } else {
            connection.startTestStream()
          }
        } label: {
          Label(
            connection.isStreaming ? "20Hz 정지" : "20Hz 연속",
            systemImage: connection.isStreaming ? "stop.fill" : "dot.radiowaves.right"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(connection.isStreaming ? .red : .cyan)
        .disabled(!connection.isLinkUsable)
      }

      HStack(spacing: 10) {
        measurementCell(title: "전송", value: "\(connection.sentCount)", unit: "회")
        measurementCell(title: "응답", value: "\(connection.ackCount)", unit: "회")
        measurementCell(title: "폐기", value: "\(connection.droppedCount)", unit: "개")
        measurementCell(title: "불기", value: "\(connection.blowEventCount)", unit: "회")
      }

      HStack(spacing: 10) {
        measurementCell(
          title: "RTT 최근",
          value: rttText(connection.rtt.latest),
          unit: "ms"
        )
        measurementCell(
          title: "중앙값",
          value: rttText(connection.rtt.p50),
          unit: "ms"
        )
        measurementCell(
          title: "최대",
          value: rttText(connection.rtt.maximum),
          unit: "ms"
        )
      }

      DisclosureGroup("직접 연결", isExpanded: $showsManualEntry) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Bonjour 검색이 막힌 네트워크에서 Mac 화면의 주소를 입력합니다.")
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            TextField("192.168.0.10", text: $manualHost)
              .textFieldStyle(.roundedBorder)
              .keyboardType(.numbersAndPunctuation)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)

            TextField("포트", text: $manualPort)
              .textFieldStyle(.roundedBorder)
              .keyboardType(.numberPad)
              .frame(width: 78)
          }

          HStack(spacing: 10) {
            Button("이 주소로 연결") {
              guard let port = UInt16(manualPort) else { return }
              connection.connectManually(host: manualHost, port: port)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manualHost.isEmpty || UInt16(manualPort) == nil)

            if connection.manualTarget != nil {
              Button("자동 검색으로") {
                connection.clearManualTarget()
              }
              .buttonStyle(.bordered)
            }
          }

          if let target = connection.manualTarget {
            Text("직접 연결 대상: \(target)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 8)
      }
      .font(.subheadline.weight(.semibold))
    }
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  private func rttText(_ value: Double) -> String {
    value > 0 ? String(format: "%.1f", value) : "—"
  }

  private var connectionTint: Color {
    switch connection.state {
    case .connected: return .green
    case .unresponsive: return .red
    case .failed: return .red
    default: return .orange
    }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: statusSymbol)
          .font(.title2)
          .foregroundStyle(statusColor)

        VStack(alignment: .leading, spacing: 2) {
          Text(statusTitle)
            .font(.headline)
          Text(detector.statusMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }

      if detector.isCalibrating {
        ProgressView(value: detector.calibrationProgress)
          .tint(.cyan)
      }

      if detector.permissionState == .denied {
        Button("설정에서 마이크 허용") {
          if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  private var meterCard: some View {
    VStack(spacing: 18) {
      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.15), lineWidth: 18)

        Circle()
          .trim(from: 0, to: detector.meterLevel)
          .stroke(
            meterColor,
            style: StrokeStyle(lineWidth: 18, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.12), value: detector.meterLevel)

        Circle()
          .fill(meterColor.opacity(detector.isBlowing ? 0.18 : 0.06))
          .scaleEffect(detector.isBlowing ? 0.88 : 0.72)
          .animation(.spring(response: 0.22), value: detector.isBlowing)

        VStack(spacing: 4) {
          Text(detector.isBlowing ? "후!" : meterStateText)
            .font(.title2.bold())
            .foregroundStyle(meterColor)
          Text("\(detector.currentDecibels, specifier: "%.1f") dBFS")
            .font(.title.monospacedDigit().weight(.semibold))
          Text("강도 \(Int(detector.strength * 100))%")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 230, height: 230)

      Text("하단 마이크에서 10~20cm 떨어져 짧게 ‘후’ 불어 보세요.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 22)
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  private var measurementGrid: some View {
    HStack(spacing: 10) {
      measurementCell(
        title: "주변 소음",
        value: String(format: "%.1f", detector.baselineDecibels),
        unit: "dBFS"
      )
      measurementCell(
        title: "감지 기준",
        value: String(format: "%.1f", detector.thresholdDecibels),
        unit: "dBFS"
      )
      measurementCell(
        title: "감지 횟수",
        value: "\(detector.blowCount)",
        unit: "회"
      )
    }
  }

  private func measurementCell(title: String, value: String, unit: String) -> some View {
    VStack(spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline.monospacedDigit())
      Text(unit)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
  }

  private var sensitivityCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("감지 민감도", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        Text("+\(Int(detector.thresholdMargin)) dB")
          .font(.subheadline.monospacedDigit().weight(.semibold))
      }

      Slider(value: $detector.thresholdMargin, in: 8...24, step: 1)
        .tint(.cyan)

      HStack {
        Text("민감")
        Spacer()
        Text("둔감")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Text("주변 소음보다 이 값만큼 큰 입력을 감지합니다. 일반적인 환경에서는 15dB부터 시작하세요.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
  }

  private var controls: some View {
    HStack {
      Button {
        if detector.isMonitoring {
          detector.stopMonitoring()
        } else {
          detector.requestPermissionAndStart()
        }
      } label: {
        Label(
          detector.isMonitoring ? "측정 정지" : "측정 시작",
          systemImage: detector.isMonitoring ? "stop.fill" : "mic.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(detector.isMonitoring ? .red : .cyan)

      Button("다시 보정") {
        detector.recalibrate()
      }
      .buttonStyle(.bordered)
      .disabled(detector.permissionState != .granted)

      Button {
        detector.resetBlowCount()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
    }
  }

  private var usageNote: some View {
    Label {
      Text("현재 단계는 상대 음량으로 불기를 판정합니다. 박수나 큰 목소리도 감지될 수 있으므로 실제 사용 장소에서 ‘다시 보정’을 눌러 주세요.")
    } icon: {
      Image(systemName: "info.circle")
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .padding(.vertical, 6)
  }

  private var statusTitle: String {
    if detector.isCalibrating {
      return "주변 소음 보정 중"
    }
    if detector.isMonitoring {
      return "실시간 측정 중"
    }
    return switch detector.permissionState {
    case .undetermined: "마이크 권한 확인 중"
    case .granted: "측정 정지됨"
    case .denied: "마이크 권한 필요"
    }
  }

  private var statusSymbol: String {
    if detector.isCalibrating {
      return "waveform.badge.magnifyingglass"
    }
    if detector.isMonitoring {
      return "waveform"
    }
    return detector.permissionState == .denied ? "mic.slash.fill" : "mic.fill"
  }

  private var statusColor: Color {
    if detector.permissionState == .denied {
      return .red
    }
    return detector.isMonitoring ? .green : .orange
  }

  private var meterColor: Color {
    if detector.isBlowing {
      return .cyan
    }
    if detector.currentDecibels >= detector.thresholdDecibels {
      return .orange
    }
    return .blue
  }

  private var meterStateText: String {
    if detector.isCalibrating {
      return "보정 중"
    }
    return detector.isMonitoring ? "대기 중" : "정지"
  }
}

#Preview {
  BlowMeterView()
}
