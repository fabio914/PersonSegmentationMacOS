//
//  ViewController.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Cocoa

final class SegmentationViewController: NSViewController {

    @IBOutlet private weak var progresssIndicator: NSProgressIndicator!
    @IBOutlet private weak var previewImageView: NSImageView!

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

    func segmentation(_ worker: SegmentationWorker, didFailWithError error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .critical
        alert.runModal()

        dismiss(self)
    }

    func segmentation(
        _ worker: SegmentationWorker,
        didUpdateProgress progress: Double,
        preview: NSImage,
        transform: CGAffineTransform
    ) {
        progresssIndicator.doubleValue = progress
        previewImageView.image = preview

        previewImageView.layer?.position = CGPoint(x: NSMidX(previewImageView.frame), y: NSMidY(previewImageView.frame))
        previewImageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewImageView.layer?.transform = CATransform3DMakeRotation(-(atan2(transform.b, transform.a)), 0, 0, 1)
    }

    func segmentation(_ worker: SegmentationWorker, didFinishWithOutput url: URL) {
        let successAlert = NSAlert()
        successAlert.messageText = "Saved"
        successAlert.informativeText = "Saved to your Movies folder as \(url.lastPathComponent)"
        successAlert.addButton(withTitle: "OK")
        successAlert.alertStyle = .informational
        successAlert.runModal()

        dismiss(self)
        NSWorkspace.shared.open(url)
    }
}
