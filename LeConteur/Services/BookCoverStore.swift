import Foundation
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum BookCoverStore {
    static var directory: URL { URL.applicationSupportDirectory.appending(path: "Covers", directoryHint: .isDirectory) }
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// Decode a bounded thumbnail once, during import. Images stay outside library.json,
    /// which is saved frequently as playback advances.
    static func save(_ data: Data, directory: URL = directory) throws -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 80_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 800
              ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = encoded as Data
        let name = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined() + ".jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let url = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return name
    }

    @MainActor static func image(named name: String?) -> UIImage? {
        guard let name, name.range(of: "^[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil else { return nil }
        if let image = cache.object(forKey: name as NSString) { return image }
        guard let image = UIImage(contentsOfFile: directory.appending(path: name).path) else { return nil }
        cache.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}
