//
//  DocxPackage.swift
//  FreeDocx
//

import Foundation
import ZIPFoundation

enum DocxPackageError: LocalizedError {
    case missingPart(String)
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case let .missingPart(path):
            return "The Word document is missing \(path)."
        case .archiveCreationFailed:
            return "FreeDocx could not create a valid Word package."
        }
    }
}

/// Lossless container for a DOCX ZIP package. Every entry is retained with its
/// original order and metadata; serializers explicitly replace only dirty
/// parts. When nothing is dirty, `serializedData()` returns the exact input
/// bytes rather than recompressing the archive.
struct DocxPackage {
    struct Entry {
        let path: String
        let type: ZIPFoundation.Entry.EntryType
        let data: Data
        let modificationDate: Date
        let permissions: UInt16?
        let compressionMethod: CompressionMethod
    }

    private let originalData: Data
    private let entries: [Entry]
    private var replacements: [String: Data] = [:]
    private var additions: [Entry] = []

    init(data: Data) throws {
        let archive = try Archive(data: data, accessMode: .read)
        var loadedEntries: [Entry] = []
        loadedEntries.reserveCapacity(archive.underestimatedCount)

        for archivedEntry in archive {
            var payload = Data()
            _ = try archive.extract(archivedEntry) { payload.append($0) }
            loadedEntries.append(Entry(
                path: archivedEntry.path,
                type: archivedEntry.type,
                data: payload,
                modificationDate: archivedEntry.fileAttributes[.modificationDate] as? Date ?? Date.distantPast,
                permissions: (archivedEntry.fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
                compressionMethod: archivedEntry.type == .file ? .deflate : .none
            ))
        }

        originalData = data
        entries = loadedEntries
    }

    var paths: [String] {
        entries.map(\.path) + additions.map(\.path)
    }

    var isDirty: Bool {
        !replacements.isEmpty || !additions.isEmpty
    }

    func containsPart(named path: String) -> Bool {
        entries.contains(where: { $0.path == path })
            || additions.contains(where: { $0.path == path })
    }

    func part(named path: String) throws -> Data {
        if let replacement = replacements[path] {
            return replacement
        }
        guard let entry = (entries + additions).first(where: { $0.path == path }) else {
            throw DocxPackageError.missingPart(path)
        }
        return entry.data
    }

    mutating func replacePart(named path: String, with data: Data) throws {
        guard containsPart(named: path) else {
            throw DocxPackageError.missingPart(path)
        }
        replacements[path] = data
    }

    mutating func addPart(named path: String, data: Data) throws {
        guard !containsPart(named: path) else {
            try replacePart(named: path, with: data)
            return
        }
        additions.append(Entry(
            path: path,
            type: .file,
            data: data,
            modificationDate: .distantPast,
            permissions: nil,
            compressionMethod: .deflate
        ))
    }

    func serializedData() throws -> Data {
        guard isDirty else { return originalData }

        let destination = try Archive(accessMode: .create)
        for entry in entries + additions {
            let payload = replacements[entry.path] ?? entry.data
            try destination.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(payload.count),
                modificationDate: entry.modificationDate,
                permissions: entry.permissions,
                compressionMethod: entry.compressionMethod
            ) { position, size in
                guard entry.type == .file else { return Data() }
                let start = Int(position)
                let end = min(start + size, payload.count)
                return payload.subdata(in: start..<end)
            }
        }

        guard let result = destination.data else {
            throw DocxPackageError.archiveCreationFailed
        }
        return result
    }
}
