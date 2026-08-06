import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

enum RecordingFormat: String { case mp4, gif }

/// Records a rectangular screen area to MP4 (AVAssetWriter) or GIF (ImageIO),
/// using ScreenCaptureKit cropped via `sourceRect`.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startPTS: CMTime?
    private let queue = DispatchQueue(label: "ai.macfixes.recorder")
    private let ciContext = CIContext()

    private var format: RecordingFormat = .mp4
    private var fps = 30
    private var outputURL: URL!
    private var gifFrames: [CGImage] = []

    private(set) var isRecording = false

    /// Start recording `area` (global top-left coords).
    func start(area: CGRect, format: RecordingFormat, fps: Int, showsCursor: Bool,
               saveDir: URL) async throws {
        self.format = format
        self.fps = fps
        self.gifFrames = []
        self.startPTS = nil

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // Crop rectangle in the display's point space (main display origin = 0,0).
        let sourceRect = CGRect(x: area.minX - CGFloat(display.frame.minX),
                                y: area.minY - CGFloat(display.frame.minY),
                                width: area.width, height: area.height)
        let pxW = Int((area.width * scale).rounded(.down)) & ~1   // even for H.264
        let pxH = Int((area.height * scale).rounded(.down)) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pxW
        config.height = pxH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let name = "Recording \(Self.timestamp()).\(format.rawValue)"
        outputURL = saveDir.appendingPathComponent(name)

        if format == .mp4 { try setupWriter(width: pxW, height: pxH, url: outputURL) }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
    }

    /// Stop and return the saved file URL.
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        try? await stream?.stopCapture()
        stream = nil

        switch format {
        case .mp4:
            input?.markAsFinished()
            await writer?.finishWriting()
            return writer?.status == .completed ? outputURL : nil
        case .gif:
            return await encodeGIF()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, isRecording, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        switch format {
        case .mp4: appendVideo(pixelBuffer, pts: pts)
        case .gif: appendGIFFrame(pixelBuffer)
        }
    }

    // MARK: MP4

    private func setupWriter(width: Int, height: Int, url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        if writer.canAdd(input) { writer.add(input) }
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let writer, let input, let adaptor else { return }
        if startPTS == nil {
            startPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
    }

    // MARK: GIF

    private func appendGIFFrame(_ pixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        // Downscale to <= 800px wide to keep GIF size reasonable.
        let maxW: CGFloat = 800
        let s = min(1, maxW / ci.extent.width)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let cg = ciContext.createCGImage(scaled, from: scaled.extent) {
            gifFrames.append(cg)
        }
    }

    private func encodeGIF() async -> URL? {
        let frames = gifFrames
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return nil }
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        for f in frames { CGImageDestinationAddImage(dest, f, frameProps as CFDictionary) }
        return CGImageDestinationFinalize(dest) ? outputURL : nil
    }

    // MARK: Helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    enum RecorderError: Error { case noDisplay }
}
