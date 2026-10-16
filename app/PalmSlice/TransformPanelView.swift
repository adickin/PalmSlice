import SwiftUI
import UIKit
import simd
import SceneKit

// MARK: - Float text field (string-backed, no auto-reformatting while typing)

struct FloatField: View {
    @Binding var value: Float
    let fmt: String   // printf format string, e.g. "%g" or "%.3g"

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        TextField("", text: $text) { isEditing in
            editing = isEditing
            if isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                }
            } else { commit() }
        }
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
        .onAppear { text = render(value) }
        .onChange(of: value) { v in if !editing { text = render(v) } }
    }

    private func render(_ v: Float) -> String { String(format: fmt, v) }

    private func commit() {
        let s = text.replacingOccurrences(of: ",", with: ".")
        if let v = Float(s) { value = v }
        text = render(value)
    }
}

// MARK: - Transform panel

struct TransformPanelView: View {
    @Binding var transform: ModelTransform
    let meshInfo: STLMeshInfo?
    let bedX: Double
    let bedY: Double
    let bedZ: Double

    @Binding var lockScale: Bool
    /// When true, renders just the sections (no NavigationStack / Form) so the
    /// caller can place them inside its own List — used by the iPad sidebar.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded {
            sections
        } else {
            NavigationStack {
                Form { sections }
                    .navigationTitle("Transform")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                        // Dismiss decimal keyboard
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        moveSection
            // Auto-drop to bed whenever rotation changes. Attached to one section
            // only — on a Group it would be duplicated onto every child.
            .onChange(of: transform.rotationDeg) { _ in
                guard let info = meshInfo else { return }
                let dropped = transform.droppedToBed(meshInfo: info)
                if dropped.positionMM.z != transform.positionMM.z {
                    transform.positionMM.z = dropped.positionMM.z
                }
            }
        rotateSection
        scaleSection

        Section {
            Button("Reset All", role: .destructive) {
                transform = .identity
            }
        }
    }

    // MARK: - Move

    private var moveSection: some View {
        Section("Move (mm)") {
            axisRow(label: "X", color: .red)   { FloatField(value: $transform.positionMM.x, fmt: "%g") }
            axisRow(label: "Y", color: .green) { FloatField(value: $transform.positionMM.y, fmt: "%g") }
            axisRow(label: "Z", color: .blue)  { FloatField(value: $transform.positionMM.z, fmt: "%g") }

            HStack(spacing: 12) {
                rowButton("Center on Bed") {
                    transform.positionMM.x = 0
                    transform.positionMM.y = 0
                }
                rowButton("Drop to Bed") {
                    if let info = meshInfo {
                        transform = transform.droppedToBed(meshInfo: info)
                    } else {
                        transform.positionMM.z = 0
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    // MARK: - Rotate

    private var rotateSection: some View {
        Section("Rotate (°)") {
            rotateRow(label: "X", color: .red,   value: $transform.rotationDeg.x)
            rotateRow(label: "Y", color: .green, value: $transform.rotationDeg.y)
            rotateRow(label: "Z", color: .blue,  value: $transform.rotationDeg.z)

            HStack(spacing: 12) {
                if meshInfo != nil {
                    rowButton("Lay Flat") { layFlat() }
                }
                rowButton("Reset") { transform.rotationDeg = .zero }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    // MARK: - Scale

    private var scaleSection: some View {
        Section("Scale") {
            Toggle("Lock Proportions", isOn: $lockScale)

            scaleRow(label: "X", color: .red,   baseSizeMM: meshInfo?.sizeMMX, binding: scaleXBinding)
            scaleRow(label: "Y", color: .green, baseSizeMM: meshInfo?.sizeMMZ, binding: scaleYBinding)
            scaleRow(label: "Z", color: .blue,  baseSizeMM: meshInfo?.sizeMMY, binding: scaleZBinding)

            HStack(spacing: 12) {
                if meshInfo != nil {
                    rowButton("Fit to Bed") { fitToBed() }
                }
                rowButton("Reset") { transform.scale = SIMD3(1, 1, 1) }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    // MARK: - Scale bindings with lock

    private var scaleXBinding: Binding<Float> {
        Binding(get: { transform.scale.x }) { newVal in
            guard newVal > 0 else { return }
            if lockScale, transform.scale.x > 0 {
                let r = newVal / transform.scale.x
                transform.scale.x = newVal; transform.scale.y *= r; transform.scale.z *= r
            } else { transform.scale.x = newVal }
        }
    }
    private var scaleYBinding: Binding<Float> {
        Binding(get: { transform.scale.y }) { newVal in
            guard newVal > 0 else { return }
            if lockScale, transform.scale.y > 0 {
                let r = newVal / transform.scale.y
                transform.scale.y = newVal; transform.scale.x *= r; transform.scale.z *= r
            } else { transform.scale.y = newVal }
        }
    }
    private var scaleZBinding: Binding<Float> {
        Binding(get: { transform.scale.z }) { newVal in
            guard newVal > 0 else { return }
            if lockScale, transform.scale.z > 0 {
                let r = newVal / transform.scale.z
                transform.scale.z = newVal; transform.scale.x *= r; transform.scale.y *= r
            } else { transform.scale.z = newVal }
        }
    }

    // MARK: - Row helpers

    /// Equal-width, single-line bordered button for the action rows. The label (not the
    /// button) takes the full width so the bordered background stretches with it, and
    /// the text shrinks instead of wrapping in the narrow iPad sidebar.
    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func axisRow<F: View>(label: String, color: Color, @ViewBuilder field: () -> F) -> some View {
        HStack(spacing: 8) {
            axisLabel(label: label, color: color)
            field()
        }
    }

    @ViewBuilder
    private func rotateRow(label: String, color: Color, value: Binding<Float>) -> some View {
        HStack(spacing: 6) {
            axisLabel(label: label, color: color)
            FloatField(value: value, fmt: "%g")
            Text("°").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { value.wrappedValue = normalised(value.wrappedValue - 90) }
                label: { Text("−90°").font(.caption) }
                .buttonStyle(.bordered).controlSize(.mini)
            Button { value.wrappedValue = normalised(value.wrappedValue + 90) }
                label: { Text("+90°").font(.caption) }
                .buttonStyle(.bordered).controlSize(.mini)
        }
    }

    @ViewBuilder
    private func scaleRow(label: String, color: Color, baseSizeMM: Float?, binding: Binding<Float>) -> some View {
        HStack(spacing: 8) {
            axisLabel(label: label, color: color)
            FloatField(value: binding, fmt: "%.3g")
            if let base = baseSizeMM, base > 0 {
                FloatField(value: sizeMMBinding(base: base, scale: binding), fmt: "%.3g")
                    .frame(minWidth: 62)
                Text("mm").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    /// Binding for the size-in-mm field: setting it back-solves the scale factor.
    private func sizeMMBinding(base: Float, scale: Binding<Float>) -> Binding<Float> {
        Binding(
            get: { base * scale.wrappedValue },
            set: { newSizeMM in
                guard newSizeMM > 0 else { return }
                scale.wrappedValue = newSizeMM / base
            }
        )
    }

    @ViewBuilder
    private func axisLabel(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).frame(width: 14, alignment: .leading)
        }
    }

    private func normalised(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < -180 { d += 360 }
        if d >  180 { d -= 360 }
        return d
    }

    // MARK: - Actions

    private func layFlat() {
        guard let info = meshInfo else { return }

        // After -90° X base rotation, STL normal (nx,ny,nz) → SceneKit (nx,nz,-ny).
        // "Most downward" = SceneKit Y most negative = STL nz most negative.
        // Weight by face area so large flat faces win.
        var bestScore: Float = -.infinity
        var bestNormal = SIMD3<Float>(0, 0, -1)

        for face in info.faces {
            let score = -face.normal.z * face.area
            if score > bestScore {
                bestScore = score
                bestNormal = face.normal
            }
        }

        let scNormal = simd_normalize(SIMD3<Float>(bestNormal.x, bestNormal.z, -bestNormal.y))
        let target   = SIMD3<Float>(0, -1, 0)
        let dot      = max(-1, min(1, simd_dot(scNormal, target)))

        let rotQuat: simd_quatf
        if dot > 0.9999 {
            transform.rotationDeg = .zero
            if let info = meshInfo { transform = transform.droppedToBed(meshInfo: info) }
            return
        } else if dot < -0.9999 {
            rotQuat = simd_quaternion(Float.pi, SIMD3<Float>(1, 0, 0))
        } else {
            rotQuat = simd_quaternion(acos(dot), simd_normalize(simd_cross(scNormal, target)))
        }

        let node = SCNNode()
        node.simdOrientation = rotQuat
        transform.rotationDeg = node.simdEulerAngles * (180 / .pi)
        transform = transform.droppedToBed(meshInfo: info)
    }

    private func fitToBed() {
        guard let info = meshInfo, info.sizeMMX > 0, info.sizeMMY > 0 else { return }
        let fit = min(Float(bedX) * 0.9 / info.sizeMMX,
                      Float(bedY) * 0.9 / info.sizeMMY)
        transform.scale = SIMD3(fit, fit, fit)
    }
}

// MARK: - Preview

#Preview {
    TransformPanelView(transform: .constant(ModelTransform()),
                       meshInfo: nil, bedX: 220, bedY: 220, bedZ: 250,
                       lockScale: .constant(true))
}
