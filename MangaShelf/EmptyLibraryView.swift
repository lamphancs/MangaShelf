//
//  EmptyLibraryView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI

struct EmptyLibraryView: View {

    @Environment(ThemeManager.self) private var theme

    let onOpenSettings: () -> Void

    private var isConfigured: Bool {
        UserDefaults.standard.data(forKey: "rootFolderBookmark") != nil
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.1))
                    .frame(width: 140, height: 140)

                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(theme.accent)
            }

            VStack(spacing: 12) {
                Text(isConfigured ? "No Manga Found" : "Your Library is Empty")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text(isConfigured
                     ? "Add manga series folders with PDF chapters\nto your root folder"
                     : "Set up your manga folder in Settings\nto get started")
                    .font(.body)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                UIImpactFeedbackGenerator.impact(.medium)
                onOpenSettings()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.body)
                    Text("Open Settings")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(theme.accent)
                .cornerRadius(12)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyLibraryView(onOpenSettings: {})
        .background(Color.black)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
