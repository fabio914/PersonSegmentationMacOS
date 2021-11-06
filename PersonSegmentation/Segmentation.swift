//
//  Segmentation.swift.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Foundation
import AVFoundation
import SceneKit
import Vision

protocol SegmentationWorkerDelegate: AnyObject {

}

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

    init(
        inputURL: URL,
        outputURL: URL,
        accuracy: Accuracy,
        backgroundColor: NSColor
    ) throws {

        
    }
}
