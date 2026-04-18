import SwiftUI

struct UnsplashPanelView: View {
    @ObservedObject var manager: UnsplashManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // API key hint
            if !UnsplashService.shared.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Set Unsplash key in Settings")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
                TextField("Search photos", text: $manager.query, onCommit: {
                    Task { await manager.search() }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                if !manager.query.isEmpty {
                    Button(action: { manager.query = ""; manager.results = [] }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.3), lineWidth: 0.5))

            // Download size picker
            HStack {
                Text("Size")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.75))
                Picker("", selection: $manager.downloadSize) {
                    ForEach(UnsplashDownloadSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Status
            if manager.isSearching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching...")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            if let error = manager.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.1)))
            }

            // Results grid
            if !manager.results.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(manager.results) { photo in
                        UnsplashResultCell(
                            photo: photo,
                            isLoading: manager.downloadingPhotoID == photo.id,
                            onTap: {
                                Task { await manager.addPhotoAsLayer(photo) }
                            }
                        )
                    }
                }
            } else if !manager.isSearching && manager.query.isEmpty {
                // Empty state
                VStack(spacing: 4) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 28))
                        .foregroundColor(Color(white: 0.3))
                    Text("Search Unsplash for stock photos")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            // Attribution footer
            if !manager.results.isEmpty {
                HStack(spacing: 2) {
                    Text("Photos from")
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.5))
                    Button("Unsplash") {
                        if let url = URL(string: "https://unsplash.com/?utm_source=artsy&utm_medium=referral") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Result Cell

struct UnsplashResultCell: View {
    let photo: UnsplashPhoto
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Thumbnail — square container that clips its contents
            Color(white: 0.18)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    AsyncImage(url: URL(string: photo.urls.small)) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().controlSize(.small)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.system(size: 18))
                                .foregroundColor(Color(white: 0.4))
                        @unknown default:
                            EmptyView()
                        }
                    }
                )
                .overlay {
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.5)
                            ProgressView().controlSize(.small).colorInvert()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(white: 0.3), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isLoading else { return }
                    onTap()
                }
                .help("Click to add as layer")

            // Attribution — photographer name (TOS requirement)
            Button(action: {
                let utmURL = "\(photo.user.links.html)?utm_source=artsy&utm_medium=referral"
                if let url = URL(string: utmURL) {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text(photo.user.name)
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help("\(photo.user.name) on Unsplash")
        }
    }
}
