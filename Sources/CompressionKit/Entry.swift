//
//  Entry.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
//

import Foundation

/// One file or folder in the archive, as its central directory record describes it.
package struct Entry {

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
