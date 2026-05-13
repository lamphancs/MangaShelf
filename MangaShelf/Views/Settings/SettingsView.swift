//
//  SettingsView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/26/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    @State private var rootFolderName: String?
    @State private var isScanning = false
    @State private var scanMessage: String?

    var isSecretMode: Bool = false

    @State private var secretFolderName: String?
    @State private var isScanningSecret = false
    @State private var secretScanMessage: String?

    private enum FolderPickTarget {
        case root, secret
    }
    @State private var isPickingFolder = false
    @State private var folderPickMode: FolderPickTarget = .root

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    themeSection
                    accentSection
                    librarySection
                    if isSecretMode {
                        secretLibrarySection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(theme.libraryBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch folderPickMode {
                case .root: handleFolderSelection(result)
                case .secret: handleSecretFolderSelection(result)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            rootFolderName = UserDefaults.standard.string(forKey: StorageKey.rootFolderName)
            secretFolderName = UserDefaults.standard.string(forKey: StorageKey.secretFolderName)
        }
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THEME")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 12) {
                ForEach(AppTheme.allCases) { appTheme in
                    let isSelected = theme.selectedTheme == appTheme
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(appTheme.libraryBackground)
                            .frame(height: 52)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(appTheme.cardBackground)
                                    .padding(8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? theme.accent : Color.white.opacity(0.15),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )

                        Text(appTheme.displayName)
                            .font(.caption2)
                            .foregroundColor(isSelected ? .white : .secondaryText)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        theme.selectedTheme = appTheme
                    }
                }
            }
            .padding(12)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Accent Section

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCENT COLOR")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .padding(.leading, 4)

            HStack(spacing: 0) {
                ForEach(AccentTheme.allCases) { accent in
                    let isSelected = theme.selectedAccent == accent
                    VStack(spacing: 6) {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                            }

                        Text(accent.displayName)
                            .font(.caption2)
                            .foregroundColor(isSelected ? .white : .secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        theme.selectedAccent = accent
                    }
                }
            }
            .padding(12)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Library Section

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MANGA LIBRARY")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                if let name = rootFolderName {
                    HStack {
                        Text("Current Folder")
                            .foregroundColor(.secondaryText)
                        Spacer()
                        Text(name)
                            .foregroundColor(.white)
                    }
                    .padding(14)

                    Divider().background(Color.white.opacity(0.06))
                }

                Button {
                    folderPickMode = .root
                    isPickingFolder = true
                } label: {
                    Label(
                        rootFolderName == nil ? "Select Manga Folder" : "Change Folder",
                        systemImage: "folder.badge.plus"
                    )
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }

                if rootFolderName != nil {
                    Divider().background(Color.white.opacity(0.06))

                    Button {
                        Task { await rescan() }
                    } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .disabled(isScanning)
                }
            }
            .font(.subheadline)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Select a root folder containing subfolders for each manga series. Each subfolder should contain PDF chapter files.")
                .font(.caption)
                .foregroundColor(.tertiaryText)
                .padding(.horizontal, 4)

            if let message = scanMessage {
                Text(message)
                    .foregroundColor(theme.accent)
                    .font(.subheadline)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Secret Library Section

    private var secretLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SECRET SHELF")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                if let name = secretFolderName {
                    HStack {
                        Text("Secret Folder")
                            .foregroundColor(.secondaryText)
                        Spacer()
                        Text(name)
                            .foregroundColor(.white)
                    }
                    .padding(14)

                    Divider().background(Color.white.opacity(0.06))
                }

                Button {
                    folderPickMode = .secret
                    isPickingFolder = true
                } label: {
                    Label(
                        secretFolderName == nil ? "Select Secret Folder" : "Change Folder",
                        systemImage: "folder.badge.questionmark"
                    )
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }

                if secretFolderName != nil {
                    Divider().background(Color.white.opacity(0.06))

                    Button {
                        Task { await rescanSecret() }
                    } label: {
                        Label("Rescan Secret Library", systemImage: "arrow.clockwise")
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .disabled(isScanningSecret)

                    Divider().background(Color.white.opacity(0.06))

                    Button(role: .destructive) {
                        removeSecretFolder()
                    } label: {
                        Label("Remove Secret Folder", systemImage: "trash")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
            .font(.subheadline)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let message = secretScanMessage {
                Text(message)
                    .foregroundColor(theme.accent)
                    .font(.subheadline)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Private

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        handleFolderResult(
            result,
            bookmarkKey: StorageKey.rootFolderBookmark,
            nameKey: StorageKey.rootFolderName,
            setName: { rootFolderName = $0 },
            setMessage: { scanMessage = $0 },
            scan: { await rescan() }
        )
    }

    private func handleSecretFolderSelection(_ result: Result<[URL], Error>) {
        handleFolderResult(
            result,
            bookmarkKey: StorageKey.secretFolderBookmark,
            nameKey: StorageKey.secretFolderName,
            setName: { secretFolderName = $0 },
            setMessage: { secretScanMessage = $0 },
            scan: { await rescanSecret() }
        )
    }

    private func handleFolderResult(
        _ result: Result<[URL], Error>,
        bookmarkKey: String,
        nameKey: String,
        setName: (String) -> Void,
        setMessage: (String) -> Void,
        scan: @escaping () async -> Void
    ) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

                UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
                UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
                setName(url.lastPathComponent)

                Task { await scan() }
            } catch {
                setMessage("Failed to save folder access: \(error.localizedDescription)")
            }

        case .failure(let error):
            setMessage("Error: \(error.localizedDescription)")
        }
    }

    private func removeSecretFolder() {
        UserDefaults.standard.removeObject(forKey: StorageKey.secretFolderBookmark)
        UserDefaults.standard.removeObject(forKey: StorageKey.secretFolderName)
        secretFolderName = nil

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.isSecret == true })
        if let existingBooks = try? modelContext.fetch(descriptor) {
            for book in existingBooks {
                modelContext.delete(book)
            }
        }
        try? modelContext.save()
        secretScanMessage = nil
    }

    private func rescanSecret() async {
        isScanningSecret = true
        secretScanMessage = nil
        defer { isScanningSecret = false }

        do {
            let count = try await ImportService().scanSecretFolder(modelContext: modelContext)
            secretScanMessage = "Found \(count) secret series"
        } catch {
            secretScanMessage = "Scan failed: \(error.localizedDescription)"
        }
    }

    private func rescan() async {
        isScanning = true
        scanMessage = nil
        defer { isScanning = false }

        do {
            let count = try await ImportService().scanRootFolder(modelContext: modelContext)
            scanMessage = "Found \(count) manga series"
        } catch {
            scanMessage = "Scan failed: \(error.localizedDescription)"
        }
    }
}
