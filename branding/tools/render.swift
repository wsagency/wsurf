// usage: swift render.swift in.svg out.png width height [transparent]
import AppKit
import WebKit

let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1]), out = a[2]
let w = Double(a[3])!, h = Double(a[4])!
let transparent = a.count > 5
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
if transparent { wv.setValue(false, forKey: "drawsBackground") }
final class D: NSObject, WKNavigationDelegate {
    func webView(_ v: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let c = WKSnapshotConfiguration(); c.rect = v.bounds
            v.takeSnapshot(with: c) { img, err in
                guard let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                      let p = r.representation(using: .png, properties: [:]) else { print("ERR \(String(describing: err))"); exit(1) }
                try! p.write(to: URL(fileURLWithPath: out)); exit(0)
            }
        }
    }
}
let d = D(); wv.navigationDelegate = d
wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
app.run()
