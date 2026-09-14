import AppKit
import SwiftUI

@main
struct AirPopApp: App {
    init() {
        Self.registerBundledFonts()
    }

    var body: some Scene {
        Window("AirPop", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }

    /// Google Sans Flex isn't a system font, so it ships in the bundle
    /// (Fonts/GoogleSansFlex.ttf) and has to be registered with Core Text
    /// once at launch -- there's no Info.plist entry for a single loose
    /// font file on macOS the way `UIAppFonts` works on iOS.
    private static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "GoogleSansFlex", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
