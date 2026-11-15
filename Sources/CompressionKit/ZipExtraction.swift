//
//  ZipExtraction.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 14/11/2026.
//

import Foundation

/// What unpacking an archive entry by entry gave: the files it could unpack, and the entries it had to skip.
public struct ZipExtraction: Sendable {

    // MARK: - Properties
    /// The files unpacked, in the archive's order. Folders aren't listed.
    public let files: [URL]
    /// The entries that couldn't be unpacked, in the archive's order. None of them leaves a file behind.
    public let failures: [ZipEntryFailure]
}
