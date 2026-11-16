#if os(macOS)
import SwiftUI
import AppKit

/// The menu bar item of GitHub #546, built on `NSStatusItem` and an own panel
/// instead of SwiftUI's `MenuBarExtra`: that one cannot be closed from code
/// without leaving its icon "pressed", and its window slid away from the menu
/// bar when its content changed height. Here the panel is placed flush under
/// the menu bar and keeps its top edge there.
@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()

    private weak var model: AppModel?
    private var item: NSStatusItem?
    private var label: ResizingHostingView?
    private var panel: PopoverPanel?
    private var monitors: [Any] = []
    private var defaultsObserver: NSObjectProtocol?

    public var isPopoverShown: Bool { panel?.isVisible ?? false }

    /// Starts watching the setting; the item exists exactly while it is on.
    public func start(model: AppModel) {
        guard defaultsObserver == nil else { return }
        self.model = model
        MenuBarActions.model = model
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    private func sync() {
        if MenuBarKeepAlive.isEnabled {
            if item == nil { install() }
        } else if item != nil {
            uninstall()
        }
    }

    // MARK: status item

    private func install() {
        guard let model else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        let label = ResizingHostingView(rootView: AnyView(MenuBarLabel().environment(model)))
        label.onSizeChange = { [weak self] in self?.layoutLabel() }
        button.addSubview(label)
        self.item = item
        self.label = label
        layoutLabel()
        DispatchQueue.main.async { [weak self] in self?.layoutLabel() }
    }

    private func uninstall() {
        hidePopover()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        label = nil
    }

    /// The SwiftUI label sits inside the button; the item is as wide as the label.
    private func layoutLabel() {
        guard let item, let button = item.button, let label else { return }
        let size = label.fittingSize
        item.length = size.width + 10
        label.frame = NSRect(x: 5, y: max(0, (button.bounds.height - size.height) / 2), width: size.width, height: size.height)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            hidePopover()
            shownAtIconPress = nil
            guard let button = item?.button else { return }
            button.highlight(true)
            // synchronous: returns when the menu is closed again
            MenuBarActions.buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            button.highlight(false)
        } else {
            let wasShown = shownAtIconPress ?? isPopoverShown
            shownAtIconPress = nil
            if wasShown {
                hidePopover()
            } else {
                showPopover()
            }
        }
    }

    // MARK: popover

    public func showPopover() {
        guard let model, let item, let button = item.button, let buttonWindow = button.window else { return }
        hidePopover()
        let host = ResizingHostingView(rootView: AnyView(MenuBarPopoverRoot().environment(model)))
        host.onSizeChange = { [weak self] in self?.resizePanel() }
        host.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // the bottom corners
        background.layer?.masksToBounds = true
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let panel = PopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hidePopover() }
        self.panel = panel

        let size = host.fittingSize
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonWindow.frame.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        // flush under the menu bar: the bottom edge of the status item's window
        let top = buttonWindow.frame.minY
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
    }

    public func hidePopover() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        item?.button?.highlight(false)
    }

    /// The content changed height (list, hints): the top edge stays under the menu bar.
    private func resizePanel() {
        guard let panel, let host = panel.contentView?.subviews.first else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Whether the popover was open when the last mouse press landed on the icon.
    /// The monitors below close the popover before the icon's action runs, so the
    /// action must not decide from the then-closed state (it would reopen).
    private var shownAtIconPress: Bool?

    private func isOnIcon(_ point: NSPoint) -> Bool {
        guard let frame = item?.button?.window?.frame else { return false }
        return frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// A click anywhere else closes the popover, as with a menu.
    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.shownAtIconPress = self.isOnIcon(NSEvent.mouseLocation) ? true : nil
                self.hidePopover()
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return event }
                if event.window === panel { return event }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self.shownAtIconPress = self.isOnIcon(point) ? true : nil
                self.hidePopover()
                return event
            }
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Reports a change of its SwiftUI content's size; lets clicks through to what lies under it.
private final class ResizingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }

    /// Inside the status item's button the button takes the click; in the panel the content does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        superview is NSStatusBarButton ? nil : super.hitTest(point)
    }
}

private final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// What the popover needs from the app scene: the text size and look.
struct MenuBarPopoverRoot: View {
    @AppStorage(AppTextSize.defaultsKey) private var textSize: AppTextSize = .standard
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system

    var body: some View {
        MenuBarPopover()
            .appTextSize(textSize.effective)
            .preferredColorScheme(appearance.colorScheme)
    }
}

/// Gives the menu bar item what only a scene can: opening windows and the settings.
struct MenuBarBridge: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            MenuBarController.shared.start(model: model)
            MenuBarActions.openWindowByID = { openWindow(id: $0) }
            MenuBarActions.openSettingsAction = { openSettings() }
        }
    }
}
#endif
