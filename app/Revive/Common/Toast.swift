import AppModel
import SwiftUI
import UIKit

extension View {
    /// Shows `toast` at the top for 2 s (product-spec.md §0.2 Toast); a new one replaces the old.
    func toast(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .top) {
            if let current = toast.wrappedValue {
                Text(current.text)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(current.id)
                    .task(id: current.id) {
                        UIAccessibility.post(notification: .announcement, argument: current.text)
                        try? await Task.sleep(for: .seconds(2))
                        if toast.wrappedValue?.id == current.id { toast.wrappedValue = nil }
                    }
            }
        }
        .animation(.default, value: toast.wrappedValue?.id)
    }
}

/// System share sheet for a file (product-spec.md P06 export).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
