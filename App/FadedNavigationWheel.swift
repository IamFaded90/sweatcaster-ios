import SwiftUI

struct FadedWheelItem: Identifiable {
    let id: String
    let title: String
    let icon: String
}

/// Scrolling previews destinations. Only a button press changes the active screen.
struct FadedNavigationWheel: View {
    let items: [FadedWheelItem]
    let selectedID: String
    let reduceMotion: Bool
    let open: (String) -> Void
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ScaledMetric(relativeTo: .caption) private var itemWidth: CGFloat = 108
    @ScaledMetric(relativeTo: .caption) private var itemHeight: CGFloat = 64
    @State private var centeredID: String?

    private var still: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geometry in
                wheel(viewportWidth: geometry.size.width)
            }
            .frame(height: itemHeight + 12)
        }
        .onAppear { center(on: selectedID) }
        .onChange(of: selectedID) { _, id in center(on: id) }
        .onChange(of: items.map(\.id)) { _, ids in
            if centeredID == nil || !ids.contains(centeredID ?? "") { center(on: selectedID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fanehjul")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            stepButton(-1)
            Text("Swipe for flere · tryk for at åbne")
                .font(.caption2).foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity)
            stepButton(1)
        }
    }

    private func wheel(viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    wheelItem(item, viewportWidth: viewportWidth)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 6)
        }
        .contentMargins(.horizontal, max(0, (viewportWidth - itemWidth) / 2), for: .scrollContent)
        .coordinateSpace(name: "faded-navigation-wheel")
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredID, anchor: .center)
    }

    private func wheelItem(_ item: FadedWheelItem, viewportWidth: CGFloat) -> some View {
        let motionless = still
        return tab(item)
            .frame(width: itemWidth, height: itemHeight)
            .visualEffect { content, proxy in
                let halfWidth: CGFloat = max(viewportWidth / 2, 1)
                let distance: CGFloat = proxy.frame(in: .named("faded-navigation-wheel")).midX - viewportWidth / 2
                let position: CGFloat = min(1, max(-1, distance / halfWidth))
                let scale: CGFloat = motionless ? 1 : 1 - abs(position) * 0.12
                let angle: Double = motionless ? 0 : Double(position) * -32
                let offset: CGFloat = motionless ? 0 : abs(position) * 9
                return content
                    .scaleEffect(scale)
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
                    .offset(y: offset)
            }
    }

    private func tab(_ item: FadedWheelItem) -> some View {
        let selected = item.id == selectedID
        return Button { center(on: item.id); open(item.id) } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon).font(.title3)
                Text(item.title).font(.caption2.bold()).lineLimit(2).multilineTextAlignment(.center)
                Capsule().fill(selected ? FadedBrand.mint : Color.clear).frame(width: 20, height: 3)
            }
            .foregroundStyle(selected ? palette.text : palette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected { ChatGlassSurface(radius: 16, colors: [FadedBrand.mint, FadedBrand.blue]) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Åbn " + item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepButton(_ offset: Int) -> some View {
        Button { step(offset) } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.caption.bold()).frame(width: 44, height: 44)
        }
        .accessibilityLabel(offset < 0 ? "Drej til forrige fane" : "Drej til næste fane")
        .disabled(items.count < 2)
    }

    private func step(_ offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == centeredID } ?? 0
        let next = (current + offset + items.count) % items.count
        center(on: items[next].id)
    }

    private func center(on id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        if still { centeredID = id }
        else { withAnimation(.easeInOut(duration: 0.25)) { centeredID = id } }
    }
}
