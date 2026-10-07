import SwiftUI

struct SplashScreenView: View {
    var onFinished: (_ isSecretMode: Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconVisible = false
    @State private var buttonVisible = false
    @State private var hasEntered = false
    @State private var iconTapCount = 0
    @State private var lastIconTap: Date?

    /// Consecutive icon taps required to unlock the secret library.
    private let secretTapCount = 5
    /// Maximum gap between taps for them to count as consecutive.
    private let secretTapInterval: TimeInterval = 0.6

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
                .contentShape(Rectangle())
                .onTapGesture(perform: registerIconTap)
                .accessibilityLabel("MangaShelf")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Button {
                enterLibrary(isSecretMode: false)
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

    private func registerIconTap() {
        guard !hasEntered else { return }
        let now = Date()
        // Restart the sequence if the user paused too long between taps.
        if let lastIconTap, now.timeIntervalSince(lastIconTap) <= secretTapInterval {
            iconTapCount += 1
        } else {
            iconTapCount = 1
        }
        lastIconTap = now

        if iconTapCount >= secretTapCount {
            enterLibrary(isSecretMode: true)
        }
    }

    private func enterLibrary(isSecretMode: Bool) {
        // The secret entry doesn't wait for the Enter button to fade in.
        guard isSecretMode || buttonVisible, !hasEntered else { return }
        hasEntered = true
        if isSecretMode {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        onFinished(isSecretMode)
    }
}

#Preview {
    SplashScreenView()
}
