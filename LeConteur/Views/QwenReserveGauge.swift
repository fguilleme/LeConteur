import SwiftUI

struct QwenReserveGauge: View {
    let reserve: QwenReserveProgress
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(showLabel: true)
            line(showLabel: false)
        }
        .font(compact ? .caption2 : .caption.weight(.medium))
        .foregroundStyle(ConteurTheme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Réserve audio")
        .accessibilityValue("\(reserve.amount). \(reserve.status)\(reserve.isAutomatic && !reserve.isComplete ? String(localized: ". Objectif automatique") : "")")
        .accessibilityIdentifier("qwen-reserve-gauge")
    }

    private func line(showLabel: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(ConteurTheme.muted)
            if showLabel { Text(shortStatus).fixedSize() }
            ProgressView(value: reserve.fraction)
                .tint(ConteurTheme.green)
                .frame(minWidth: compact ? 24 : 36, maxWidth: .infinity)
            Text(shortAmount).monospacedDigit().fixedSize()
        }
    }

    private var shortAmount: String {
        if reserve.isComplete { return String(format: String(localized: "%lld s"), Int64(reserve.readySeconds)) }
        let amount = "\(Int(reserve.readySeconds)) / \(Int(ceil(reserve.targetSeconds))) s"
        return reserve.isAutomatic ? amount + " · auto" : amount
    }

    private var shortStatus: String {
        if reserve.isPaused { return String(localized: "En pause") }
        if reserve.hasGenerationError { return String(localized: "À reprendre") }
        if reserve.isComplete { return String(localized: "Prête") }
        if reserve.isGenerationSuspended { return String(localized: "En attente") }
        return reserve.isBuffering || reserve.isGenerating ? String(localized: "Recharge") : String(localized: "Réserve")
    }

    private var statusIcon: String {
        if reserve.isPaused { return "pause.fill" }
        if reserve.hasGenerationError { return "exclamationmark.circle" }
        if reserve.isComplete { return "checkmark.circle" }
        if reserve.isGenerationSuspended { return "pause.circle" }
        return reserve.isBuffering || reserve.isGenerating ? "arrow.triangle.2.circlepath" : "waveform"
    }
}
