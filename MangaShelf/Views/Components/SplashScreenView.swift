import SwiftUI

struct SplashScreenView: View {

    var onFinished: () -> Void = {}

    @State private var iconScale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 20

    // Animation timing. The splash stays on screen until every intro
    // animation has fully played, plus a short readable hold, before
    // handing off to the library.
    private let iconDuration: Double = 0.35
    private let titleDelay: Double = 0.15
    private let titleDuration: Double = 0.3
    private let holdDuration: Double = 0.5

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
            withAnimation(.easeOut(duration: iconDuration)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: titleDuration).delay(titleDelay)) {
                titleOpacity = 1.0
                titleOffset = 0
            }
            // Wait for the full intro animation to complete (the title finishes
            // last, at titleDelay + titleDuration) plus a short hold so the
            // library only appears once the splash has played out entirely.
            let animationDuration = max(iconDuration, titleDelay + titleDuration)
            try? await Task.sleep(for: .seconds(animationDuration + holdDuration))
            onFinished()
        }
    }
}

#Preview {
    SplashScreenView()
}
