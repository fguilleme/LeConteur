import SwiftUI

enum ConteurTheme {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.15, green: 0.22, blue: 0.18)
    static let green = Color(red: 0.25, green: 0.37, blue: 0.29)
    static let muted = Color(red: 0.43, green: 0.47, blue: 0.42)
    static let orange = Color(red: 0.77, green: 0.40, blue: 0.25)
    static let wash = Color(red: 0.90, green: 0.92, blue: 0.86)
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
                .fill(LinearGradient(colors: [ConteurTheme.green, ConteurTheme.ink], startPoint: .topLeading, endPoint: .bottomTrailing))
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
