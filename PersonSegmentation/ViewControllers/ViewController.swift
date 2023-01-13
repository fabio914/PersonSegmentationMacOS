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

    @IBOutlet private weak var imagePathLabel: NSTextField!
    @IBOutlet private weak var selectImageButton: NSButton!
    @IBOutlet private weak var startProcessingButton: NSButton!

    @IBOutlet private weak var videoDragView: DragView!
    @IBOutlet private weak var imageDragView: DragView!

    private var inputFileURL: URL? {
        didSet {
            if let inputFileURL = inputFileURL {
                pathLabel.stringValue = inputFileURL.path
            } else {
                pathLabel.stringValue = "No selection"
            }
        }
    }

    private var imageFileURL: URL? {
        didSet {
            if let imageFileURL = imageFileURL {
                imagePathLabel.stringValue = imageFileURL.path
            } else {
                imagePathLabel.stringValue = "No selection"
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputFileURL = nil
        imageFileURL = nil

        videoDragView.fileExtensions = ["mov", "mp4"]
        imageDragView.fileExtensions = ["jpg", "png"]
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

    @IBAction func selectImageFile(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose an image"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.allowedFileTypes = ["jpg", "png"]

        let modalResponse = openPanel.runModal()

        if case .OK = modalResponse, let selectedURL = openPanel.url {
            self.imageFileURL = selectedURL
        }
    }

    @IBAction func startProcessing(_ sender: Any) {
        guard let inputFileURL, let imageFileURL else {
            return
        }

        do {
            let moviesDirectory = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let outputURL = moviesDirectory.appendingPathComponent("\(UUID().uuidString).mp4")

            let faceReplacementWorker = try FaceReplacementWorker(
                inputURL: inputFileURL,
                outputURL: outputURL,
                imageURL: imageFileURL
            )

            let faceReplacementViewController = self.storyboard?.instantiateController(withIdentifier: "FaceReplacementViewController") as? FaceReplacementViewController
            faceReplacementViewController?.faceReplacementWorker = faceReplacementWorker
            faceReplacementViewController.flatMap(presentAsSheet)
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

extension ViewController: DragViewDelegate {

    func dragView(_ view: DragView, didReceive fileURL: URL) {
        guard let viewIdentifier = view.identifier else { return }

        if viewIdentifier.rawValue == "InputVideo" {
            self.inputFileURL = fileURL
        } else if viewIdentifier.rawValue == "OverlayImage" {
            self.imageFileURL = fileURL
        }
    }
}
