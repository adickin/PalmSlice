import SwiftUI

/// Paint mode controls: what to paint (colour, supports, seam), the tool, mix
/// or enforce / block to paint (or erase), brush size, brush or fill, undo /
/// redo, clear the part, done.
struct PaintToolbar: View {
    @ObservedObject var controller: PaintController
    let palette: ToolPalette
    /// Colour painting needs several tools (or a mix) to choose from.
    var colourAvailable = true
    /// The slice profile's supports are off, so painted enforcers do nothing.
    var supportsOff = false
    let onDone: () -> Void
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Paint", selection: $controller.layer) {
                ForEach(PaintLayer.allCases.filter { colourAvailable || $0 != .colour }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    choice(icon: "eraser", label: "Erase", state: 0)
                    if controller.layer == .colour {
                        ToolChips(tool: Binding(get: { max(controller.tool, 0) }, set: { controller.tool = $0 }), palette: palette)
                            .fixedSize()
                    } else {
                        let seam = controller.layer == .seam
                        choice(icon: "plus.circle.fill", label: seam ? "Seam Here" : "Enforce",
                               state: Int(SLICER_PAINT_ENFORCE))
                        choice(icon: "nosign", label: seam ? "No Seam" : "Block", state: Int(SLICER_PAINT_BLOCK))
                    }
                }
            }
            if controller.layer == .supports && supportsOff {
                Text("Supports are off in the slice profile, so painted supports won't print until you turn them on.")
                    .font(.caption2).foregroundStyle(.orange)
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
            Text("Paint on the model with one finger or the Pencil; drag off the model to turn the view, two fingers to move it, pinch to zoom.")
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

    /// Erase, or an enforce / block state on the support and seam layers.
    private func choice(icon: String, label: String, state: Int) -> some View {
        Button { controller.tool = state } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(state == 0 ? Color.primary : PaintLayer.annotationColour(UInt8(state)).color)
                if state != 0 { Text(label).font(.caption.weight(.semibold)) }
            }
            .padding(5)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(controller.tool == state ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
