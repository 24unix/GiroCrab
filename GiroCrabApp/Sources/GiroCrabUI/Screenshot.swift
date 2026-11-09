#if os(macOS)
import AppKit

/// `--screenshot <file.png>`: waits ~120 frames (2 s at 60 Hz), renders the
/// main window (including title bar and toolbar) into a PNG and quits.
public enum WindowScreenshot {
    @MainActor
    public static func scheduleIfRequested(_ options: LaunchOptions = .current) {
        guard let path = options.screenshotPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            capture(to: path, attempt: 0)
        }
    }

    @MainActor
    private static func capture(to path: String, attempt: Int) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let content = window.contentView else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { capture(to: path, attempt: attempt + 1) }
            } else {
                FileHandle.standardError.write("screenshot: no window found\n".data(using: .utf8)!)
                exit(2)
            }
            return
        }
        // With a sheet open (e.g. --demo-sync), capture the sheet instead.
        let target = window.attachedSheet ?? window
        guard let targetContent = target.contentView else { exit(2) }
        let view = targetContent.superview ?? targetContent // frame view = title bar + toolbar + content
        _ = content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(3) }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("screenshot saved: \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            exit(0)
        } catch {
            FileHandle.standardError.write("screenshot: \(error)\n".data(using: .utf8)!)
            exit(5)
        }
    }
}
#endif
