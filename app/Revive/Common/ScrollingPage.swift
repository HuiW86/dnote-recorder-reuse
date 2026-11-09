import SwiftUI
import UIKit

/// Full-screen page with a pinned primary action (P01, P02, P03 done). The content is centred
/// when it fits and scrolls when large accessibility text makes it overflow, instead of being
/// squeezed into "…" (#49).
struct ScrollingPage<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemBackground))
        }
    }
}
