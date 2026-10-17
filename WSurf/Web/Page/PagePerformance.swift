// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// A summary of how the current document loaded and behaves, read from the page's own Performance Timeline, never a trace.
/// A metric the engine does not expose is `null` and named in `unsupported`; `null` without a name means the engine supports it
/// and nothing has been observed yet.
nonisolated enum PagePerformance {
    static let slowestCount = 5

    /// The body of an async function. Page-provided URLs are cut to origin and path, so no query value, fragment or credential
    /// reaches the client.
    static let script = #"""
      const round = value => Math.round(value * 10) / 10;
      const clean = value => {
        try {
          const url = new URL(value, document.baseURI);
          return (url.origin === 'null' ? url.protocol : url.origin + url.pathname).slice(0, 160);
        } catch (e) { return ''; }
      };
      const supported = typeof PerformanceObserver === 'function' && PerformanceObserver.supportedEntryTypes
        ? Array.from(PerformanceObserver.supportedEntryTypes) : ['navigation', 'paint', 'resource'];
      const has = type => supported.includes(type);
      const unsupported = ['navigation', 'paint', 'resource', 'largest-contentful-paint', 'layout-shift', 'longtask'].filter(type => !has(type));
      // Buffered entries reach an observer in a later task, so one is read after a turn of the event loop.
      const observe = type => new Promise(resolve => {
        if (!has(type)) { resolve(null); return; }
        const seen = [];
        let observer;
        try {
          observer = new PerformanceObserver(list => seen.push(...list.getEntries()));
          observer.observe({ type, buffered: true });
        } catch (e) { resolve(null); return; }
        setTimeout(() => { seen.push(...observer.takeRecords()); observer.disconnect(); resolve(seen); }, 0);
      });
      const [lcpEntries, shiftEntries, taskEntries] = await Promise.all(
        ['largest-contentful-paint', 'layout-shift', 'longtask'].map(observe));

      const nav = has('navigation') ? performance.getEntriesByType('navigation')[0] : null;
      const navigation = nav ? {
        type: nav.type,
        ttfbMs: nav.responseStart > 0 ? round(nav.responseStart) : null,
        domContentLoadedMs: nav.domContentLoadedEventStart > 0 ? round(nav.domContentLoadedEventStart) : null,
        loadMs: nav.loadEventStart > 0 ? round(nav.loadEventStart) : null,
        transferBytes: nav.transferSize || 0,
        redirectCount: nav.redirectCount || 0,
      } : null;

      const paints = has('paint') ? performance.getEntriesByType('paint') : null;
      const paintAt = name => {
        const entry = paints && paints.find(candidate => candidate.name === name);
        return entry ? round(entry.startTime) : null;
      };
      const lcp = lcpEntries && lcpEntries.length ? lcpEntries[lcpEntries.length - 1] : null;
      const paint = paints || lcpEntries ? {
        firstPaintMs: paintAt('first-paint'),
        firstContentfulPaintMs: paintAt('first-contentful-paint'),
        largestContentfulPaintMs: lcp ? round(lcp.startTime) : null,
        largestContentfulElement: lcp && lcp.element ? lcp.element.localName : null,
        largestContentfulUrl: lcp && lcp.url ? clean(lcp.url) : null,
      } : null;

      // Cumulative layout shift as a page-load metric: the worst window of shifts less than 1 s apart and under 5 s long.
      let layout = null;
      if (shiftEntries) {
        let sum = 0, worstWindow = 0, windowStart = 0, previous = 0, count = 0, worst = 0;
        for (const entry of shiftEntries) {
          if (entry.hadRecentInput) continue;
          count++;
          worst = Math.max(worst, entry.value);
          if (sum && entry.startTime - previous < 1000 && entry.startTime - windowStart < 5000) sum += entry.value;
          else { sum = entry.value; windowStart = entry.startTime; }
          previous = entry.startTime;
          worstWindow = Math.max(worstWindow, sum);
        }
        layout = { cumulativeShift: Math.round(worstWindow * 1000) / 1000, shifts: count, worstShift: Math.round(worst * 1000) / 1000 };
      }

      const longTasks = taskEntries ? {
        count: taskEntries.length,
        totalMs: round(taskEntries.reduce((sum, entry) => sum + entry.duration, 0)),
        maxMs: round(taskEntries.reduce((most, entry) => Math.max(most, entry.duration), 0)),
      } : null;

      let resources = null;
      if (has('resource')) {
        const entries = performance.getEntriesByType('resource');
        const byType = {};
        let transfer = 0, decoded = 0, sizeHidden = 0;
        const typeOf = entry => entry.initiatorType === 'xmlhttprequest' ? 'xhr' : (entry.initiatorType || 'other').slice(0, 24);
        for (const entry of entries) {
          const type = typeOf(entry);
          const slot = byType[type] || (byType[type] = { count: 0, transferBytes: 0 });
          slot.count++;
          slot.transferBytes += entry.transferSize || 0;
          transfer += entry.transferSize || 0;
          decoded += entry.decodedBodySize || 0;
          // A cross-origin response without Timing-Allow-Origin reports no size at all.
          if (!entry.transferSize && !entry.encodedBodySize && !entry.decodedBodySize) sizeHidden++;
        }
        const slowest = entries.slice().sort((a, b) => b.duration - a.duration).slice(0, \#(slowestCount)).map(entry => ({
          url: clean(entry.name), type: typeOf(entry), durationMs: round(entry.duration), transferBytes: entry.transferSize || 0,
        }));
        // The timeline keeps 250 resources by default; a full buffer may have dropped later ones.
        resources = { count: entries.length, transferBytes: transfer, decodedBytes: decoded, sizeHidden, byType, slowest,
          bufferFull: entries.length >= 250 };
      }

      return JSON.stringify({
        document: location.protocol === 'http:' || location.protocol === 'https:' ? location.origin + location.pathname : clean(location.href),
        elapsedMs: round(performance.now()), navigation, paint, layout, longTasks, resources, unsupported,
      });
    """#
}

extension ChromiumPage {
    /// Counters Chromium reports for this page right now (heap, DOM nodes, documents, listeners). Durations and counts that
    /// DevTools accumulates only while enabled are not read, since a single read would see none. Nil when the page does not answer.
    func runtimeMetrics() async -> [String: Int]? {
        guard (try? await command("Performance.enable")) != nil else { return nil }
        let reply = try? await command("Performance.getMetrics")
        // A new task, so a cancelled request still switches the domain off.
        await Task { @MainActor in _ = try? await self.command("Performance.disable") }.value
        guard let metrics = reply?["metrics"] as? [[String: Any]] else { return nil }
        let names = [
            "JSHeapUsedSize": "jsHeapUsedBytes", "JSHeapTotalSize": "jsHeapTotalBytes", "Nodes": "domNodes", "Documents": "documents",
            "JSEventListeners": "jsEventListeners",
        ]
        var values: [String: Int] = [:]
        for metric in metrics {
            guard let name = metric["name"] as? String, let key = names[name], let value = (metric["value"] as? NSNumber)?.doubleValue,
                value.isFinite, value >= 0
            else { continue }
            values[key] = Int(value)
        }
        return values.isEmpty ? nil : values
    }
}

extension PageDriver {
    static func readPerformance(in webView: BrowserPage) async -> String {
        await PageSettle.untilIdle(webView)
        guard var report = await evaluateAsyncJSON(PageAutomationGuard.scriptCheck + PagePerformance.script, in: webView) else {
            return "The page did not respond. Use readPerformance after it finishes loading."
        }
        if report["stale"] as? Bool == true { return staleMessage }
        var unsupported = report["unsupported"] as? [String] ?? []
        report["engine"] = webView.chromium == nil ? "webkit" : "chromium"
        if let chromium = webView.chromium, let runtime = await chromium.runtimeMetrics() {
            report["runtime"] = runtime
        } else {
            report["runtime"] = NSNull()
            unsupported.append("runtime")
        }
        report["unsupported"] = unsupported
        guard PageAutomationGuard.allowsExecution,
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return staleMessage }
        var result = "PERFORMANCE:\n" + String(decoding: data, as: UTF8.self)
        // The reply is not a new observation, so the one in force stays valid.
        if let current = observation(in: webView) { result += "\nobservationID: \(current.id)" }
        return result
    }

    /// `evaluateJSON` for a body that waits: the engines run it as an async function.
    private static func evaluateAsyncJSON(_ body: String, in webView: BrowserPage) async -> [String: Any]? {
        guard PageAutomationGuard.allowsExecution,
            await selectedFrameIsLive(in: webView),
            let raw = (try? await webView.callAsyncJavaScript(body, arguments: [:], in: selectedFrame?.frame, contentWorld: PageAutomationGuard.world)) as? String,
            PageAutomationGuard.allowsExecution,
            await selectedFrameIsLive(in: webView),
            let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { return nil }
        return object
    }
}
