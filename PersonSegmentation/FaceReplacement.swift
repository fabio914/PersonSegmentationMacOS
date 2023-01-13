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

protocol FaceReplacementWorkerDelegate: AnyObject {
    func faceReplacement(_ worker: FaceReplacementWorker, didFailWithError: Error)
    func faceReplacement(_ worker: FaceReplacementWorker, didUpdateProgress: Double, preview: NSImage, transform: CGAffineTransform)
    func faceReplacement(_ worker: FaceReplacementWorker, didFinishWithOutput url: URL)
}

enum FaceReplacementWorkerError: Error {
    case failedToLoadImage
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

final class FaceReplacementWorker {

    weak var delegate: FaceReplacementWorkerDelegate?
    private let outputURL: URL
    private let overlayImage: NSImage

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

    private let metalTextureCache: CVMetalTextureCache
    private let scene: SCNScene
    private let framePlaneNode: SCNNode
    private let cameraNode: SCNNode
    private let sceneRenderer: SCNRenderer
    private let videoPlaneSize: CGSize

    init(
        inputURL: URL,
        outputURL: URL,
        imageURL: URL
    ) throws {

        // MARK: - Configuring Input:

        let inputAsset = AVAsset(url: inputURL)
        let inputReader = try AVAssetReader(asset: inputAsset)

        guard let videoTrack = inputAsset.tracks(withMediaType: .video).first else {
            throw FaceReplacementWorkerError.missingVideoTrack
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
            throw FaceReplacementWorkerError.unableToInitializeCompressionSession
        }

        self.compressionSession = session

        // MARK: - Configuring Scene:

        guard let image = NSImage(contentsOf: imageURL) else {
            throw FaceReplacementWorkerError.failedToLoadImage
        }

        self.overlayImage = image

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FaceReplacementWorkerError.unableToCreateMetalDevice
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

        let planeNode = Helpers.makePlane(size: planeSize, distance: 10)
        self.videoPlaneSize = planeSize

        planeNode.geometry?.firstMaterial?.shaderModifiers = [
            .surface: Shaders.videoShader
        ]

//        planeNode.eulerAngles.z = -videoRotation

        cameraNode.addChildNode(planeNode)
        renderer.scene = scene

        self.scene = scene
        self.framePlaneNode = planeNode
        self.cameraNode = cameraNode
        self.sceneRenderer = renderer
        self.metalTextureCache = textureCache
    }

    func start() {
        guard !isRunning else { return }
        self.isRunning = true

        guard inputReader.startReading() else {
            delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.failedToStartReading)
            return
        }

        guard outputWriter.startWriting() else {
            delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.failedToStartWriting)
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

        let request = VNDetectFaceRectanglesRequest()

        do {
            guard let pixelBuffer = nextSampleBuffer.imageBuffer else {
                throw FaceReplacementWorkerError.missingFrameImageBuffer
            }

            // Performing Person Segmentation

            try requestHandler.perform([request])

            let containerNode = SCNNode()
            containerNode.position = .init(x: 0, y: 0, z: -1)

            let scale = 1.5

            if let results = request.results, !results.isEmpty {

                for result in results where result.confidence > 0.5 {
                    let boundingBox = result.boundingBox

                    let position = CGPoint(x: (boundingBox.midX - 0.5) * videoPlaneSize.width, y: (boundingBox.midY - 0.5) * videoPlaneSize.height)
                    let size = CGSize(width: boundingBox.width * videoPlaneSize.width * scale, height: boundingBox.height * videoPlaneSize.height * scale)

                    let plane = SCNPlane(width: size.width, height: size.height)

                    plane.cornerRadius = 0
                    plane.firstMaterial?.lightingModel = .constant

                    // TODO: Fix size
                    plane.firstMaterial?.diffuse.contents = overlayImage

                    let planeNode = SCNNode(geometry: plane)
                    planeNode.position = .init(x: position.x, y: position.y, z: 0)

                    containerNode.addChildNode(planeNode)
                }
            }

            cameraNode.addChildNode(containerNode)

            // Composing and rendering composition

            let luma = Helpers.texture(from: pixelBuffer, format: .r8Unorm, planeIndex: 0, textureCache: metalTextureCache)
            let chroma = Helpers.texture(from: pixelBuffer, format: .rg8Unorm, planeIndex: 1, textureCache: metalTextureCache)

            framePlaneNode.geometry?.firstMaterial?.transparent.contents = luma
            framePlaneNode.geometry?.firstMaterial?.diffuse.contents = chroma

            let result = sceneRenderer.snapshot(atTime: 0, with: videoSize, antialiasingMode: SCNAntialiasingMode.none)

            containerNode.removeFromParentNode()

            // Encoding and writing frame

            guard let resultPixelBuffer = Helpers.pixelBuffer(from: result) else {
                throw FaceReplacementWorkerError.unableToConvertImageToPixelBuffer
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
                                // FIXME!
//                                self.delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.failedToWrite(self.outputWriter.status))
                            }
                        } else {
                            self.delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.encoderFailed(status))
                        }
                    }
                }
            )

            let progress = CMTimeGetSeconds(presentationTimeStamp)/self.videoDuration

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.faceReplacement(self, didUpdateProgress: progress, preview: result, transform: self.videoTransform)
                self.processNextSample()
            }
        } catch {
            delegate?.faceReplacement(self, didFailWithError: error)
        }
    }

    private func didFinishProcessing() {
        switch inputReader.status {
        case .failed:
            delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.failedToRead)
            return
        case .cancelled:
            delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.readingCancelled)
        case .completed:
            VTCompressionSessionInvalidate(compressionSession)
            outputVideoWriter.markAsFinished()

            // Consider waiting for the remaining frames...
            outputWriter.finishWriting(completionHandler: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.faceReplacement(self, didFinishWithOutput: self.outputURL)
                }
            })
        case .unknown, .reading:
            fallthrough
        @unknown default:
            // This shouldn't happen
            delegate?.faceReplacement(self, didFailWithError: FaceReplacementWorkerError.inconsistentState)
        }
    }
}

extension Shaders {

    static let videoShader =
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

        _surface.diffuse = vec4(fgColor.rgb, 1.0);
        """
}
