//
//  Data+Extensions.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
//

import Foundation

/// Little-endian reads at an offset from the start of the data.
package extension Data {

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
