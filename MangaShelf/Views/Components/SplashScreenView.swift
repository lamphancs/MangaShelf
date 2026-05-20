import SwiftUI

struct SplashScreenView: View {

    var onFinished: () -> Void = {}

    @State private var iconScale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 20

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.0, green: 0.48, blue: 1.0),
                                Color(red: 0.62, green: 0.32, blue: 0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                VStack(spacing: 8) {
                    Text("MangaShelf")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Loading your library...")
                        .font(.subheadline)
                        .foregroundColor(Color(white: 0.5))
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)
            }
        }
        .task {
            withAnimation(.easeOut(duration: 0.35)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                titleOpacity = 1.0
                titleOffset = 0
            }
            // Library renders from SwiftData immediately; reconciliation runs silently
            // in the background. Splash duration is now purely a UX minimum, not a wait.
            try? await Task.sleep(for: .seconds(0.65))
            onFinished()
        }
    }
}

#Preview {
    SplashScreenView()
}
