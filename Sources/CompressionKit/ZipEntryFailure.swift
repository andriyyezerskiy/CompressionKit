//
//  ZipEntryFailure.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 14/11/2026.
//

import Foundation

/// An entry that couldn't be unpacked, such as a damaged, password-protected or Deflate64 file, or one whose name
/// is too long for the disk.
public struct ZipEntryFailure: Sendable {

    // MARK: - Properties
    /// The entry's path in the archive.
    public let path: String
    /// Why it couldn't be unpacked: a `ZipError`, or the file system's error when its file or folder couldn't be made.
    public let error: any Error
}
