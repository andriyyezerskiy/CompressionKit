//
//  ZipError.swift
//  CompressionKit
//
//  Created by Andriy Yezerskiy on 28/09/2026.
//

import Foundation

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
