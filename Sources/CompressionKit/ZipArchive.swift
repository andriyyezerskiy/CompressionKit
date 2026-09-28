//
//  ZipArchive.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
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
