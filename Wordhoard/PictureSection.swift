import OSLog
import PhotosUI
import SwiftUI
import UIKit
import WordhoardCore

/// The card's picture slot (W1, I2, I4; plan 4.3): the picture, or an "Add picture" row. Tapping either
/// opens the picture actions: Generate picture (only when `canGenerate`), Choose photo…, Take photo…
/// (only with a camera) and Remove picture (only with a picture). Every change goes through
/// `WordCardModel`; the photo is handed over as data.
struct PictureSection: View {
    let model: WordCardModel
    /// Whether the picture generator and the prompt writer both report `.available` (4.4).
    let canGenerate: Bool
    let generate: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var picture: UIImage?
    private let logger = Logger(subsystem: "Wordhoard", category: "images")

    private var fileName: String? {
        model.word.image?.fileName
    }

    var body: some View {
        Section {
            Menu {
                actions
            } label: {
                slot
            }
            .accessibilityHint(Text("Picture actions"))
            .accessibilityIdentifier("wordCard.imageMenu")
            if fileName == nil, let message {
                message
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wordCard.imageMessage")
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            if let item {
                Task {
                    await loadPhoto(item)
                }
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { data in
                model.setImage(data: data, source: .camera)
            }
            .ignoresSafeArea()
        }
        .task(id: fileName) {
            await loadPicture()
        }
    }

    // MARK: - Slot

    @ViewBuilder private var slot: some View {
        if fileName != nil {
            pictureView
        } else if model.word.imageStatus == .pending {
            placeholder
        } else {
            Label("Add picture", systemImage: "photo.badge.plus")
                .accessibilityIdentifier("wordCard.addPicture")
        }
    }

    private var pictureView: some View {
        Color.secondary.opacity(0.15)
            .frame(height: 180)
            .overlay {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement()
            .accessibilityLabel(Text("Word picture"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("wordCard.image")
    }

    /// While the picture is being made (4.4); the menu stays available, so a photo can be picked instead.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 180)
            .overlay {
                ProgressView {
                    Text("Creating a picture…")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wordCard.imagePlaceholder")
    }

    /// One line under "Add picture" for a generation that ended without a picture (I4, I5).
    private var message: Text? {
        switch model.word.imageStatus {
        case .skipped:
            Text("No picture for this word")
        case .refused, .failed:
            Text("Couldn't create a picture")
        case .unavailable:
            Text("Image Playground isn't available on this iPhone")
        case .pending, nil:
            nil
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if canGenerate {
            Button("Generate picture", systemImage: "wand.and.stars", action: generate)
                .accessibilityIdentifier("wordCard.imageGenerate")
        }
        Button("Choose photo…", systemImage: "photo.on.rectangle") {
            isPhotoPickerPresented = true
        }
        .accessibilityIdentifier("wordCard.imageChoosePhoto")
        if CameraPicker.isAvailable {
            Button("Take photo…", systemImage: "camera") {
                isCameraPresented = true
            }
            .accessibilityIdentifier("wordCard.imageTakePhoto")
        }
        if fileName != nil {
            Button("Remove picture", systemImage: "trash", role: .destructive) {
                model.removeImage()
            }
            .accessibilityIdentifier("wordCard.imageRemove")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer {
            photoItem = nil
        }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                model.setImage(data: data, source: .library)
            }
        } catch {
            logger.error("Could not load the chosen photo: \(error.localizedDescription, privacy: .public)")
            model.failure = .savingImage
        }
    }

    /// Decodes the full picture off the main actor; `nil` while there is none.
    private func loadPicture() async {
        guard let url = model.imageURL else {
            picture = nil
            return
        }
        let path = url.path(percentEncoded: false)
        picture = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)?.preparingForDisplay()
        }.value
    }
}
