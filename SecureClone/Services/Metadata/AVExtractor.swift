//
//  AVExtractor.swift
//  SecureClone
//
//  Metadata + thumbnails for anything macOS can open natively:
//  ProRes / H.264 / HEVC in .mov / .mp4 (DJI, Blackmagic, Sony, Canon…),
//  and ProRes-in-MXF where AVFoundation supports it. Reads the timecode
//  track for TC start, so the CSV matches what the camera burned in.
//

import Foundation
import AVFoundation
import CoreMedia
import AppKit

enum AVExtractor {

    struct Result {
        var durationSeconds: Double?
        var fps: String?
        var resolution: String?
        var codec: String?
        var tcStart: String?
        var tcEnd: String?
    }

    static func metadata(fileAt url: URL) async -> Result? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let playable = try? await asset.load(.isReadable), playable else { return nil }

        var r = Result()
        if let d = try? await asset.load(.duration), d.isNumeric {
            r.durationSeconds = CMTimeGetSeconds(d)
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                r.fps = Timecode.fpsString(Double(fps))
            }
            if let size = try? await track.load(.naturalSize), size.width > 0 {
                r.resolution = "\(Int(size.width))x\(Int(size.height))"
            }
            if let fds = try? await track.load(.formatDescriptions), let fd = fds.first {
                r.codec = codecName(CMFormatDescriptionGetMediaSubType(fd))
            }
        }

        // Timecode track → TC start / end.
        if let tcTrack = try? await asset.loadTracks(withMediaType: .timecode).first,
           let tc = readTimecode(asset: asset, track: tcTrack) {
            r.tcStart = Timecode.string(frames: tc.frames, base: tc.base, dropFrame: tc.drop)
            if let d = r.durationSeconds, let fpsStr = r.fps, let fps = Double(fpsStr) {
                let durFrames = Int64((d * fps).rounded())
                r.tcEnd = Timecode.string(frames: tc.frames + durFrames, base: tc.base, dropFrame: tc.drop)
            }
        }
        return r
    }

    /// One frame from ~1 s in (or the middle of a short clip), as JPEG.
    static func thumbnail(fileAt url: URL, maxWidth: CGFloat = 480) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        let dur = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let at = CMTime(seconds: dur > 2 ? 1.0 : max(0, dur / 2), preferredTimescale: 600)
        guard let result = try? await gen.image(at: at) else { return nil }
        return jpeg(result.image)
    }

    static func jpeg(_ cg: CGImage, quality: Double = 0.75) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: - Timecode track

    private static func readTimecode(asset: AVAsset, track: AVAssetTrack) -> (frames: Int64, base: Int, drop: Bool)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        guard let sbuf = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sbuf),
              let fd = CMSampleBufferGetFormatDescription(sbuf) else { return nil }

        var length = 0
        var ptr: UnsafeMutablePointer<CChar>? = nil
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let p = ptr else { return nil }

        let subtype = CMFormatDescriptionGetMediaSubType(fd)
        var frames: Int64
        if subtype == kCMTimeCodeFormatType_TimeCode64, length >= 8 {
            frames = p.withMemoryRebound(to: Int64.self, capacity: 1) { Int64(bigEndian: $0.pointee) }
        } else if length >= 4 {
            frames = p.withMemoryRebound(to: Int32.self, capacity: 1) { Int64(Int32(bigEndian: $0.pointee)) }
        } else { return nil }

        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
        // Flags are a raw UInt32 in this SDK; kCMTimeCodeFlag_DropFrame == 1 << 0.
        let flags: UInt32 = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd)
        let dropFrame = (flags & 1) != 0
        guard quanta > 0 else { return nil }
        return (frames, quanta, dropFrame)
    }

    // MARK: - Codec names

    private static func codecName(_ fourcc: FourCharCode) -> String {
        switch fourcc {
        case 0x61706368: return "ProRes 422 HQ"        // apch
        case 0x6170636E: return "ProRes 422"           // apcn
        case 0x61706373: return "ProRes 422 LT"        // apcs
        case 0x6170636F: return "ProRes 422 Proxy"     // apco
        case 0x61703468: return "ProRes 4444"          // ap4h
        case 0x61703478: return "ProRes 4444 XQ"       // ap4x
        case 0x61707277: return "ProRes RAW"           // aprw
        case 0x61707268: return "ProRes RAW HQ"        // aprh
        case 0x61766331, 0x61766333: return "H.264"    // avc1, avc3
        case 0x68766331, 0x68657631: return "HEVC"     // hvc1, hev1
        case 0x6D6A7032: return "JPEG 2000"            // mjp2
        case 0x6A706567: return "Motion JPEG"          // jpeg
        case 0x64766831, 0x64766865: return "DV"       // dvh1, dvhe
        case 0x78643561, 0x78643562: return "XDCAM"    // xd5a, xd5b
        default:
            let c = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((fourcc >> $0) & 0xFF))) }
            return String(c)
        }
    }
}

/// DNG / JPEG / HEIC stills via ImageIO: EXIF plus the embedded preview.
enum StillExtractor {
    static func metadata(fileAt url: URL) -> (resolution: String?, iso: String?, exposure: String?, codec: String?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil, nil) }

        var res: String? = nil
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            res = "\(w)x\(h)"
        }
        var iso: String? = nil, exp: String? = nil
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let v = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { iso = String(v) }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                exp = t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s"
            }
        }
        let codec = url.pathExtension.lowercased() == "dng" ? "DNG (RAW)" : url.pathExtension.uppercased()
        return (res, iso, exp, codec)
    }

    static func thumbnail(fileAt url: URL, maxPixel: Int = 480) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return AVExtractor.jpeg(cg)
    }
}
