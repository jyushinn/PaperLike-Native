import AppKit
import PaperlikeCore
import SwiftUI

enum PaperLikeArtwork {
    @MainActor
    static var applicationIcon: NSImage {
        if let url = Bundle.main.url(forResource: "PaperLikeNativeAboutIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let image = Bundle.main.image(forResource: NSImage.Name("Paperlike-Native")) {
            return image
        }
#if DEBUG
        if let image = NSImage(contentsOf: sourceRoot.appendingPathComponent("Resources/AppIcon/Paperlike-Native-rendered.png")) {
            return image
        }
#endif
        return NSApp.applicationIconImage
    }

    static func statusIcon(named name: String) -> NSImage? {
        if let image = Bundle.main.image(forResource: NSImage.Name(name)) {
            return image
        }
#if DEBUG
        return NSImage(contentsOf: sourceRoot.appendingPathComponent("Resources/MenuBarIcons/\(name).svg"))
#else
        return nil
#endif
    }

#if DEBUG
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
#endif
}

public struct ConnectionStatusIcon: View {
    let presentation: ConnectionPresentation
    let size: CGFloat

    public init(presentation: ConnectionPresentation, size: CGFloat) {
        self.presentation = presentation
        self.size = size
    }

    public var body: some View {
        if let image = PaperLikeArtwork.statusIcon(named: presentation.menuBarIconName)?.copy() as? NSImage {
            // MenuBarExtra extracts NSImage and ignores SwiftUI's frame when sizing its button.
            let _ = image.size = NSSize(width: size, height: size)
            let _ = image.isTemplate = true
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: presentation.symbolName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
