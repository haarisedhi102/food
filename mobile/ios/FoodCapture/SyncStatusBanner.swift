import SwiftUI

/// A compact, non-blocking status banner pinned under the navigation bar. It keeps sync
/// progress visible after the browser sheet is dismissed, then shows the result briefly.
struct SyncStatusBanner: View {
    let stage: String
    let toast: String?
    let toastFailed: Bool

    var body: some View {
        if !stage.isEmpty {
            banner {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Syncing receipts")
                            .font(.subheadline.weight(.semibold))
                        Text(stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Syncing receipts. \(stage)")
            }
        } else if let toast {
            banner {
                HStack(spacing: 10) {
                    Image(systemName: toastFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toastFailed ? Color.orange : Color.green)
                        .accessibilityHidden(true)
                    Text(toast)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func banner(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
