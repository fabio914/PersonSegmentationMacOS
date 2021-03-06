//
//  Segmentation.swift.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Foundation
import AVFoundation
import VideoToolbox
import SceneKit
import Vision

protocol SegmentationWorkerDelegate: AnyObject {
    func segmentation(_ worker: SegmentationWorker, didFailWithError: Error)
    func segmentation(_ worker: SegmentationWorker, didUpdateProgress: Double, preview: NSImage, transform: CGAffineTransform)
    func segmentation(_ worker: SegmentationWorker, didFinishWithOutput url: URL)
}

enum SegmentationWorkerError: Error {
    case missingVideoTrack
    case unableToInitializeCompressionSession
    case unableToCreateMetalDevice
    case unableToCreateTextureCache
    case failedToStartReading
    case failedToStartWriting
    case failedToRead
    case readingCancelled
    case inconsistentState
    case missingFrameImageBuffer
    case missingSegmentationResult
    case unableToConvertImageToPixelBuffer
    case encoderFailed(OSStatus)
    case failedToWrite(AVAssetWriter.Status)
}

// FIXME: Memory usage

final class SegmentationWorker {

    enum Accuracy: Int, RawRepresentable {
        case accurate = 0
        case balanced
        case fast

        var personSegmentationQualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .accurate:
                return .accurate
            case .balanced:
                return .balanced
            case .fast:
                return .fast
            }
        }
    }

    weak var delegate: SegmentationWorkerDelegate?
    private let outputURL: URL

    private(set) var isRunning: Bool = false

    private let videoSize: CGSize
    private let videoDuration: Double // seconds
    private let frameDuration: CMTime
    private let videoTransform: CGAffineTransform

    private let inputReader: AVAssetReader
    private let inputVideoReader: AVAssetReaderTrackOutput

    private let outputWriter: AVAssetWriter
    private let outputVideoWriter: AVAssetWriterInput
    private let compressionSession: VTCompressionSession

    private let backgroundImage: NSImage

    private let metalTextureCache: CVMetalTextureCache
    private let scene: SCNScene
    private let framePlaneNode: SCNNode
    private let sceneRenderer: SCNRenderer
    private let personSegmentationQualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel

    init(
        inputURL: URL,
        outputURL: URL,
        accuracy: Accuracy,
        backgroundColor: NSColor
    ) throws {

        // MARK: - Configuring Input:

        let inputAsset = AVAsset(url: inputURL)
        let inputReader = try AVAssetReader(asset: inputAsset)

        guard let videoTrack = inputAsset.tracks(withMediaType: .video).first else {
            throw SegmentationWorkerError.missingVideoTrack
        }

        self.videoDuration = CMTimeGetSeconds(inputAsset.duration)

        // FIXME: We're assuming constant frame-rate, for some reason each frame's CMSampleBuffer duration is always invalid
        self.frameDuration = videoTrack.minFrameDuration

        let videoTransform = videoTrack.preferredTransform
        self.videoTransform = videoTransform

//        let videoRotation = atan2(videoTransform.b, videoTransform.a)

        let videoSize: CGSize = {
//            switch Int(videoRotation * 180.0/Double.pi) {
//            case -90, 90:
//                return CGSize(width: videoTrack.naturalSize.height, height: videoTrack.naturalSize.width)
//            default:
                return videoTrack.naturalSize
//            }
        }()

        let inputVideoTrackOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )

        inputReader.add(inputVideoTrackOutput)

        self.inputReader = inputReader
        self.inputVideoReader = inputVideoTrackOutput
        self.videoSize = videoSize

        // MARK: - Configuring Output:

        self.outputURL = outputURL
        let outputWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let format = try CMFormatDescription(
            videoCodecType: .mpeg4Video,
            width: Int(videoSize.width),
            height: Int(videoSize.height),
            extensions: nil
        )

        let outputVideoWriter = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: format
        )

        outputVideoWriter.expectsMediaDataInRealTime = true
        outputWriter.add(outputVideoWriter)

        outputVideoWriter.transform = videoTransform

        self.outputWriter = outputWriter
        self.outputVideoWriter = outputVideoWriter

        var session: VTCompressionSession?

        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(videoSize.width),
            height: Int32(videoSize.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard let session = session else {
            throw SegmentationWorkerError.unableToInitializeCompressionSession
        }

        self.compressionSession = session

        // MARK: - Configuring Scene:

        self.backgroundImage = Helpers.imageWithColor(color: backgroundColor, size: videoSize)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SegmentationWorkerError.unableToCreateMetalDevice
        }

        let renderer = SCNRenderer(device: device, options: nil)

        var cache: CVMetalTextureCache?
        Helpers.create(textureCache: &cache, forDevice: device)

        guard let textureCache = cache else {
            throw SegmentationWorkerError.unableToCreateTextureCache
        }

        let scene = SCNScene()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = .init(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        let planeSize: CGSize

        // TODO: Check this...
//        if videoTrack.naturalSize.width > videoTrack.naturalSize.height {
            planeSize = CGSize(width: 2 * (videoTrack.naturalSize.width/videoTrack.naturalSize.height), height: 2)
//        } else {
//            planeSize = CGSize(width: 2, height: 2 * (videoTrack.naturalSize.height/videoTrack.naturalSize.width))
//        }

        let planeNode = Helpers.makePlane(size: planeSize, distance: 1)

        planeNode.geometry?.firstMaterial?.shaderModifiers = [
            .surface: Shaders.maskShader
        ]

//        planeNode.eulerAngles.z = -videoRotation

        cameraNode.addChildNode(planeNode)
        renderer.scene = scene

        self.scene = scene
        self.framePlaneNode = planeNode
        self.sceneRenderer = renderer
        self.metalTextureCache = textureCache

        self.personSegmentationQualityLevel = accuracy.personSegmentationQualityLevel
    }

    func start() {
        guard !isRunning else { return }
        self.isRunning = true

        guard inputReader.startReading() else {
            delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.failedToStartReading)
            return
        }

        guard outputWriter.startWriting() else {
            delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.failedToStartWriting)
            return
        }

        outputWriter.startSession(atSourceTime: .zero)
        processNextSample()
    }

    private func processNextSample() {
        guard let nextSampleBuffer = inputVideoReader.copyNextSampleBuffer() else {
            didFinishProcessing()
            return
        }

        let presentationTimeStamp = nextSampleBuffer.outputPresentationTimeStamp

        let requestHandler = VNImageRequestHandler(cmSampleBuffer: nextSampleBuffer, options: [:])

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = personSegmentationQualityLevel

        do {
            guard let pixelBuffer = nextSampleBuffer.imageBuffer else {
                throw SegmentationWorkerError.missingFrameImageBuffer
            }

            // Performing Person Segmentation

            try requestHandler.perform([request])

            guard let maskPixelBuffer = request.results?.first?.pixelBuffer else {
                throw SegmentationWorkerError.missingSegmentationResult
            }

            // Composing and rendering composition

            let mask = Helpers.texture(from: maskPixelBuffer, format: .r8Unorm, planeIndex: 0, textureCache: metalTextureCache)

            let luma = Helpers.texture(from: pixelBuffer, format: .r8Unorm, planeIndex: 0, textureCache: metalTextureCache)
            let chroma = Helpers.texture(from: pixelBuffer, format: .rg8Unorm, planeIndex: 1, textureCache: metalTextureCache)

            framePlaneNode.geometry?.firstMaterial?.transparent.contents = luma
            framePlaneNode.geometry?.firstMaterial?.diffuse.contents = chroma
            framePlaneNode.geometry?.firstMaterial?.specular.contents = backgroundImage
            framePlaneNode.geometry?.firstMaterial?.ambient.contents = mask

            let result = sceneRenderer.snapshot(atTime: 0, with: videoSize, antialiasingMode: SCNAntialiasingMode.none)

            // Encoding and writing frame

            guard let resultPixelBuffer = Helpers.pixelBuffer(from: result) else {
                throw SegmentationWorkerError.unableToConvertImageToPixelBuffer
            }

            VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: resultPixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: frameDuration,
                frameProperties: nil,
                infoFlagsOut: nil,
                outputHandler: { [weak self] status, infoFlags, sampleBuffer in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        guard case .writing = self.outputWriter.status else {
                            return
                        }

                        if let sampleBuffer = sampleBuffer {
                            if !self.outputVideoWriter.append(sampleBuffer) {
                                self.delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.failedToWrite(self.outputWriter.status))
                            }
                        } else {
                            self.delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.encoderFailed(status))
                        }
                    }
                }
            )

            let progress = CMTimeGetSeconds(presentationTimeStamp)/self.videoDuration

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.segmentation(self, didUpdateProgress: progress, preview: result, transform: self.videoTransform)
                self.processNextSample()
            }
        } catch {
            delegate?.segmentation(self, didFailWithError: error)
        }
    }

    private func didFinishProcessing() {
        switch inputReader.status {
        case .failed:
            delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.failedToRead)
            return
        case .cancelled:
            delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.readingCancelled)
        case .completed:
            VTCompressionSessionInvalidate(compressionSession)
            outputVideoWriter.markAsFinished()

            // Consider waiting for the remaining frames...
            outputWriter.finishWriting(completionHandler: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.segmentation(self, didFinishWithOutput: self.outputURL)
                }
            })
        case .unknown, .reading:
            fallthrough
        @unknown default:
            // This shouldn't happen
            delegate?.segmentation(self, didFailWithError: SegmentationWorkerError.inconsistentState)
        }
    }
}

