//
//  CRC32.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
//

import Foundation

/// The CRC-32 zip uses to check each file, computed as the file is written.
package struct CRC32 {

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
