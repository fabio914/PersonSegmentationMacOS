//
//  ViewController.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Cocoa

final class ViewController: NSViewController {

    @IBOutlet private weak var pathLabel: NSTextField!
    @IBOutlet private weak var selectFileButton: NSButton!
    @IBOutlet private weak var startProcessingButton: NSButton!

    @IBOutlet private weak var backgroundColorWell: NSColorWell!
    @IBOutlet private weak var qualityPopUpButton: NSPopUpButton!

    private var inputFileURL: URL? {
        didSet {
            if let inputFileURL = inputFileURL {
                pathLabel.stringValue = inputFileURL.path
                startProcessingButton.isEnabled = true
            } else {
                pathLabel.stringValue = "No selection"
                startProcessingButton.isEnabled = false
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputFileURL = nil
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    // MARK: - Actions

    @IBAction func selectFile(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a video"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.allowedFileTypes = ["mov", "mp4"]

        let modalResponse = openPanel.runModal()

        if case .OK = modalResponse, let selectedURL = openPanel.url {
            self.inputFileURL = selectedURL
        }
    }

    @IBAction func startProcessing(_ sender: Any) {
        guard let inputFileURL = inputFileURL else {
            return
        }

        do {
            let moviesDirectory = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let outputURL = moviesDirectory.appendingPathComponent("\(UUID().uuidString).mp4")

            let segmentationWorker = try SegmentationWorker(
                inputURL: inputFileURL,
                outputURL: outputURL,
                accuracy: .init(rawValue: qualityPopUpButton.indexOfSelectedItem) ?? .accurate,
                backgroundColor: backgroundColorWell.color
            )

            let segmentationViewController = self.storyboard?.instantiateController(withIdentifier: "SegmentationViewController") as? SegmentationViewController
            segmentationViewController?.segmentationWorker = segmentationWorker
            segmentationViewController.flatMap(presentAsSheet)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}
