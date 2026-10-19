import RHAPI
import SwiftUI

// The one component library of design/DESIGN.md: Home is built from these, and so are
// the rh.page/1 components at stage 5 (metric = MetricCard, status = StatusRow,
// button with icon = ActionTile). Glass is the system's (docs/decisions/0005).

/// A glass panel with large corners.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// A large number with a short unambiguous caption: "38%", "112 GB free".
struct MetricCard: View {
    let title: String
    let systemImage: String
    /// nil while loading.
    let value: String?
    /// Words after the number, e.g. "free".
    var caption: String?
    /// Why there is no value (pending source, failed read).
    var problem: String?

    var body: some View {
        GlassCard(padding: 14, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                        if let caption {
                            Text(caption).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                } else if let problem {
                    Text("—").font(.system(.title2, design: .monospaced, weight: .semibold))
                    Text(problem).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("00%").font(.system(.title2, design: .monospaced, weight: .semibold)).redacted(reason: .placeholder)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if let value { return [value, caption].compactMap { $0 }.joined(separator: " ") }
        return problem ?? String(localized: "Loading")
    }
}

/// A coloured dot for a status state.
struct StatusDot: View {
    let state: StatusValue.State

    var body: some View {
        Circle()
            .fill(Palette.color(for: state))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// One row: dot, title, subtitle, status label and optional time. Agents, activity, attention.
struct StatusRow: View {
    let title: String
    var subtitle: String?
    var status: StatusValue?
    var systemImage: String?
    var time: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(status.map { Palette.color(for: $0.state) } ?? .secondary)
                    .frame(width: 20)
            } else if let status {
                StatusDot(state: status.state)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let status, let text = status.text {
                    Text(text).font(.footnote.weight(.medium)).foregroundStyle(Palette.color(for: status.state))
                }
                if let time {
                    Text(time, format: .relative(presentation: .named))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A tappable glass tile with an icon: Quick Access, and page buttons at stage 5.
struct ActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(width: 112, height: 96, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

/// An orange counter like "2 pending" in the concept.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.caption.weight(.bold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(.black)
            .background(.orange, in: .capsule)
            .accessibilityLabel(Text("\(count) pending"))
    }
}

/// Section title with an optional counter and a trailing link ("View all").
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let count, count > 0 { CountBadge(count: count) }
            Spacer()
            trailing.font(.subheadline)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}
