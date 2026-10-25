import SwiftUI
import UIKit

/// Keep UTF-16 speech ranges in the coordinate system of the displayed paragraph.
struct ReaderParagraphContent {
    let text: String
    let highlight: NSRange?
    let isActive: Bool

    init(segments: [String], start: Int, position: Int, wordRange: NSRange?) {
        text = segments.joined(separator: " ")
        let local = position - start
        isActive = segments.indices.contains(local)
        guard isActive else { highlight = nil; return }
        let sentence = segments[local]
        let range = wordRange ?? sentence.range(of: #"\S+"#, options: .regularExpression).map { NSRange($0, in: sentence) }
        guard let range, range.length > 0, Range(range, in: sentence) != nil else { highlight = nil; return }
        let offset = segments.prefix(local).reduce(0) { $0 + $1.utf16.count + 1 }
        highlight = NSRange(location: offset + range.location, length: range.length)
    }

    var currentWord: String? { highlight.map { (text as NSString).substring(with: $0) } }
}

struct ReaderWordFrame: Equatable {
    let position: Int
    let sourceRange: NSRange?
    let rect: CGRect
}

struct ReaderWordFrameKey: PreferenceKey {
    static var defaultValue: ReaderWordFrame? { nil }
    static func reduce(value: inout ReaderWordFrame?, nextValue: () -> ReaderWordFrame?) {
        if let next = nextValue() { value = next }
    }
}

/// Only scroll when the spoken line leaves a comfortable visible area. A long
/// paragraph can span several screens without ever changing its paragraph ID.
enum ReaderFollowScroll {
    static func visibleTextRect(offset: CGPoint, size: CGSize, insets: EdgeInsets) -> CGRect {
        // The container is the readable size; visibleRect also includes the areas
        // behind the navigation bar/player. Convert its origin into content space.
        CGRect(x: offset.x + insets.leading, y: offset.y + insets.top,
               width: max(0, size.width), height: max(0, size.height))
    }

    static func offset(word: CGRect, visible: CGRect, contentHeight: CGFloat) -> CGFloat? {
        guard visible.height > 0, word.height > 0, word.minY.isFinite else { return nil }
        let margin = min(36, visible.height * 0.15)
        if word.minY >= visible.minY + margin && word.maxY <= visible.maxY - margin { return nil }
        let target = max(0, min(max(0, contentHeight - visible.height), word.midY - visible.height * 0.5))
        return abs(target - visible.minY) > 1 ? target : nil
    }
}

struct ReaderParagraphView: View {
    let content: ReaderParagraphContent
    let position: Int
    let sourceRange: NSRange?
    let textSize: Double
    @State private var frame = CGRect.zero
    @State private var measuredRange: NSRange?
    @State private var wordRect: CGRect?

    private var wordFrame: ReaderWordFrame? {
        guard content.isActive, measuredRange == content.highlight, let wordRect else { return nil }
        return ReaderWordFrame(position: position, sourceRange: sourceRange,
                               rect: wordRect.offsetBy(dx: frame.minX, dy: frame.minY))
    }

    var body: some View {
        ParagraphText(content: content, textSize: textSize) { range, rect in
            measuredRange = range
            wordRect = rect
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("reader-content")) } action: { frame = $0 }
        .preference(key: ReaderWordFrameKey.self, value: wordFrame)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.text)
        .accessibilityValue(content.currentWord.map { String(localized: "Mot en cours : \($0)") } ?? "")
    }
}

private struct ParagraphText: UIViewRepresentable {
    let content: ReaderParagraphContent
    let textSize: Double
    let wordFrame: (NSRange?, CGRect?) -> Void

    func makeUIView(context: Context) -> ReaderParagraphTextView { ReaderParagraphTextView() }

    func updateUIView(_ view: ReaderParagraphTextView, context: Context) {
        view.onWordFrame = wordFrame
        view.configure(content: content, textSize: textSize)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderParagraphTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
}

/// TextKit updates the actual highlighted range and exposes its line rectangle.
/// Changing a word only changes attributes; it never rebuilds the book or resets
/// the scroll view. The enclosing SwiftUI row owns paragraph taps/accessibility.
final class ReaderParagraphTextView: UITextView {
    var onWordFrame: ((NSRange?, CGRect?) -> Void)?
    private var highlightedRange: NSRange?
    private var configuredSize = 0.0
    private var active = false
    private var reporting = false
    private var lastReportedRange: NSRange?
    private var lastReportedRect: CGRect?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = false
        isScrollEnabled = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(content: ReaderParagraphContent, textSize: Double) {
        let color = UIColor(ConteurTheme.ink).withAlphaComponent(content.isActive ? 1 : 0.76)
        let rebuild = text != content.text || configuredSize != textSize || active != content.isActive
        if rebuild {
            let systemDescriptor = UIFont.systemFont(ofSize: textSize).fontDescriptor
            let descriptor = systemDescriptor.withDesign(.serif) ?? systemDescriptor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 9
            attributedText = NSAttributedString(string: content.text, attributes: [
                .font: UIFont(descriptor: descriptor, size: textSize),
                .foregroundColor: color, .paragraphStyle: paragraph
            ])
            configuredSize = textSize
            active = content.isActive
            highlightedRange = nil
        }
        if rebuild || highlightedRange != content.highlight {
            textStorage.beginEditing()
            if let previous = highlightedRange, NSMaxRange(previous) <= textStorage.length {
                textStorage.removeAttribute(.backgroundColor, range: previous)
                textStorage.addAttribute(.foregroundColor, value: color, range: previous)
            }
            if let range = content.highlight {
                textStorage.addAttributes([.backgroundColor: UIColor(ConteurTheme.green), .foregroundColor: UIColor.white], range: range)
            }
            textStorage.endEditing()
            highlightedRange = content.highlight
        }
        scheduleWordFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleWordFrame()
    }

    func currentWordRect() -> CGRect? {
        guard bounds.width > 0, let range = highlightedRange,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return nil }
        let rect = firstRect(for: textRange)
        return rect.isNull || rect.isInfinite || rect.height <= 0 ? nil : rect
    }

    private func scheduleWordFrame() {
        guard !reporting else { return }
        reporting = true
        // Publish after SwiftUI's layout/update transaction, using the latest word.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reporting = false
            let rect = self.currentWordRect()
            guard self.lastReportedRange != self.highlightedRange || self.lastReportedRect != rect else { return }
            self.lastReportedRange = self.highlightedRange
            self.lastReportedRect = rect
            self.onWordFrame?(self.highlightedRange, rect)
        }
    }
}
