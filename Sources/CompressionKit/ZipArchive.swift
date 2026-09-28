//
//  ZipArchive.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
//
//  Unpacks zip archives, as Bandcamp and most stores deliver albums, with the Compression framework instead of a
//  zip library. Entries are read from the archive's central directory, stored or deflated, with ZIP64 for archives
//  past 4 GB. Each entry streams to disk in chunks and is checked against its CRC, so large lossless albums never sit
//  in memory whole. Encrypted archives and other compression methods aren't supported.
//

import Compression
import Foundation

public enum ZipArchive {

    // MARK: - Properties
    private static let chunkSize: Int = 1 << 20

    // MARK: - Actions
    /// Unpacks every file in `archive` into `destination`, keeping its folders. macOS's `__MACOSX` resource forks
    /// are skipped, and an entry whose path would land outside `destination` is refused.
    public static func extract(_ archive: URL, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }

        let root = destination.standardizedFileURL

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in try entries(in: handle) {
            guard !entry.path.hasPrefix("__MACOSX/") else { continue }

            let url = root.appending(path: entry.path).standardizedFileURL

            guard url.path.hasPrefix(root.path + "/") else {
                throw ZipError.unsafePath(entry.path)
            }

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try extract(entry, from: handle, to: url)
            }
        }
    }

    // MARK: - Helpers
    /// The entries the central directory lists, found through the end-of-directory record at the archive's end.
    private static func entries(in handle: FileHandle) throws -> [Entry] {
        let size = try handle.seekToEnd()
        // The end record is 22 bytes, plus a comment of up to 64 KB.
        let tailStart = size > 65_557 ? size - 65_557 : 0
        let tail = try read(handle, at: tailStart, count: Int(size - tailStart))

        guard let endIndex = tail.lastIndex(ofSignature: 0x0605_4b50, from: tail.count - 22) else {
            throw ZipError.notAnArchive
        }

        var entryCount = UInt64(tail.uint16(at: endIndex + 10))
        var directorySize = UInt64(tail.uint32(at: endIndex + 12))
        var directoryOffset = UInt64(tail.uint32(at: endIndex + 16))

        // ZIP64 keeps the real values in its own end record, pointed to by a locator just before the plain one.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           endIndex >= 20, tail.uint32(at: endIndex - 20) == 0x0706_4b50 {
            let record = try read(handle, at: tail.uint64(at: endIndex - 12), count: 56)

            guard record.uint32(at: 0) == 0x0606_4b50 else { throw ZipError.corrupt }

            entryCount = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }

        let directory = try read(handle, at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        var offset = 0

        for _ in 0..<entryCount {
            guard offset + 46 <= directory.count, directory.uint32(at: offset) == 0x0201_4b50 else { throw ZipError.corrupt }

            let entry = try Entry(directory: directory, at: offset)

            entries.append(entry)
            offset += 46 + entry.headerLength
        }

        return entries
    }

    /// Streams one entry's data from the archive to `url`, inflating it if it's deflated, and checks its CRC.
    private static func extract(_ entry: Entry, from handle: FileHandle, to url: URL) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.method) }

        let header = try read(handle, at: entry.localHeaderOffset, count: 30)

        guard header.uint32(at: 0) == 0x0403_4b50 else { throw ZipError.corrupt }

        let dataStart = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))

        FileManager.default.createFile(atPath: url.path, contents: nil)

        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        var checksum = CRC32()
        var written: UInt64 = 0
        let write: (Data) throws -> Void = { data in
            checksum.update(with: data)
            written += UInt64(data.count)
            try output.write(contentsOf: data)
        }
        var inflater: OutputFilter?

        // Zip's deflate is raw, which is what the Compression framework's zlib algorithm reads.
        if entry.method == 8 {
            inflater = try OutputFilter(.decompress, using: .zlib) { data in
                if let data {
                    try write(data)
                }
            }
        }

        try handle.seek(toOffset: dataStart)

        var remaining = entry.compressedSize

        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(UInt64(chunkSize), remaining))), !chunk.isEmpty else {
                throw ZipError.corrupt
            }

            remaining -= UInt64(chunk.count)

            if let inflater {
                try inflater.write(chunk)
            } else {
                try write(chunk)
            }
        }

        try inflater?.finalize()

        guard written == entry.uncompressedSize, checksum.value == entry.crc else {
            throw ZipError.corrupt
        }
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)

        guard let data = try handle.read(upToCount: count), data.count == count else { throw ZipError.corrupt }

        return data
    }
}

