//
//  FreeDocxDocument.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The standard Office Open XML Word document type (`.docx`).
    nonisolated static let wordDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
}

final class FreeDocxDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static let readableContentTypes: [UTType] = [.wordDocument]
    static let writableContentTypes: [UTType] = [.wordDocument]

    @Published var attributedText: NSAttributedString {
        didSet {
            guard !isApplyingProjection else { return }
            session.acceptEditorText(attributedText)
            pendingEditMessage = session.pendingError.map {
                "This edit was rejected and the document can't be saved until it is undone or removed: \($0.localizedDescription)"
            }
            guard !attributedText.isEqual(to: session.attributedText) else { return }
            isApplyingProjection = true
            attributedText = session.attributedText
            isApplyingProjection = false
        }
    }

    /// User-facing description of the last edit the Word model rejected.
    /// Nil while every edit has been applied safely.
    @Published private(set) var pendingEditMessage: String?

    let pageLayout: DocumentPageLayout

    private let session: DocxDocumentSession
    private var isApplyingProjection = false

    init() {
        FreeDocxLifecycleState.documentDidStartOpening()
        let session = try! DocxDocumentSession()
        self.session = session
        attributedText = session.attributedText
        pageLayout = session.pageLayout
    }

    required convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(fileData: data)
    }

    init(fileData data: Data) throws {
        FreeDocxLifecycleState.documentDidStartOpening()
        do {
            let session = try DocxDocumentSession(data: data)
            self.session = session
            attributedText = session.attributedText
            pageLayout = session.pageLayout
        } catch {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: "FreeDocx couldn’t read this Word document."
                ]
            )
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        try serializedData()
    }

    func fileWrapper(
        snapshot: Data,
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    func serializedData() throws -> Data {
        do {
            return try session.serializedData()
        } catch {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: error.localizedDescription
                ]
            )
        }
    }
}
