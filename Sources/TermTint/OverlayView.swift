import AppKit

/// The frosted wash, the role emblem, the big name, and the inline editor.
final class OverlayView: NSView, NSTextFieldDelegate {

    var onCommit: ((String) -> Void)?
    var onEndEditing: (() -> Void)?

    private(set) var isEditing = false

    private let effect = NSVisualEffectView()
    private let wash = NSView()
    private let titleBar = NSView()
    private let emblem = NSImageView()
    private let pill = NSView()
    private let field = NSTextField()
    private let caption = NSTextField(labelWithString: "")
    private let pencil = NSImageView()

    private var tint = Tint(hue: 0, role: .shell)
    private var role: Role = .shell
    private var captionText = ""
    private var isHot = false
    private var name = ""
    private var isPlaceholder = true
    /// Areas covered by windows sitting in front of this one, in view coordinates.
    private var occluders: [CGRect] = []
    /// The window's own title bar stays readable — only tinted — so it can
    /// still be grabbed and dragged.
    private var titleBarHeight: CGFloat = 28

    // Rendering symbols and mask images is expensive enough that doing it on
    // every layout pass shows up in CPU and memory. All of it is derived
    // state, so it is cached and only rebuilt when its inputs change.
    private var emblemCache: (role: Role, size: CGFloat, image: NSImage?)?
    private var glyphCache: (role: Role, size: CGFloat, image: NSImage)?
    private var maskCache: (bounds: CGRect, occluders: [CGRect], body: CGRect)?

    private enum Metrics {
        /// Measured off a real Terminal window on macOS 26: the rounding runs
        /// 16 points deep and follows a plain circular arc. Matching it matters
        /// — the overlay used to be the squarer of the two, so a hard little
        /// wedge of colour stuck out past each corner of the window.
        static let corner: CGFloat = 16
        static let pillPaddingX: CGFloat = 26
        static let pillPaddingY: CGFloat = 12
        static let gap: CGFloat = 12
        static let minFont: CGFloat = 26
        static let maxFont: CGFloat = 92
        static let emblemAlpha: CGFloat = 0.085
        static let minEditWidth: CGFloat = 190
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { false }

    // MARK: - Construction

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.corner
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        addSubview(effect)

        wash.wantsLayer = true
        addSubview(wash)

        titleBar.wantsLayer = true
        addSubview(titleBar)

        // Oversized and cropped by the window edge — a watermark, not an icon.
        emblem.imageScaling = .scaleProportionallyUpOrDown
        emblem.alphaValue = Metrics.emblemAlpha
        addSubview(emblem)

        pill.wantsLayer = true
        pill.layer?.cornerCurve = .continuous
        pill.alphaValue = 0
        addSubview(pill)

        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)

        caption.alignment = .center
        addSubview(caption)

        pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        pencil.imageScaling = .scaleProportionallyUpOrDown
        pencil.alphaValue = 0
        addSubview(pencil)
    }

    // MARK: - Content

    func configure(tint: Tint, role: Role, name: String, caption: String, titleBarHeight: CGFloat) {
        self.tint = tint
        self.role = role
        self.titleBarHeight = titleBarHeight

        // Colours and geometry may refresh at any time, but the text must not:
        // a redraw while the field editor is open would overwrite what is
        // being typed.
        if !isEditing {
            self.name = name
            self.isPlaceholder = name.isEmpty
            self.captionText = isPlaceholder ? "Klicken zum Benennen" : caption
        }

        layer?.borderColor = tint.edge.cgColor
        wash.layer?.backgroundColor = tint.wash.cgColor
        titleBar.layer?.backgroundColor = tint.titleBarWash.cgColor
        pill.layer?.backgroundColor = NSColor(white: 0, alpha: 0.20).cgColor
        pencil.contentTintColor = tint.textColor.withAlphaComponent(0.55)
        emblem.contentTintColor = tint.textColor

        field.textColor = tint.textColor
        if !isEditing {
            field.stringValue = isPlaceholder ? "Ohne Namen" : name
            field.alphaValue = isPlaceholder ? 0.45 : 1
        }

        needsLayout = true
    }

    /// Rectangles of windows stacked in front of this one, in view coordinates.
    /// The overlay is cut away there, so it never paints over a window that
    /// is actually on top.
    func setOcclusion(_ rects: [CGRect]) {
        guard rects != occluders else { return }
        occluders = rects
        needsLayout = true
    }

    /// Highlights the name while the pointer is over it, so it reads as clickable.
    func setHot(_ hot: Bool) {
        guard hot != isHot, !isEditing else { return }
        isHot = hot
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            pill.animator().alphaValue = hot ? 1 : 0
            pencil.animator().alphaValue = hot ? 1 : 0
            field.animator().alphaValue = hot ? 1 : (isPlaceholder ? 0.45 : 1)
        }
    }

    /// Pill around the name, in this view's coordinates — the click target.
    var nameHitRect: CGRect { pill.frame }

    /// Room under the caption for the freeze button, which lives in its own
    /// clickable panel — this view never takes clicks.
    private(set) var freezeSlot: CGRect = .zero
    /// Sits left of the freeze button; the pair stays centred together.
    private(set) var markSlot: CGRect = .zero
    static let freezeSize = CGSize(width: 136, height: 30)

    // MARK: - Editing

    /// - Parameter prefill: text to start from. Automatic labels start empty so
    ///   you can type straight away instead of clearing them first.
    func beginEditing(prefill: String) {
        guard !isEditing else { return }
        isEditing = true
        pill.alphaValue = 1
        pencil.alphaValue = 0
        field.alphaValue = 1
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = nil
        field.stringValue = prefill
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        // The cursor goes to the end, nothing is selected: a name you typed
        // yourself stays put so you can add to it. Selecting it all meant the
        // first keystroke wiped the whole thing — which is not what tapping a
        // name you already chose is meant to do.
        field.currentEditor()?.selectedRange = NSRange(location: (prefill as NSString).length, length: 0)
    }

    func commitEditing() {
        guard isEditing else { return }
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        finishEditing()
        onCommit?(value)
    }

    func cancelEditing() {
        guard isEditing else { return }
        finishEditing()
        onEndEditing?()
    }

    private func finishEditing() {
        isEditing = false
        field.isEditable = false
        field.isSelectable = false
        window?.makeFirstResponder(nil)
        isHot = false
        pill.alphaValue = 0
        pencil.alphaValue = 0
    }

    /// The field editor holds the live text while typing.
    private var currentText: String {
        (field.currentEditor()?.string).map { $0 } ?? field.stringValue
    }

    func controlTextDidChange(_ notification: Notification) {
        // Keeps the pill growing with what you type.
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
            return true
        default:
            return false
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // The title bar is left uncovered so the window stays draggable and
        // recognisable; it only gets a colour wash.
        let barHeight = min(titleBarHeight, bounds.height * 0.4)
        let body = CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: max(0, bounds.height - barHeight))
        titleBar.frame = CGRect(x: bounds.minX, y: body.maxY,
                                width: bounds.width, height: barHeight)
        effect.frame = body
        wash.frame = body

        applyMask()

        // Everything is centred in what is actually visible, not in the whole
        // window, so a half-covered window still reads properly.
        let content = Self.largestVisibleRect(in: body, occluders: occluders)
        layoutEmblem(in: content)

        let text = isEditing ? currentText : field.stringValue
        let fontSize = fittedFontSize(for: text, in: content)
        let font = Self.rounded(size: fontSize, weight: .semibold)
        field.font = font

        let captionSize = max(11, min(13, fontSize * 0.17))
        caption.attributedStringValue = captionString(size: captionSize)

        let captionHeight = (captionText.isEmpty || isEditing) ? 0 : ceil(caption.intrinsicContentSize.height)
        let fieldHeight = ceil(font.ascender - font.descender) + 8
        let available = max(80, content.width - 2 * (Metrics.pillPaddingX + 16))

        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 14
        // While editing the field spans the available width so the caret never
        // runs out of room; only the pill tracks the text.
        let fieldWidth = isEditing ? available : min(max(measured, 60), available)
        let pillTextWidth = isEditing ? max(measured, Metrics.minEditWidth) : measured

        // The freeze button only gets room where there is enough of it.
        let showsFreeze = !isEditing && content.height > 190
        let freezeRoom = showsFreeze ? Metrics.gap + 4 + Self.freezeSize.height : 0
        let blockHeight = fieldHeight + (captionHeight > 0 ? Metrics.gap + captionHeight : 0) + freezeRoom
        let blockTop = content.midY + blockHeight / 2

        // The pencil gets its own room on the right instead of sitting on top
        // of the last letter.
        let glyph = max(13, min(20, fontSize * 0.26))
        let glyphRoom = (isHot && !isEditing) ? glyph + 10 : 0

        let pillWidth = min(pillTextWidth + 2 * Metrics.pillPaddingX + glyphRoom, content.width - 24)
        pill.frame = CGRect(x: content.midX - pillWidth / 2,
                            y: blockTop - fieldHeight - Metrics.pillPaddingY,
                            width: pillWidth,
                            height: fieldHeight + 2 * Metrics.pillPaddingY)
        pill.layer?.cornerRadius = min(18, pill.frame.height / 2)

        // Text stays centred in the pill's text area, not in the whole pill.
        let textCentre = pill.frame.midX - glyphRoom / 2
        field.frame = CGRect(x: textCentre - fieldWidth / 2,
                             y: blockTop - fieldHeight,
                             width: fieldWidth,
                             height: fieldHeight)

        pencil.frame = CGRect(x: pill.frame.maxX - glyph - Metrics.pillPaddingX / 2,
                              y: pill.frame.midY - glyph / 2,
                              width: glyph,
                              height: glyph)

        caption.frame = CGRect(x: content.minX + 16,
                               y: field.frame.minY - Metrics.gap - captionHeight,
                               width: max(40, content.width - 32),
                               height: captionHeight)

        let above = captionHeight > 0 ? caption.frame.minY : pill.frame.minY
        guard showsFreeze else {
            freezeSlot = .zero
            markSlot = .zero
            return
        }
        let gap: CGFloat = 8
        let mark = MarkButtonPanel.size
        let pairWidth = mark.width + gap + Self.freezeSize.width
        let left = content.midX - pairWidth / 2
        let bottom = above - Metrics.gap - 4 - Self.freezeSize.height
        markSlot = CGRect(x: left, y: bottom + (Self.freezeSize.height - mark.height) / 2,
                          width: mark.width, height: mark.height)
        freezeSlot = CGRect(x: left + mark.width + gap, y: bottom,
                            width: Self.freezeSize.width, height: Self.freezeSize.height)
    }

    private func layoutEmblem(in content: CGRect) {
        let size = min(content.height * 0.92, content.width * 0.55)
        guard size > 24 else {
            emblem.image = nil
            emblemCache = nil
            return
        }
        // Quantised so small resizes do not re-render the symbol.
        let quantised = (size / 8).rounded() * 8
        if emblemCache?.role != role || emblemCache?.size != quantised {
            emblemCache = (role, quantised, role.symbol(pointSize: quantised, weight: .light))
        }
        emblem.image = emblemCache?.image
        emblem.frame = CGRect(x: content.maxX - size * 0.58,
                              y: content.minY - size * 0.18,
                              width: size,
                              height: size)
    }

    /// Caption with the role glyph inline, so the emblem is never the only cue.
    private func captionString(size: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let color = tint.textColor.withAlphaComponent(0.58)
        let result = NSMutableAttributedString()

        if !isPlaceholder, let glyph = cachedGlyph(size: size, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = glyph
            attachment.bounds = CGRect(x: 0, y: font.descender * 0.7, width: size, height: size)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }

        result.append(NSAttributedString(string: captionText, attributes: [
            .font: font,
            .foregroundColor: color,
        ]))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: paragraph,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    private func cachedGlyph(size: CGFloat, color: NSColor) -> NSImage? {
        let quantised = (size * 2).rounded() / 2
        if let cache = glyphCache, cache.role == role, cache.size == quantised {
            return cache.image
        }
        guard let symbol = role.symbol(pointSize: quantised, weight: .semibold) else { return nil }
        let tinted = symbol.tinted(with: color)
        glyphCache = (role, quantised, tinted)
        return tinted
    }

    /// Scales the name to the visible area, then shrinks it until it fits.
    private func fittedFontSize(for text: String, in content: CGRect) -> CGFloat {
        var size = min(content.width * 0.135, content.height * 0.40)
        size = min(max(size, Metrics.minFont), Metrics.maxFont)
        guard !text.isEmpty else { return size }

        // Text width scales with the point size, so one measurement is enough —
        // no need to step the size down and re-measure each time.
        let reference: CGFloat = 100
        let referenceWidth = (text as NSString)
            .size(withAttributes: [.font: Self.rounded(size: reference, weight: .semibold)])
            .width
        guard referenceWidth > 0 else { return size }

        let limit = max(60, content.width - 2 * (Metrics.pillPaddingX + 16))
        // Deliberate slack: NSTextField adds its own insets, and landing exactly
        // on the limit makes it truncate the last glyph.
        let fitting = (limit / referenceWidth) * reference * 0.94
        return max(14, min(size, fitting))
    }

    // MARK: - Occlusion

    private func applyMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Rebuilding the mask forces the window server to redo the blur shape;
        // only do it when the shape actually changed.
        let signature = (bounds, occluders, effect.frame)
        if let cache = maskCache,
           cache.bounds == signature.0, cache.occluders == signature.1, cache.body == signature.2 {
            return
        }
        maskCache = signature

        // The layer only needs a mask to punch out covering windows; its own
        // corner radius already rounds the edge.
        if occluders.isEmpty {
            layer?.mask = nil
        } else if let cut = Self.maskImage(size: bounds.size,
                                           shape: CGRect(origin: .zero, size: bounds.size),
                                           holes: occluders,
                                           scale: window?.backingScaleFactor ?? 2) {
            let mask = CALayer()
            mask.frame = bounds
            mask.contents = cut
            mask.contentsScale = window?.backingScaleFactor ?? 2
            layer?.mask = mask
        } else {
            layer?.mask = nil
        }

        // The behind-window blur is shaped by the window server, which ignores
        // the layer's corner radius entirely — so the frosted area needs its
        // own rounded mask, always, not just when something covers us. Without
        // it a square sheet of blur sits under the rounded tint and shows at
        // every corner.
        let origin = effect.frame.origin
        let size = effect.frame.size
        guard size.width > 0, size.height > 0 else {
            effect.maskImage = nil
            return
        }
        // The whole overlay's shape, expressed in the blur's own coordinates:
        // its top corners fall outside the image, so only the bottom two round.
        let shapeRect = CGRect(x: -origin.x, y: -origin.y,
                               width: bounds.width, height: bounds.height)
        let corner = Metrics.corner
        let cutouts = occluders.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        _ = corner
        effect.maskImage = Self.nsMaskImage(size: size, shape: shapeRect, holes: cutouts)
    }

    /// The overlay's shape with the covering windows taken out of it.
    ///
    /// Each hole is cleared on its own, never collected into one path filled
    /// by the even-odd rule. Even-odd counts crossings: an area inside the
    /// outline and inside *two* holes came out odd again and was filled back
    /// in — so wherever two windows in front of the hovered one overlapped
    /// each other, the veil reappeared right on top of them. That is the
    /// rectangle that looked as if the overlay had slipped forward.
    private static func draw(shape: CGRect, holes: [CGRect], into ctx: CGContext) {
        let corner = Metrics.corner
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        for rect in holes where rect.width > 0 && rect.height > 0 {
            let radius = min(corner, min(rect.width, rect.height) / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
    }

    private static func nsMaskImage(size: CGSize, shape: CGRect, holes: [CGRect]) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            if let ctx = NSGraphicsContext.current?.cgContext { draw(shape: shape, holes: holes, into: ctx) }
            return true
        }
    }

    private static func maskImage(size: CGSize, shape: CGRect, holes: [CGRect], scale: CGFloat) -> CGImage? {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width >= 1, pixels.height >= 1,
              let ctx = CGContext(data: nil,
                                  width: Int(pixels.width.rounded()),
                                  height: Int(pixels.height.rounded()),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(shape: shape, holes: holes, into: ctx)
        return ctx.makeImage()
    }

    /// Greedily cuts away each covered area, keeping the largest rectangle that
    /// survives. Good enough for the handful of overlaps that ever occur.
    static func largestVisibleRect(in rect: CGRect, occluders: [CGRect]) -> CGRect {
        var result = rect
        for occluder in occluders {
            let overlap = result.intersection(occluder)
            guard !overlap.isNull, overlap.width > 2, overlap.height > 2 else { continue }

            let candidates = [
                CGRect(x: result.minX, y: result.minY,
                       width: max(0, overlap.minX - result.minX), height: result.height),
                CGRect(x: overlap.maxX, y: result.minY,
                       width: max(0, result.maxX - overlap.maxX), height: result.height),
                CGRect(x: result.minX, y: result.minY,
                       width: result.width, height: max(0, overlap.minY - result.minY)),
                CGRect(x: result.minX, y: overlap.maxY,
                       width: result.width, height: max(0, result.maxY - overlap.maxY)),
            ]
            guard let best = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }),
                  best.width > 40, best.height > 30
            else { continue }
            result = best
        }
        return result
    }

    private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

private extension NSImage {
    /// Text attachments ignore `contentTintColor`, so bake the colour in.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
