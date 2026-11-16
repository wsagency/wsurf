// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import IOSurface
import QuartzCore

// D4 exit gate, F5: what out-of-process Chromium costs that no process footprint shows. A tab's last frame is an IOSurface the
// service made and WSurf's layer holds: it is in neither process's `phys_footprint` (dropping ten previews moved WSurf by 0 MB and the
// service by 0 MB), and a hidden tab keeps its one (about 2.4 MB at 840x705 @1x, 17.9 MB at 1300x860 @2x). A hidden renderer is a
// process of the service's tree, which is in no footprint WSurf reads for itself (the exit gate: ten hidden renderers took the tree
// from 174 to 664 MB, about 49 MB a tab; `PerfProbe.family` counts the tree). WSurf has no runtime memory budget to add these to:
// this counter is what its diagnostics and the resource benchmarks (`ResourceProbe`) read. No product UI uses it.

/// What WSurf holds for the pages that run in the service, by the counts the service-side figures do not include.
struct ChromiumRemoteMemory: Equatable {
    /// Pages that have a browser in the service.
    var browsers = 0
    /// Of those, the ones the service was told are hidden (their renderers idle, and their ring is freed).
    var hiddenBrowsers = 0
    /// Frames kept in layers (shown, hidden, or kept for a relaunch), and their size in bytes.
    var previews = 0
    var previewBytes = 0
}

extension ChromiumPage {
    /// The size of the IOSurface this page's layer shows: its last frame, or the one it kept while its service is replaced. 0 when it
    /// shows none.
    var previewBytes: Int {
        if let remote {
            return remote.connection.sink.previewBytes(for: remote.id)
        }
        guard let contents = retainedPreview?.contents, CFGetTypeID(contents as AnyObject) == IOSurfaceGetTypeID() else { return 0 }
        return IOSurfaceGetAllocSize(unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self))
    }
}

extension ChromiumRuntime {
    /// The counters above for every live page (a page in process has none of them).
    var remoteMemory: ChromiumRemoteMemory {
        var memory = ChromiumRemoteMemory()
        for page in livePages {
            if let remote = page.remote {
                memory.browsers += 1
                if remote.sentHidden {
                    memory.hiddenBrowsers += 1
                }
            }
            let bytes = page.previewBytes
            if bytes > 0 {
                memory.previews += 1
                memory.previewBytes += bytes
            }
        }
        return memory
    }
}
