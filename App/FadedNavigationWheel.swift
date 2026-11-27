import SwiftUI
import UIKit

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
    @ScaledMetric(relativeTo: .caption) private var itemWidth: CGFloat = 92
    @ScaledMetric(relativeTo: .caption) private var itemHeight: CGFloat = 64
    @State private var centeredPosition: NavigationWheelLoop.Position?

    private var still: Bool { reduceMotion || systemReduceMotion }
    private var itemIDs: [String] { items.map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            stepButton(-1)
            GeometryReader { geometry in
                wheel(viewportWidth: geometry.size.width)
            }
            .frame(height: itemHeight + 12)
            stepButton(1)
        }
        .onAppear { setImmediately(NavigationWheelLoop.center(selectedID, in: itemIDs)) }
        .onChange(of: selectedID) { _, id in center(on: id) }
        .onChange(of: itemIDs) { _, ids in
            let id = centeredPosition.flatMap { ids.contains($0.itemID) ? $0.itemID : nil } ?? selectedID
            setImmediately(NavigationWheelLoop.center(id, in: ids))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fanehjul")
    }

    private func wheel(viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(NavigationWheelLoop.positions(in: itemIDs)) { position in
                    if let item = items.first(where: { $0.id == position.itemID }) {
                        wheelItem(item, position: position, viewportWidth: viewportWidth)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 6)
        }
        .contentMargins(.horizontal, max(0, (viewportWidth - itemWidth) / 2), for: .scrollContent)
        .coordinateSpace(name: "faded-navigation-wheel")
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredPosition, anchor: .center)
        .onScrollPhaseChange { _, phase in
            if phase == .idle,
               let middle = NavigationWheelLoop.recentered(centeredPosition, in: itemIDs),
               middle != centeredPosition {
                setImmediately(middle)
            }
        }
    }

    private func wheelItem(_ item: FadedWheelItem, position: NavigationWheelLoop.Position, viewportWidth: CGFloat) -> some View {
        let motionless = still
        return tab(item, position: position)
            .frame(width: itemWidth, height: itemHeight)
            .visualEffect { content, proxy in
                let halfWidth: CGFloat = max(viewportWidth / 2, 1)
                let distance: CGFloat = proxy.frame(in: .named("faded-navigation-wheel")).midX - viewportWidth / 2
                let position: CGFloat = min(1, max(-1, distance / halfWidth))
                let scale: CGFloat = motionless ? 1 : 1 - abs(position) * 0.04
                let angle: Double = motionless ? 0 : Double(position) * -8
                let offset: CGFloat = motionless ? 0 : abs(position) * 2
                return content
                    .scaleEffect(scale)
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
                    .offset(y: offset)
            }
    }

    private func tab(_ item: FadedWheelItem, position: NavigationWheelLoop.Position) -> some View {
        let selected = item.id == selectedID
        return Button { move(to: position); open(item.id) } label: {
            VStack(spacing: 4) {
                Image(systemName: UIImage(systemName: item.icon) == nil ? "square.grid.2x2.fill" : item.icon)
                    .font(.title3)
                Text(item.title).font(.caption2.bold()).lineLimit(2).multilineTextAlignment(.center)
                Capsule().fill(selected ? FadedBrand.mint : Color.clear).frame(width: 20, height: 3)
            }
            .foregroundStyle(selected ? palette.text : palette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 16).fill(palette.text.opacity(0.07))
                }
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
        guard let next = NavigationWheelLoop.step(from: centeredPosition, by: offset, in: itemIDs) else { return }
        if let current = centeredPosition, abs(next.cycle - current.cycle) > 1 { setImmediately(next) }
        else { move(to: next) }
    }

    private func center(on id: String) {
        guard let next = NavigationWheelLoop.nearest(id, to: centeredPosition, in: itemIDs) else { return }
        move(to: next)
    }

    private func move(to position: NavigationWheelLoop.Position) {
        if still { setImmediately(position) }
        else { withAnimation(.easeInOut(duration: 0.25)) { centeredPosition = position } }
    }

    private func setImmediately(_ position: NavigationWheelLoop.Position?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { centeredPosition = position }
    }
}
