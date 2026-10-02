import SwiftUI

struct SplashScreenView: View {
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconVisible = false
    @State private var buttonVisible = false
    @State private var hasEntered = false

    private let foreground = Color(red: 0.91, green: 0.87, blue: 0.81)

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Image("SplashIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 190, height: 190)
                // Match the approved preview: black pixels merge into the backdrop.
                .blendMode(.screen)
                .opacity(iconVisible ? 1 : 0)
                .accessibilityLabel("MangaShelf")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Button {
                guard !hasEntered else { return }
                hasEntered = true
                onFinished()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(foreground)
                    .frame(width: 68, height: 44)
                    .background(foreground.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(foreground.opacity(0.19), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enter Library")
            .accessibilityHidden(!buttonVisible)
            .disabled(!buttonVisible || hasEntered)
            .opacity(buttonVisible ? 1 : 0)
            .padding(.trailing, 26)
            .padding(.bottom, 24)
        }
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.5)) {
                iconVisible = true
            }

            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                buttonVisible = true
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