// MARK: - Helpers

struct Helpers {

    @discardableResult
    static func create(textureCache: inout CVMetalTextureCache?, forDevice metalDevice: MTLDevice) -> Bool {
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )

        return result == kCVReturnSuccess
    }

    static func makePlane(size: CGSize, distance: Float) -> SCNNode {
        let plane = SCNPlane(width: size.width, height: size.height)
        plane.cornerRadius = 0
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.diffuse.contents = NSColor(red: 0, green: 0, blue: 0, alpha: 1)

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = .init(0, 0, -distance)
        return planeNode
    }

    static func texture(
        from pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        planeIndex: Int,
        textureCache: CVMetalTextureCache?
    ) -> MTLTexture? {
        guard let textureCache = textureCache,
            planeIndex >= 0 /*,
            planeIndex < CVPixelBufferGetPlaneCount(pixelBuffer),
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange */
        else {
            return nil
        }

        var texture: MTLTexture?

        let width =  CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var textureRef: CVMetalTexture?

        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &textureRef
        )

        if result == kCVReturnSuccess, let textureRef = textureRef {
            texture = CVMetalTextureGetTexture(textureRef)
        }

        return texture
    }

    static func imageWithColor(color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    static func pixelBuffer(from image: NSImage) -> CVPixelBuffer? {
        let width = image.size.width
        let height = image.size.height

        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )

        guard let resultPixelBuffer = pixelBuffer, status == kCVReturnSuccess else {
            return nil
        }

        CVPixelBufferLockBaseAddress(resultPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(resultPixelBuffer)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: pixelData,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(resultPixelBuffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        CVPixelBufferUnlockBaseAddress(resultPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return resultPixelBuffer
    }
}

struct Shaders {

    static let maskShader =
        """
        float BT709_nonLinearNormToLinear(float normV) {
            if (normV < 0.081) {
                normV *= (1.0 / 4.5);
            } else {
                float a = 0.099;
                float gamma = 1.0 / 0.45;
                normV = (normV + a) * (1.0 / (1.0 + a));
                normV = pow(normV, gamma);
            }

            return normV;
        }

        vec4 yCbCrToRGB(float luma, vec2 chroma) {
            float y = luma;
            float u = chroma.r - 0.5;
            float v = chroma.g - 0.5;

            const float yScale = 255.0 / (235.0 - 16.0); //(BT709_YMax-BT709_YMin)
            const float uvScale = 255.0 / (240.0 - 16.0); //(BT709_UVMax-BT709_UVMin)

            y = y - 16.0/255.0;
            float r = y*yScale + v*uvScale*1.5748;
            float g = y*yScale - u*uvScale*1.8556*0.101 - v*uvScale*1.5748*0.2973;
            float b = y*yScale + u*uvScale*1.8556;

            r = clamp(r, 0.0, 1.0);
            g = clamp(g, 0.0, 1.0);
            b = clamp(b, 0.0, 1.0);

            r = BT709_nonLinearNormToLinear(r);
            g = BT709_nonLinearNormToLinear(g);
            b = BT709_nonLinearNormToLinear(b);
            return vec4(r, g, b, 1.0);
        }

        #pragma body

        float luma = texture2D(u_transparentTexture, _surface.transparentTexcoord).r;
        vec2 chroma = texture2D(u_diffuseTexture, _surface.diffuseTexcoord).rg;
        vec4 fgColor = yCbCrToRGB(luma, chroma);

        vec3 bgColor = texture2D(u_specularTexture, _surface.specularTexcoord).rgb;

        float mask = texture2D(u_ambientTexture, _surface.ambientTexcoord).r;

        _surface.transparent = vec4(0.0, 0.0, 0.0, 1.0);
        _surface.specular = vec4(0.0, 0.0, 0.0, 1.0);
        _surface.ambient = vec4(0.0, 0.0, 0.0, 1.0);

        if (mask > 0.5) {
            _surface.diffuse = vec4(fgColor.rgb, 1.0);
        } else {
            _surface.diffuse = vec4(bgColor.rgb, 1.0);
        }
        """
}
