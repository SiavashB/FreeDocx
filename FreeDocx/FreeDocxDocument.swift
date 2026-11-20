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
            if !session.acceptEditorText(attributedText) {
                editRejectionMessage = session.pendingError?.localizedDescription
            }
            if oldValue.string != session.attributedText.string {
                wordCount = Self.countWords(in: session.attributedText.string)
            }
            guard !attributedText.isEqual(to: session.attributedText) else { return }
            isApplyingProjection = true
            attributedText = session.attributedText
            isApplyingProjection = false
        }
    }
    @Published var editRejectionMessage: String?
    private(set) var wordCount: Int
    let pageLayout: DocumentPageLayout

    private let session: DocxDocumentSession
    private var isApplyingProjection = false

    init() {
        FreeDocxLifecycleState.documentDidStartOpening()
        let session = try! DocxDocumentSession()
        self.session = session
        wordCount = Self.countWords(in: session.attributedText.string)
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
            wordCount = Self.countWords(in: session.attributedText.string)
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

    private static func countWords(in text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            let startsOrContinuesWord = !character.isWhitespace && !character.isNewline
            if startsOrContinuesWord && !inWord { count += 1 }
            inWord = startsOrContinuesWord
        }
        return count
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

    func canApplyEditorChanges(
        to editorText: NSAttributedString,
        ranges: [NSRange],
        replacementStrings: [String]?
    ) -> Bool {
        do {
            try session.validateEditorChanges(
                in: editorText,
                ranges: ranges,
                replacementStrings: replacementStrings
            )
            return true
        } catch {
            editRejectionMessage = error.localizedDescription
            return false
        }
    }
}
