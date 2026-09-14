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

    /// Neither Google Sans Flex nor Handjet is a system font, so both ship
    /// in the bundle and have to be registered with Core Text once at
    /// launch -- there's no Info.plist entry for a loose font file on
    /// macOS the way `UIAppFonts` works on iOS.
    private static func registerBundledFonts() {
        for name in ["GoogleSansFlex", "Handjet-Medium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
