// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

enum ProductStyle {
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.67, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.27, green: 0.36, blue: 0.78, alpha: 1)
    }
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    static func symbol(_ name: String, size: CGFloat = 20, color: NSColor = accent) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: size, weight: .medium)
        view.contentTintColor = color
        return view
    }
    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        if !vertical { stack.distribution = .fill }
        return stack
    }
    static func pin(_ view: NSView, in parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

final class SurfaceView: NSView {
    var fill: NSColor = .controlBackgroundColor
    var radius: CGFloat = 14
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Native button semantics with background-only hover, press and keyboard focus states.
final class ProductButton: NSButton {
    enum Kind { case primary, secondary, quiet, navigation }
    var kind: Kind = .secondary
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    var onPress: (() -> Void)?
    private var hovered = false
    private var keyboardFocus = false
    private var windowObservers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?

    init(_ title: String, kind: Kind = .secondary, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.kind = kind
        self.onPress = action
        target = self
        self.action = #selector(invoke)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = .systemFont(ofSize: 13, weight: .medium)
        imagePosition = .imageLeading
        alignment = kind == .navigation ? .left : .center
        setButtonType(.momentaryPushIn)
        (cell as? NSButtonCell)?.highlightsBy = []
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 28, height: 36)
    }
    @objc private func invoke() { onPress?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        keyboardFocus = false
        super.mouseDown(with: event)
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        hovered = false
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.hovered = false
                    self?.needsDisplay = true
                })
            }
        }
    }
    deinit { windowObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func becomeFirstResponder() -> Bool {
        keyboardFocus = NSApp.currentEvent?.type == .keyDown
        let value = super.becomeFirstResponder()
        needsDisplay = true
        return value
    }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); needsDisplay = true; return value }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let focused = keyboardFocus && window?.isKeyWindow == true && window?.firstResponder === self
        let mouseInside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        let active = (hovered && mouseInside && window?.isKeyWindow == true) || focused || isHighlighted
        let background: NSColor
        if kind == .primary {
            background = ProductStyle.accent.withAlphaComponent(isHighlighted ? 0.75 : 1)
            contentTintColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
            }
        } else if selected {
            background = ProductStyle.accent.withAlphaComponent(active ? 0.20 : 0.12)
            contentTintColor = ProductStyle.accent
        } else {
            background = active ? NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07)
                : (kind == .secondary ? NSColor.labelColor.withAlphaComponent(0.05) : .clear)
            contentTintColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
        background.withAlphaComponent(isEnabled ? background.alphaComponent : 0.35 * background.alphaComponent).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if kind == .navigation {
            let tint = selected ? ProductStyle.accent : NSColor.labelColor
            if let image {
                let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium).applying(.init(paletteColors: [tint]))
                let configured = image.withSymbolConfiguration(configuration) ?? image
                let rect = NSRect(x: 14, y: (bounds.height - 18) / 2, width: 18, height: 18)
                configured.draw(in: rect)
            }
            let text = title.trimmingCharacters(in: .whitespaces)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium), .foregroundColor: tint]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: 43, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        } else { super.draw(dirtyRect) }
    }
}

private final class CenteredSearchCell: NSTextFieldCell {
    private func centeredRect(_ rect: NSRect) -> NSRect {
        let font = self.font ?? .systemFont(ofSize: 15)
        let height = min(rect.height, ceil(font.ascender - font.descender + font.leading) + 2)
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredRect(rect) }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredRect(rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centeredRect(rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}

final class SearchField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = CenteredSearchCell(textCell: "")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var onMouseFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onMouseFocus?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); needsDisplay = true; return value }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); needsDisplay = true; return value }

}

/// A compact native-button choice group, without platform focus outlines or bezels.
final class ChoicePicker: NSView {
    private var buttons: [ProductButton] = []
    init(labels: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        let surface = SurfaceView()
        surface.radius = 9
        surface.fill = NSColor.labelColor.withAlphaComponent(0.045)
        ProductStyle.pin(surface, in: self)
        let stack = ProductStyle.stack([], vertical: false, spacing: 2)
        ProductStyle.pin(stack, in: surface, inset: 3)
        for (index, label) in labels.enumerated() {
            let button = ProductButton(label, kind: .quiet)
            button.selected = index == selected
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.onPress = { [weak self] in
                self?.buttons.enumerated().forEach { $0.element.selected = $0.offset == index }
                onChange(index)
            }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
