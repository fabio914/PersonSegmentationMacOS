//
//  ViewController.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Cocoa

final class SegmentationViewController: NSViewController {

    @IBOutlet private weak var progresssIndicator: NSProgressIndicator!
    var segmentationWorker: SegmentationWorker?

    override func viewDidLoad() {
        super.viewDidLoad()
        progresssIndicator.startAnimation(self)
        segmentationWorker?.delegate = self
        segmentationWorker?.start()
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
}

extension SegmentationViewController: SegmentationWorkerDelegate {

    func segmentation(_ worker: SegmentationWorker, didFailWithError: Error) {

    }

    func segmentation(_ worker: SegmentationWorker, didUpdateProgress: Double) {

    }

    func segmentationDidFinish(_ worker: SegmentationWorker) {

    }
}
