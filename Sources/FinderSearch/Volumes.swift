import AppKit
import Foundation

struct MountedVolume: Equatable, Identifiable, Sendable {
    let url: URL
    let canEject: Bool
    var id: String { url.path }
    var name: String { id == "/" ? "Macintosh HD" : url.lastPathComponent }

    init(url: URL, canEject: Bool) {
        self.url = url
        self.canEject = canEject && url.path != "/"
    }

    static func load() async throws -> [MountedVolume] {
        try await BackgroundWork.run {
            let keys: Set<URLResourceKey> = [
                .volumeIsBrowsableKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                .volumeIsInternalKey,
            ]
            let urls =
                FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
                ?? []
            var mapped = try urls.map { url in
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: keys)
                return MountedVolume(
                    url: url,
                    canEject: values?.volumeIsEjectable == true
                        || values?.volumeIsRemovable == true || values?.volumeIsInternal == false)
            }
            // HOME: SMB and other network shares occasionally miss from the
            // enumeration; anything mounted under /Volumes joins the list.
            if let mounts = try? FileManager.default.contentsOfDirectory(  // HOME
                at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [
                    .isDirectoryKey, .isVolumeKey,
                ])
            {
                let known = Set(mapped.map(\.url.standardizedFileURL.path))
                for mount in mounts where !known.contains(mount.standardizedFileURL.path) {
                    let values = try? mount.resourceValues(forKeys: [.isVolumeKey, .isDirectoryKey])
                    if values?.isVolume == true || values?.isDirectory == true {
                        mapped.append(MountedVolume(url: mount, canEject: true))
                    }
                }
            }
            return mapped
        }
    }

    static func eject(_ url: URL) async throws {
        try await BackgroundWork.run { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
    }
}
