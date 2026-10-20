// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

nonisolated struct PageTranslationSegment: Equatable, Sendable {
    let node: Int
    let text: String
}

/// Blocks to translate, each a list of text-node segments, and whether the page has more waiting right now.
nonisolated struct PageTranslationBatch: Equatable, Sendable {
    let blocks: [[PageTranslationSegment]]
    let hasMore: Bool

    var texts: [String] {
        blocks.map { $0.map(\.text).joined() }
    }
}

nonisolated struct PageTranslationSample: Equatable, Sendable {
    let declaredLanguage: String
    let text: String
}

/// Reads and replaces the text of a page's main frame in a content world of its own, through `BrowserPage`, so WebKit and Chromium
/// tabs behave alike. The page cannot see the script or call it. Nothing is installed at document start: a page that is never
/// translated runs none of this. Every answer is a JSON string, decoded here, so both engines return the same shapes.
@MainActor
enum PageTranslationScript {
    static let world = WKContentWorld.world(name: "WSurfTranslate")

    static let replyCeiling: Duration = .seconds(5)

    /// How long `next` waits in the page for new content before it answers with no blocks. Chromium fails a DevTools command after
    /// 15 seconds, so the wait and its ceiling stay below that.
    static let idleWait: Duration = .seconds(10)

    static func sample(in page: BrowserPage) async -> PageTranslationSample? {
        guard let object = await call(source + "return JSON.stringify(api.sample());", in: page) as? [String: Any] else { return nil }
        return PageTranslationSample(
            declaredLanguage: object["lang"] as? String ?? "",
            text: object["text"] as? String ?? ""
        )
    }

    /// Starts a run over the current document and returns its token, or nil when the page has no body or did not answer. Starting
    /// again restores the page and retires the earlier token.
    static func start(in page: BrowserPage) async -> Int? {
        let token = await call(source + "return JSON.stringify(api.start());", in: page) as? NSNumber
        return token.map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The next blocks to translate, nearest the viewport first. Empty when nothing new arrived within `idle`; nil when the run
    /// ended: restored, retired, the document is gone, or the page did not answer.
    static func next(
        limit: Int, token: Int, idle: Duration = idleWait, in page: BrowserPage
    ) async -> PageTranslationBatch? {
        guard let object = await call(
            installed + "return JSON.stringify(await api.next(limit, token, idle));",
            arguments: ["limit": limit, "token": token, "idle": Int(idle / .milliseconds(1))],
            within: idle + replyCeiling,
            in: page
        ) as? [String: Any], object["done"] as? Bool == false
        else { return nil }
        let blocks = (object["blocks"] as? [[[Any]]] ?? []).map { block in
            block.compactMap { pair -> PageTranslationSegment? in
                guard pair.count == 2,
                      let node = (pair[0] as? NSNumber)?.intValue,
                      let text = pair[1] as? String
                else { return nil }
                return PageTranslationSegment(node: node, text: text)
            }
        }
        return PageTranslationBatch(blocks: blocks, hasMore: object["more"] as? Bool ?? false)
    }

    static func apply(_ texts: [Int: String], in page: BrowserPage) async {
        let pairs = Array(texts)
        _ = await call(
            installed + "api.apply(nodes, texts); return 'true';",
            arguments: ["nodes": pairs.map(\.key), "texts": pairs.map(\.value)],
            in: page
        )
    }

    static func restore(in page: BrowserPage) async {
        _ = await call(installed + "api.restore(); return 'true';", in: page)
    }

    private static func call(
        _ body: String,
        arguments: [String: any Sendable] = [:],
        within ceiling: Duration = replyCeiling,
        in page: BrowserPage
    ) async -> Any? {
        guard let json = await page.callAsyncJavaScript(body, arguments: arguments, in: world, within: ceiling, as: String.self),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// The API a later call uses. A new document has none, which ends the run.
    private static let installed = """
    const api = globalThis.__wsurfTranslate;
    if (!api) return JSON.stringify({ done: true });

    """

    /// Groups each block's text nodes, so a sentence split by links or emphasis is translated as one, and hands them out nearest
    /// the viewport first. Groups are ranked once at start and again only after the viewport moves or new content arrives, never
    /// on every call, so a long page costs one ranking per change instead of one per batch.
    static let source = #"""
    if (!globalThis.__wsurfTranslate) {
      const skipped = new Set(['script', 'style', 'noscript', 'template', 'code', 'pre', 'kbd', 'samp', 'var',
        'textarea', 'input', 'select', 'option', 'svg', 'math', 'canvas', 'iframe', 'object', 'embed',
        'video', 'audio']);
      const letter = /\p{L}/u;
      const visible = /\S/;
      const displays = new WeakMap();
      let registry = [], queued = new WeakSet(), originals = new Map(), pending = [], head = 0, dirty = false, ranked = '';
      let active = false, token = 0, observer = null, waiter = null, added = new Set(), flush = null;

      const excluded = el => skipped.has(el.localName) || el.getAttribute('translate') === 'no'
        || el.classList.contains('notranslate') || el.isContentEditable;
      const insideExcluded = node => {
        for (let el = node.parentElement; el; el = el.parentElement) if (excluded(el)) return true;
        return false;
      };
      const isInline = el => {
        let display = displays.get(el);
        if (display === undefined) {
          display = getComputedStyle(el).display;
          displays.set(el, display);
        }
        return display === 'inline' || display === 'contents';
      };
      const blockOf = node => {
        let el = node.parentElement;
        while (el && el !== document.body && isInline(el)) el = el.parentElement;
        return el || document.body;
      };
      const wake = () => {
        const resolve = waiter;
        waiter = null;
        resolve?.();
      };
      const moved = () => { dirty = true; };
      const viewport = () => [scrollX, scrollY, innerWidth, innerHeight].join();

      const collect = root => {
        if (!root || !active) return;
        if (root.nodeType === Node.ELEMENT_NODE && excluded(root)) return;
        if (insideExcluded(root)) return;
        const open = new Map();
        const consider = node => {
          if (queued.has(node)) return;
          const block = blockOf(node);
          if (!visible.test(node.nodeValue) && !(node.nextSibling && open.has(block))) return;
          queued.add(node);
          let group = open.get(block);
          if (!group) {
            group = { element: block, nodes: [] };
            open.set(block, group);
            pending.push(group);
            dirty = true;
          }
          group.nodes.push(node);
        };
        if (root.nodeType === Node.TEXT_NODE) {
          consider(root);
          return;
        }
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: node => node.nodeType === Node.TEXT_NODE || node.localName === 'br'
            ? NodeFilter.FILTER_ACCEPT
            : excluded(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP
        });
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.nodeType === Node.TEXT_NODE) consider(node);
          else open.delete(blockOf(node));
        }
      };

