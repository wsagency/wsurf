// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import PDFKit
import WebKit

@MainActor
enum PagePrinting {
    static func begin(for page: BrowserPage, then finished: (() -> Void)? = nil) {
        let id = ObjectIdentifier(page)
        guard let window = page.window, !page.isClosed,
              !(page.superview is WebViewParkingShelf),
              !printing.contains(id)
        else {
            finished?()
            return
        }

        printing.insert(id)
        Task {
            do {
                let info = NSPrintInfo.shared
                info.horizontalPagination = .fit
                info.isHorizontallyCentered = false
                let operation: NSPrintOperation
                if let webKit = page.webKit {
                    operation = webKit.printOperation(with: info)
                    operation.view?.frame = webKit.bounds
                } else if let chromium = page.chromium {
                    try await chromium.ensureReady()
                    let result = try await chromium.command("Page.printToPDF", params: [
                        "printBackground": true, "preferCSSPageSize": true
                    ])
                    guard let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded),
                          let document = PDFDocument(data: data),
                          let printing = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
                    else { throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a printable page.")) }
                    operation = printing
                } else { throw ChromiumError.closed }
                let sheet = PrintSheetDelegate {
                    printing.remove(id)
                    finished?()
                }
                sheets.append(sheet)
                operation.runModal(
                    for: window, delegate: sheet,
                    didRun: #selector(PrintSheetDelegate.printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            } catch {
                printing.remove(id)
                finished?()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "The page couldn’t be printed.")
                alert.informativeText = error.localizedDescription
                await alert.beginSheetModal(for: window)
            }
        }
    }

    private static var printing: Set<ObjectIdentifier> = []
    private static var sheets: [PrintSheetDelegate] = []

    fileprivate static func forget(_ sheet: PrintSheetDelegate) {
        sheets.removeAll { $0 === sheet }
    }
}

@MainActor
private final class PrintSheetDelegate: NSObject {
    private let finished: () -> Void

    init(finished: @escaping () -> Void) {
        self.finished = finished
        super.init()
    }

    @objc func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let finished = finished
        PagePrinting.forget(self)
        finished()
    }
}
