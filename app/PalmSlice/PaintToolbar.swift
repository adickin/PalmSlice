import SwiftUI

/// Paint mode controls: the tool or mix to paint (or erase), brush size, brush
/// or fill, undo / redo, clear the part, done.
struct PaintToolbar: View {
    @ObservedObject var controller: PaintController
    let palette: ToolPalette
    let onDone: () -> Void
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { controller.tool = 0 } label: {
                        Image(systemName: "eraser")
                            .padding(5)
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(controller.tool == 0 ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Erase")
                    ToolChips(tool: Binding(get: { max(controller.tool, 0) }, set: { controller.tool = $0 }), palette: palette)
                        .fixedSize()
                }
            }
            Picker("Mode", selection: $controller.mode) {
                ForEach(PaintController.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if controller.mode == .brush {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Slider(value: $controller.radius, in: 0.5...15)
                    Text(String(format: "%.1f mm", controller.radius))
                        .font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    Toggle("Through", isOn: $controller.sphere)
                        .toggleStyle(.button)
                        .font(.caption)
                        .accessibilityHint("Paints everything within the brush, not just the surface facing you")
                }
            }
            HStack(spacing: 14) {
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!controller.canUndo)
                    .accessibilityLabel("Undo")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!controller.canRedo)
                    .accessibilityLabel("Redo")
                Button("Clear Part", role: .destructive) { confirmClear = true }
                    .font(.caption)
                Spacer(minLength: 4)
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            }
            Text("Paint with one finger or the Pencil; two fingers turn the view, pinch to zoom.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog("Clear the painting on this part?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Part", role: .destructive) { controller.clearPart() }
        }
        .alert("Painting", isPresented: Binding(get: { controller.errorMessage != nil },
                                                set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }
}
