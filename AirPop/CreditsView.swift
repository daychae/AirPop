import SwiftUI

/// Fonts, frameworks, and license text worth acknowledging before AirPop
/// ships anywhere public -- surfaced from a small button on the start
/// screen rather than buried in a menu, since this app mostly lives at an
/// exhibition booth where nobody goes looking for an "About" item.
struct CreditsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var showsFullLicense = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("크레딧")
          .font(.title2.bold())
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          creditSection(title: "폰트") {
            VStack(alignment: .leading, spacing: 6) {
              Text("Google Sans Flex")
                .font(.headline)
              Text("영문 텍스트에 사용. SIL Open Font License 1.1로 배포되는 오픈소스 폰트로, 앱에 번들하여 배포하는 것이 허용됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
              Button(showsFullLicense ? "라이선스 원문 숨기기" : "라이선스 원문 보기") {
                showsFullLicense.toggle()
              }
              .font(.callout)
              .buttonStyle(.link)

              if showsFullLicense {
                ScrollView {
                  Text(Self.googleSansFlexLicenseText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 180)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }

          creditSection(title: "기술") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Self.technologies, id: \.self) { line in
                Text(line)
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
          }

          creditSection(title: "만든 사람") {
            Text("by L & L")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.bottom, 4)
      }
    }
    .padding(24)
    .frame(width: 420, height: 460)
  }

  @ViewBuilder
  private func creditSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      content()
    }
  }

  private static let technologies = [
    "Vision -- 실시간 손동작 추적",
    "Core ML / Create ML -- 직접 학습시킨 핀치 제스처 분류기",
    "SpriteKit -- 버블 렌더링 및 팝 이펙트",
    "AVFoundation -- 카메라 및 마이크 입력",
    "Network.framework (Bonjour) -- 아이폰-맥 실시간 통신",
  ]

  /// Read from the bundled OFL.txt rather than duplicated inline, so the
  /// displayed text can never drift from the license actually shipped
  /// alongside the font file.
  private static let googleSansFlexLicenseText: String = {
    guard
      let url = Bundle.main.url(forResource: "GoogleSansFlex-OFL", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      return "라이선스 파일을 불러오지 못했습니다."
    }
    return text
  }()
}

#Preview {
  CreditsView()
}
