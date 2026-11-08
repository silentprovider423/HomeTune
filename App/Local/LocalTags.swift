import AVFoundation
import UniformTypeIdentifiers

/// Tags einer Audiodatei auf dem iPhone (AVAsset bzw. FLAC-Kommentarblock), Dateiname als Rückfall.
struct LocalTags: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var composer: String?
    var duration: Double = 0
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var bitRate: Int?
    var artwork: Data?
}

/// Liest Metadaten lokal – ohne Server. MP3/M4A/AIFF/WAV über `AVAsset`, FLAC über einen eigenen kleinen
/// Leser für STREAMINFO, VORBIS_COMMENT und PICTURE (so klappt es unabhängig davon, was AVFoundation kann).
enum TagReader {
    /// Endungen, die beim Durchsuchen von Ordnern beachtet werden. Ob iOS die Datei wirklich lesen kann,
    /// entscheidet danach `AVAudioFile` (z. B. Ogg/Opus je nach iOS-Version).
    static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "m4b", "aac", "alac", "wav", "wave",
                                               "aif", "aiff", "aifc", "caf", "ogg", "oga", "opus"]

    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    /// Typen für den Dateien-Dialog und „Öffnen in“.
    static var contentTypes: [UTType] {
        var t: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType("org.xiph.flac") ?? UTType(filenameExtension: "flac") { t.append(flac) }
        return t
    }

    /// Tags + Dauer; nil, wenn iOS die Datei nicht als Audio öffnen kann.
    static func read(_ url: URL) async -> LocalTags? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.processingFormat.sampleRate > 0 else { return nil }
        var t = LocalTags()
        let asbd = file.fileFormat.streamDescription.pointee
        t.duration = Double(file.length) / file.processingFormat.sampleRate
        t.sampleRate = Int(file.fileFormat.sampleRate)
        t.channels = Int(file.fileFormat.channelCount)
        if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel > 0 {
            t.bitDepth = Int(asbd.mBitsPerChannel)
        } else if asbd.mFormatID == kAudioFormatFLAC || asbd.mFormatID == kAudioFormatAppleLossless {
            // Quell-Bittiefe steckt in den Format-Flags (kAppleLosslessFormatFlag_16BitSourceData = 1 …)
            t.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)]
        }
        let ext = url.pathExtension.lowercased()
        if ext == "flac" {
            FLACTags.read(url, into: &t)
        } else {
            await readAsset(url, into: &t)
        }
        let lossless = t.bitDepth != nil
        if !lossless, t.duration > 0, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            t.bitRate = Int((Double(size) * 8 / t.duration / 1000).rounded())
        }
        return t
    }

    // MARK: AVAsset (ID3, iTunes/QuickTime, gemeinsame Schlüssel)

    private static func readAsset(_ url: URL, into t: inout LocalTags) async {
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.metadata)) ?? []
        items += (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            guard let id = item.identifier else { continue }
            let s = try? await item.load(.stringValue)
            func set(_ kp: WritableKeyPath<LocalTags, String?>) {
                if t[keyPath: kp] == nil, let v = clean(s) { t[keyPath: kp] = v }
            }
            switch id {
            case .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName, .quickTimeMetadataTitle:
                set(\.title)
            case .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist, .quickTimeMetadataArtist:
                set(\.artist)
            case .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum, .quickTimeMetadataAlbum:
                set(\.album)
            case .id3MetadataBand, .iTunesMetadataAlbumArtist:
                set(\.albumArtist)
            case .id3MetadataComposer, .iTunesMetadataComposer, .quickTimeMetadataComposer:
                set(\.composer)
            case .id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre:
                if t.genre == nil { t.genre = genre(s) }
            case .id3MetadataTrackNumber:
                if t.track == nil { t.track = firstInt(s) }
            case .id3MetadataPartOfASet:
                if t.discNumber == nil { t.discNumber = firstInt(s) }
            case .iTunesMetadataTrackNumber:
                if t.track == nil { t.track = await packedNumber(item) }
            case .iTunesMetadataDiscNumber:
                if t.discNumber == nil { t.discNumber = await packedNumber(item) }
            case .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataReleaseTime, .iTunesMetadataReleaseDate,
                 .commonIdentifierCreationDate, .quickTimeMetadataYear:
                if t.year == nil { t.year = year(s) }
            case .commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt, .quickTimeMetadataArtwork:
                if t.artwork == nil, let d = try? await item.load(.dataValue), !d.isEmpty { t.artwork = d }
            default:
                break
            }
        }
    }

    /// iTunes `trkn`/`disk`: 8 bzw. 6 Bytes, Nummer als Big-Endian in Byte 2…3.
    private static func packedNumber(_ item: AVMetadataItem) async -> Int? {
        if let d = try? await item.load(.dataValue), d.count >= 4 {
            let b = [UInt8](d)
            let n = Int(b[2]) << 8 | Int(b[3])
            return n > 0 ? n : nil
        }
        if let n = try? await item.load(.numberValue) { return n.intValue > 0 ? n.intValue : nil }
        return firstInt(try? await item.load(.stringValue))
    }

    // MARK: Hilfen (auch für den FLAC-Leser)

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !t.isEmpty else { return nil }
        return t
    }

    /// „3/12“ → 3
    static func firstInt(_ s: String?) -> Int? {
        guard let s = clean(s) else { return nil }
        let digits = s.prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Erste vierstellige Zahl („2021-05-01“, „2021“) als Jahr.
    static func year(_ s: String?) -> Int? {
        guard let s = clean(s), let r = s.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    /// ID3 schreibt Genres manchmal als „(17)“ oder „(17)Rock“ – Zahl entfernen.
    static func genre(_ s: String?) -> String? {
        guard var g = clean(s) else { return nil }
        if let r = g.range(of: #"^\(\d+\)"#, options: .regularExpression) { g.removeSubrange(r) }
        return clean(g)
    }

    /// Dateiname ohne Endung → (Nummer, Titel): „01 - Paper Boats“ → (1, „Paper Boats“), „03. Titel“ → (3, „Titel“).
    static func fromFilename(_ name: String) -> (track: Int?, title: String) {
        let base = (name as NSString).deletingPathExtension
        let pattern = #"^(\d{1,3})\s*(?:[-._)]\s*|\s+)(.+)$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let n = Range(m.range(at: 1), in: base), let t = Range(m.range(at: 2), in: base),
           let title = clean(String(base[t])) {
            return (Int(base[n]), title)
        }
        return (nil, base)
    }
}

/// Minimaler FLAC-Metadatenleser (Format: „fLaC“, danach Blöcke mit 4-Byte-Kopf; Kommentare Little-Endian,
/// Bild-Block Big-Endian). Liest nur den Kopfbereich der Datei, nie die Audiodaten.
enum FLACTags {
    static func read(_ url: URL, into t: inout LocalTags) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), magic == Data("fLaC".utf8) else { return }
        var last = false
        var guardCount = 0
        while !last && guardCount < 64 {
            guardCount += 1
            guard let hdr = try? h.read(upToCount: 4), hdr.count == 4 else { return }
            let b = [UInt8](hdr)
            last = b[0] & 0x80 != 0
            let type = b[0] & 0x7F
            let len = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            switch type {
            case 0, 4, 6:
                guard let d = try? h.read(upToCount: len), d.count == len else { return }
                let bytes = [UInt8](d)
                if type == 0 { streamInfo(bytes, into: &t) }
                else if type == 4 { comments(bytes, into: &t) }
                else if t.artwork == nil || picType(bytes) == 3 { picture(bytes, into: &t) }
            default:
                guard let off = try? h.offset() else { return }
                try? h.seek(toOffset: off + UInt64(len))
            }
        }
    }

    private static func streamInfo(_ b: [UInt8], into t: inout LocalTags) {
        guard b.count >= 18 else { return }
        let rate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        let channels = Int((b[12] >> 1) & 0x7) + 1
        let bps = (Int(b[12] & 1) << 4 | Int(b[13] >> 4)) + 1
        let total = Int(b[13] & 0x0F) << 32 | Int(b[14]) << 24 | Int(b[15]) << 16 | Int(b[16]) << 8 | Int(b[17])
        if rate > 0 {
            t.sampleRate = rate
            if total > 0 { t.duration = Double(total) / Double(rate) }
        }
        t.channels = channels
        t.bitDepth = bps
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func comments(_ b: [UInt8], into t: inout LocalTags) {
        guard let vendor = le32(b, 0), let count = le32(b, 4 + vendor) else { return }
        var i = 8 + vendor
        for _ in 0..<min(count, 1000) {
            guard let len = le32(b, i), i + 4 + len <= b.count else { return }
            let s = String(decoding: b[(i + 4)..<(i + 4 + len)], as: UTF8.self)
            i += 4 + len
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let value = String(s[s.index(after: eq)...])
            switch key {
            case "TITLE": t.title = t.title ?? TagReader.clean(value)
            case "ARTIST": t.artist = t.artist ?? TagReader.clean(value)
            case "ALBUM": t.album = t.album ?? TagReader.clean(value)
            case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": t.albumArtist = t.albumArtist ?? TagReader.clean(value)
            case "TRACKNUMBER": t.track = t.track ?? TagReader.firstInt(value)
            case "DISCNUMBER": t.discNumber = t.discNumber ?? TagReader.firstInt(value)
            case "DATE", "YEAR", "ORIGINALDATE": t.year = t.year ?? TagReader.year(value)
            case "GENRE": t.genre = t.genre ?? TagReader.genre(value)
            case "COMPOSER": t.composer = t.composer ?? TagReader.clean(value)
            default: break
            }
        }
    }

    private static func picType(_ b: [UInt8]) -> Int? { be32(b, 0) }

    private static func picture(_ b: [UInt8], into t: inout LocalTags) {
        guard let mimeLen = be32(b, 4) else { return }
        var i = 8 + mimeLen
        guard let descLen = be32(b, i) else { return }
        i += 4 + descLen + 16
        guard let len = be32(b, i), len > 0, i + 4 + len <= b.count else { return }
        t.artwork = Data(b[(i + 4)..<(i + 4 + len)])
    }
}
