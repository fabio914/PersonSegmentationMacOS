//
//  DragView.swift
//  PersonSegmentation
//
//  Created by Fabio Dela Antonio on 06/11/2021.
//

import Cocoa

@objc protocol DragViewDelegate {
    func dragView(_ view: DragView, didReceive fileURL: URL)
}

// https://stackoverflow.com/a/60251731

final class DragView: NSView {

    @IBOutlet weak var delegate: DragViewDelegate?
    var fileExtensions: Set<String> = ["mp4", "mov"]

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ draggingInfo: NSDraggingInfo) -> NSDragOperation {
        let matchingFiles = draggingInfo.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap({ $0 as? URL })
            .filter({ fileExtensions.contains($0.pathExtension.lowercased()) }) ?? []

        let containsMatchingFiles = !matchingFiles.isEmpty
        return containsMatchingFiles ? .copy:.init()
    }

    override func performDragOperation(_ draggingInfo: NSDraggingInfo) -> Bool {
        let matchingFileURL = draggingInfo.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { fileExtensions.contains($0.pathExtension.lowercased()) })

        guard let matchingFileURL = matchingFileURL else {
            return false
        }

        delegate?.dragView(self, didReceive: matchingFileURL)
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
    }
}