/// One file or folder in the archive, as its central directory record describes it.
private struct Entry {

    // MARK: - Properties
    let path: String
    let method: UInt16
    let crc: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let isEncrypted: Bool
    /// The name, extra field and comment that follow the record's fixed 46 bytes.
    let headerLength: Int

    var isDirectory: Bool { path.hasSuffix("/") }

    // MARK: - Init
    init(directory: Data, at offset: Int) throws {
        let flags = directory.uint16(at: offset + 8)
        let nameLength = Int(directory.uint16(at: offset + 28))
        let extraLength = Int(directory.uint16(at: offset + 30))
        let commentLength = Int(directory.uint16(at: offset + 32))
        let nameStart = offset + 46

        guard nameStart + nameLength + extraLength <= directory.count else { throw ZipError.corrupt }

        let nameData = directory.subdata(in: directory.startIndex + nameStart..<directory.startIndex + nameStart + nameLength)
        var compressedSize = UInt64(directory.uint32(at: offset + 20))
        var uncompressedSize = UInt64(directory.uint32(at: offset + 24))
        var localHeaderOffset = UInt64(directory.uint32(at: offset + 42))

        // ZIP64's extra field holds, in this order, each size or offset too large for its 32-bit place.
        var extraOffset = nameStart + nameLength

        while extraOffset + 4 <= nameStart + nameLength + extraLength {
            let id = directory.uint16(at: extraOffset)
            let length = Int(directory.uint16(at: extraOffset + 2))
            var field = extraOffset + 4

            if id == 0x0001 {
                if uncompressedSize == 0xFFFF_FFFF {
                    uncompressedSize = directory.uint64(at: field)
                    field += 8
                }

                if compressedSize == 0xFFFF_FFFF {
                    compressedSize = directory.uint64(at: field)
                    field += 8
                }

                if localHeaderOffset == 0xFFFF_FFFF {
                    localHeaderOffset = directory.uint64(at: field)
                }
            }

            extraOffset += 4 + length
        }

        // Names are UTF-8 when the archive says so, and usually are anyway; older archives use DOS Latin.
        let dosLatin = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        let name = String(data: nameData, encoding: .utf8) ?? (flags & 0x800 == 0 ? String(data: nameData, encoding: dosLatin) : nil)

        guard let name else { throw ZipError.corrupt }

        path = String(name.replacing("\\", with: "/").trimmingPrefix("/"))
        method = directory.uint16(at: offset + 10)
        crc = directory.uint32(at: offset + 16)
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.localHeaderOffset = localHeaderOffset
        isEncrypted = flags & 0x1 != 0
        headerLength = nameLength + extraLength + commentLength
    }
}

/// The CRC-32 zip uses to check each file, computed as the file is written.
private struct CRC32 {

    // MARK: - Properties
    var value: UInt32 { ~state }

    private var state: UInt32 = 0xFFFF_FFFF

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in
            crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
    }

    // MARK: - Actions
    mutating func update(with data: Data) {
        var crc = state

        data.withUnsafeBytes { bytes in
            Self.table.withUnsafeBufferPointer { table in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }

        state = crc
    }
}

/// Little-endian reads at an offset from the start of the data.
private extension Data {

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }

    /// Where the last record with this signature starts, looking back from `index`.
    func lastIndex(ofSignature signature: UInt32, from index: Int) -> Int? {
        stride(from: index, through: 0, by: -1).first { uint32(at: $0) == signature }
    }
}

public enum ZipError: LocalizedError {
    case notAnArchive
    case corrupt
    case encrypted
    case unsupportedMethod(UInt16)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: "This file isn't a zip archive."
        case .corrupt: "This zip archive is damaged."
        case .encrypted: "This zip archive is password-protected."
        case .unsupportedMethod: "This zip archive is compressed in a way craete can't unpack."
        case .unsafePath(let path): "This zip archive holds a file that would unpack outside its folder: \(path)."
        }
    }
}
