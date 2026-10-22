import SwiftUI

struct ModelListView: View {
    @Binding var models: [PlacedModel]
    @Binding var selectedModelID: UUID?
    let onAdd: () -> Void
    let disabled: Bool
    var onModelsChanged: (() -> Void)? = nil
    var onShowFileSettings: ((UUID) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(models) { model in
                    ModelCell(
                        model: model,
                        isSelected: model.id == selectedModelID,
                        onSelect: { selectedModelID = model.id },
                        onDelete: { removeModel(id: model.id) },
                        onShowFileSettings: { onShowFileSettings?(model.id) }
                    )
                    .disabled(disabled)
                }

                Button(action: onAdd) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.title3)
                        Text("Add")
                            .font(.caption2)
                    }
                    .frame(width: 64, height: 64)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func removeModel(id: UUID) {
        models.removeAll { $0.id == id }
        if selectedModelID == id {
            selectedModelID = models.first?.id
        }
        onModelsChanged?()
    }
}

private struct ModelCell: View {
    let model: PlacedModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onShowFileSettings: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Image(systemName: model.isIntersecting ? "exclamationmark.triangle.fill" : "cube.fill")
                        .font(.title3)
                        .foregroundStyle(model.isIntersecting ? .red : .primary)

                    Text(model.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .foregroundStyle(model.isIntersecting ? Color.red : Color.primary)
                }
                .frame(width: 72, height: 64)
                .background(
                    isSelected ? Color.accentColor.opacity(0.25) : Color(.systemGray6).opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            model.isIntersecting ? Color.red
                                : isSelected ? Color.accentColor
                                : Color.clear,
                            lineWidth: 1.5
                        )
                )

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .background(Color(.systemBackground).opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            .overlay(alignment: .topLeading) {
                if model.fileSettings != nil || model.projectSettings != nil {
                    Button(action: onShowFileSettings) {
                        FileSettingsBadge(model: model)
                            .padding(4)
                            .background(Color(.systemBackground).opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if model.fileSettings != nil || model.projectSettings != nil {
                Button(action: onShowFileSettings) {
                    Label("Settings from File…", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}
