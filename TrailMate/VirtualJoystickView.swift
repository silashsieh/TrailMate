import SwiftUI

struct VirtualJoystickView: View {
    let onInput: (Float, Float) -> Void

    @State private var thumbOffset: CGSize = .zero

    private let padRadius: CGFloat = 60
    private let thumbRadius: CGFloat = 20
    private var maxTravel: CGFloat { padRadius - thumbRadius }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)

            Rectangle()
                .fill(.secondary.opacity(0.2))
                .frame(width: 1)
            Rectangle()
                .fill(.secondary.opacity(0.2))
                .frame(height: 1)

            Circle()
                .fill(.primary.opacity(0.5))
                .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                .offset(thumbOffset)
        }
        .frame(width: padRadius * 2, height: padRadius * 2)
        .clipShape(Circle())
        .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx * dx + dy * dy)

                    if distance <= maxTravel {
                        thumbOffset = value.translation
                    } else {
                        let s = maxTravel / distance
                        thumbOffset = CGSize(width: dx * s, height: dy * s)
                    }

                    let nx = Float(thumbOffset.width / maxTravel)
                    let ny = Float(-thumbOffset.height / maxTravel)
                    onInput(nx, ny)
                }
                .onEnded { _ in
                    thumbOffset = .zero
                    onInput(0, 0)
                }
        )
    }
}
