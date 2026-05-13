//
//  SortMenuView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI

struct SortMenuView: View {

    @Environment(ThemeManager.self) private var theme
    @Binding var selectedOption: LibrarySortOption

    var body: some View {
        Menu {
            ForEach(LibrarySortOption.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        selectedOption = option
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if selectedOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption)
                Text(selectedOption.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundColor(theme.accent)
        }
    }
}

#Preview {
    @Previewable @State var option = LibrarySortOption.recentlyAdded

    return SortMenuView(selectedOption: $option)
        .padding()
        .background(Color.black)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
