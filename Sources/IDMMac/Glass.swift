import SwiftUI

/// Liquid Glass on macOS 26, frosted material on earlier systems; a flat fill when the user switched
/// the glass look off or asked macOS for less transparency.
private struct MDMGlass: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("glassLook") private var glassLook = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !glassLook || reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke((tint ?? .secondary).opacity(0.2), lineWidth: 1))
        } else {
            glass(content, shape)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, _ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        } else {
            frosted(content, shape)
        }
        #else
        frosted(content, shape)
        #endif
    }

    private func frosted(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder((tint ?? .white).opacity(0.18), lineWidth: 1))
    }
}

extension View {
    /// Cards, panels and rows share this one look.
    func mdmGlass(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(MDMGlass(cornerRadius: cornerRadius, tint: tint))
    }
}
