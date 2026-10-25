import SwiftUI

enum ConteurTheme {
    static let paper = adaptive(light: (0.97, 0.96, 0.93), dark: (0.07, 0.09, 0.08))
    static let ink = adaptive(light: (0.15, 0.22, 0.18), dark: (0.91, 0.94, 0.91))
    static let green = adaptive(light: (0.25, 0.37, 0.29), dark: (0.27, 0.50, 0.33))
    static let muted = adaptive(light: (0.43, 0.47, 0.42), dark: (0.66, 0.70, 0.66))
    static let orange = adaptive(light: (0.77, 0.40, 0.25), dark: (0.94, 0.55, 0.36))
    static let wash = adaptive(light: (0.90, 0.92, 0.86), dark: (0.13, 0.18, 0.15))
    static let card = adaptive(light: (0.99, 0.99, 0.98), dark: (0.12, 0.14, 0.13))
    static let featured = adaptive(light: (0.92, 0.91, 0.85), dark: (0.16, 0.19, 0.17))
    static let coverDark = Color(red: 0.15, green: 0.22, blue: 0.18)

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let components = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}

struct BookCover: View {
    var title: String
    var coverFileName: String? = nil
    var large = false
    var body: some View {
        Group {
            if let image = BookCoverStore.image(named: coverFileName) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: large ? 122 : 55, height: large ? 170 : 76)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: large ? 12 : 6))
            } else {
                placeholder
            }
        }.accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: large ? 16 : 9)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.37, blue: 0.29), ConteurTheme.coverDark], startPoint: .topLeading, endPoint: .bottomTrailing))
            GeometryReader { proxy in
                Path { path in
                    for i in 0..<7 {
                        let y = proxy.size.height * 0.45 + CGFloat(i) * 7
                        path.move(to: CGPoint(x: -10, y: y))
                        path.addCurve(to: CGPoint(x: proxy.size.width + 10, y: y + 16), control1: CGPoint(x: proxy.size.width * 0.3, y: y - 35), control2: CGPoint(x: proxy.size.width * 0.6, y: y + 45))
                    }
                }.stroke(.white.opacity(0.20), lineWidth: 1)
            }.clipped()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "waveform").font(.system(size: large ? 20 : 12, weight: .light))
                Spacer()
                if large { Text(title).font(.system(size: 19, weight: .medium, design: .serif)).lineLimit(4) }
                Text("LE CONTEUR").font(.system(size: large ? 7 : 5, weight: .semibold)).tracking(large ? 2 : 0.6)
            }.padding(large ? 16 : 8).foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: large ? 122 : 55, height: large ? 170 : 76)
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.12)).frame(width: 2).padding(.leading, 5).padding(.vertical, 5) }
        .accessibilityHidden(true)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(ConteurTheme.muted)
    }
}

struct BookTranslationGauge: View {
    let progress: Double
    let isActive: Bool
    var compact = false

    private var value: Double { min(1, max(0, progress)) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(spacing: 8) {
                Label(isActive ? String(localized: "Traduction en cours") : String(localized: "Traduction en pause"),
                      systemImage: isActive ? "translate" : "pause.circle")
                Spacer(minLength: 8)
                Text("\(Int((value * 100).rounded(.down))) %").monospacedDigit()
            }
            .font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
            .foregroundStyle(ConteurTheme.muted)
            ProgressView(value: value)
                .tint(isActive ? ConteurTheme.green : ConteurTheme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? String(localized: "Traduction en cours") : String(localized: "Traduction en pause"))
        .accessibilityValue(String(format: String(localized: "%lld pour cent"), Int64((value * 100).rounded(.down))))
    }
}