      // On screen first, then below the viewport, then above it; elements without a box last.
      const distance = group => {
        const rect = group.element.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) return 1e9;
        if (rect.bottom <= 0) return 1e7 - rect.bottom;
        return Math.max(rect.top, 0);
      };
      const rank = () => {
        pending = pending.slice(head)
          .filter(group => group.element.isConnected)
          .map(group => [distance(group), group])
          .sort((a, b) => a[0] - b[0])
          .map(entry => entry[1]);
        head = 0;
        dirty = false;
        ranked = viewport();
      };

      globalThis.__wsurfTranslate = {
        sample() {
          const text = (document.body?.innerText || '').slice(0, 4000);
          return { lang: document.documentElement.lang || '', text: (document.title + '\n' + text).trim() };
        },

        start() {
          this.restore();
          if (!document.body) return 0;
          active = true;
          token += 1;
          collect(document.body);
          observer = new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) added.add(node);
            if (flush) return;
            flush = setTimeout(() => {
              flush = null;
              const nodes = [...added];
              added = new Set();
              for (const node of nodes) if (node.isConnected) collect(node);
              for (const node of originals.keys()) if (!node.isConnected) originals.delete(node);
              if (head < pending.length) wake();
            }, 300);
          });
          observer.observe(document.body, { childList: true, subtree: true });
          // The window's own position is compared on every call; the listener catches scrolling inside a container.
          addEventListener('scroll', moved, { capture: true, passive: true });
          return token;
        },

        async next(limit, expected, idle) {
          if (!active || expected !== token) return { done: true };
          if (head >= pending.length) {
            await new Promise(resolve => {
              waiter = resolve;
              setTimeout(resolve, idle);
            });
            if (!active || expected !== token) return { done: true };
          }
          if (dirty || ranked !== viewport()) rank();
          const blocks = [];
          while (blocks.length < limit && head < pending.length) {
            const group = pending[head++];
            if (!group.element.isConnected) continue;
            const segments = [];
            for (const node of group.nodes) {
              if (!node.isConnected) continue;
              const text = node.nodeValue.replace(/\s+/g, ' ');
              if (!text) continue;
              segments.push([registry.push(new WeakRef(node)) - 1, text]);
            }
            if (segments.some(segment => letter.test(segment[1]))) blocks.push(segments);
          }
          if (head > 256 && head * 2 > pending.length) {
            pending = pending.slice(head);
            head = 0;
          }
          return { done: false, blocks, more: head < pending.length };
        },

        apply(nodes, texts) {
          if (!active) return;
          nodes.forEach((index, position) => {
            const node = registry[index]?.deref();
            registry[index] = undefined;
            if (!node?.isConnected) return;
            const entry = originals.get(node) || { original: node.nodeValue };
            entry.translated = texts[position];
            originals.set(node, entry);
            node.nodeValue = entry.translated;
          });
        },

        restore() {
          active = false;
          observer?.disconnect();
          observer = null;
          clearTimeout(flush);
          flush = null;
          added = new Set();
          removeEventListener('scroll', moved, { capture: true });
          for (const [node, entry] of originals) {
            if (node.nodeValue === entry.translated) node.nodeValue = entry.original;
          }
          registry = [];
          queued = new WeakSet();
          originals = new Map();
          pending = [];
          head = 0;
          dirty = false;
          ranked = '';
          wake();
        }
      };

      addEventListener('pagehide', () => {
        if (!active) return;
        active = false;
        wake();
      });
      addEventListener('pageshow', event => {
        if (event.persisted) globalThis.__wsurfTranslate.restore();
      });
    }
    const api = globalThis.__wsurfTranslate;

    """#
}
