import AppKit
import SpriteKit
import SwiftUI

struct ContentView: View {
  @StateObject private var tracker = CameraHandTracker()
  @StateObject private var cameraCoordinates = CameraCoordinateMapper()
  @StateObject private var game = GameSession()
  @StateObject private var blowServer = AirPopBonjourServer()

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
    }
    .background(.black)
    .onAppear {
      blowServer.start { strength in
        game.handleBlow(strength: strength)
      }
    }
    .onDisappear {
      blowServer.stop()
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
        .fill(blowServer.connectedDeviceCount > 0 ? Color.green : Color.orange)
        .frame(width: 9, height: 9)
      Text(
        blowServer.connectedDeviceCount > 0
          ? "\(blowServer.connectedDeviceCount) IPHONE CONNECTED"
          : (blowServer.isAdvertising ? "IPHONE 대기 중" : "BONJOUR 시작 중")
      )
      .font(.caption.bold())
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 8)
    .background(.black.opacity(0.52), in: Capsule())
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
