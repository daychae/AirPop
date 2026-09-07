import SwiftUI
import UIKit

struct BlowMeterView: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var detector = BlowDetector()
  @StateObject private var connection = AirPopConnection()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          connectionCard
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
      connection.start()
      detector.requestPermissionAndStart()
    }
    .onDisappear {
      connection.stop()
      detector.stopMonitoring()
    }
    .onChange(of: detector.completedBlowSequence) { _, _ in
      connection.sendBlow(strength: detector.lastBlowStrength)
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

  private var connectionCard: some View {
    HStack(spacing: 12) {
      Image(systemName: connection.isConnected ? "macbook.and.iphone" : "wifi")
        .font(.title2)
        .foregroundStyle(connection.isConnected ? .green : .orange)

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
