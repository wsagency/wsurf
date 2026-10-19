// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// How Reader asks a tab's page whether it holds an article, waits for one to appear, and takes it out.
@MainActor
struct ReaderDriver {
    var probe: () async -> Bool
    var watch: () async -> Bool = { false }
    var extract: () async -> ReaderArticle?

    /// A driver for the tab's page in either engine. `page` is asked on every call, so a tab that swaps its page (a different
    /// engine for the site) is followed, a closed tab ends the work, and the driver never keeps a page alive.
    static func page(_ page: @escaping @MainActor () -> BrowserPage?) -> ReaderDriver {
        ReaderDriver(
            probe: {
                guard let page = page() else { return false }
                return await ReaderExtractor.isReaderable(page)
            },
            watch: {
                guard let page = page() else { return false }
                return await ReaderExtractor.becomesReaderable(page, within: ReaderExtractor.watchWindow)
            },
            extract: {
                guard let page = page() else { return nil }
                return await ReaderExtractor.article(in: page)
            }
        )
    }
}

/// Runs Mozilla's Readability in a content world of its own, through `BrowserPage`, so WebKit and Chromium tabs behave alike. The page
/// cannot see the scripts or what they leave behind, and nothing here runs in the page world. A page that never answers is given up
/// on after `replyCeiling`.
@MainActor
enum ReaderExtractor {
    static let world = WKContentWorld.world(name: "WSurfReader")

    static let replyCeiling: Duration = .seconds(5)

    /// How long a page that is not an article yet is watched for becoming one.
    static let watchWindow: Duration = .seconds(10)

    static func isReaderable(_ page: BrowserPage, within ceiling: Duration = replyCeiling) async -> Bool {
        await call(probeScript, in: page, within: ceiling)
    }

    static func becomesReaderable(_ page: BrowserPage, within window: Duration) async -> Bool {
        await call(
            watchScript, arguments: ["timeout": Int(window / .milliseconds(1))],
            in: page, within: window + replyCeiling
        )
    }

    private static func call(
        _ body: String, arguments: [String: any Sendable] = [:], in page: BrowserPage, within ceiling: Duration
    ) async -> Bool {
        guard let document = page.url, isEligible(document) else { return false }
        let value = await page.callAsyncJavaScript(
            body, arguments: arguments, in: world, within: ceiling, as: Bool.self
        )
        guard page.url == document else { return false }
        return value ?? false
    }

    static func article(in page: BrowserPage, within ceiling: Duration = replyCeiling) async -> ReaderArticle? {
        guard let document = page.url, isEligible(document) else { return nil }
        let value = await page.callAsyncJavaScript(extractScript, in: world, within: ceiling, as: String.self)
        guard page.url == document,
              let json = value,
              let article = await decode(json),
              page.url == document,
              article.url.absoluteString == document.absoluteString
        else { return nil }
        return article
    }

    @concurrent
    private nonisolated static func decode(_ json: String) async -> ReaderArticle? {
        ReaderArticle(json: json)
    }

    nonisolated static func isEligible(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// The text of a bundled script. Empty when the resource is missing, which turns Reader off; `ReaderExtractorTests` fails then.
    private static func source(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    private static let readerableSource = """
    \(source("Readability-readerable"))
    const readerArticleTypes = /^(article|newsarticle|blogposting|reportagenewsarticle|analysisnewsarticle|opinionnewsarticle|reviewnewsarticle|scholarlyarticle|techarticle|liveblogposting)$/i;
    function readerHasArticleMetadata() {
      const og = document.querySelector('meta[property="og:type"]');
      if (og && (og.content || '').trim().toLowerCase() === 'article') return true;
      for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
        let stack;
        try { stack = [JSON.parse(script.textContent)]; } catch (e) { continue; }
        while (stack.length) {
          const item = stack.pop();
          if (Array.isArray(item)) { stack.push(...item); continue; }
          if (!item || typeof item !== 'object') continue;
          const types = [].concat(item['@type'] || []);
          if (types.some(type => typeof type === 'string' && readerArticleTypes.test(type))) return true;
          if (item['@graph']) stack.push(item['@graph']);
        }
      }
      const articles = document.querySelectorAll('article');
      return articles.length === 1 && articles[0].querySelector('time, [rel="author"], [itemprop="author"]') !== null;
    }
    let readerArticleList = false;
    function readerCounts(node) {
      if (readerArticleList && node.tagName === 'ARTICLE') return false;
      if (!isNodeVisible(node)) return false;
      if (node.checkVisibility && !node.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const rect = node.getBoundingClientRect();
      return rect.width > 1 && rect.height > 1;
    }
    function readerIsReaderable() {
      if (typeof isProbablyReaderable !== 'function') return false;
      readerArticleList = document.querySelectorAll('article').length > 1;
      const metadata = readerHasArticleMetadata();
      if (isProbablyReaderable(document, { visibilityChecker: readerCounts })) {
        const root = location.pathname.replace(/\\/+$/, '') === '' && !location.search;
        return metadata || !root;
      }
      return metadata && isProbablyReaderable(document, { minScore: 10, minContentLength: 100, visibilityChecker: readerCounts });
    }
    """

    private static let probeScript = """
    if (document.readyState === 'loading') {
      await new Promise(resolve => document.addEventListener('DOMContentLoaded', resolve, { once: true }));
    }
    \(readerableSource)
    return readerIsReaderable();
    """

    private static let watchScript = """
    \(readerableSource)
    if (readerIsReaderable()) return true;
    return await new Promise(resolve => {
      let pending = null;
      const finish = value => {
        observer.disconnect();
        clearTimeout(pending);
        clearTimeout(deadline);
        resolve(value);
      };
      const observer = new MutationObserver(() => {
        if (pending) return;
        pending = setTimeout(() => {
          pending = null;
          if (readerIsReaderable()) finish(true);
        }, 500);
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      const deadline = setTimeout(() => finish(false), timeout);
    });
    """

    private static let extractScript = """
    \(source("Readability"))
    if (typeof Readability !== 'function') return '';
    const copy = document.cloneNode(true);
    const parsed = new Readability(copy, { charThreshold: 400 }).parse();
    if (!parsed || !parsed.content) return '';
    const holder = copy.createElement('div');
    holder.innerHTML = parsed.content;
    const removed = 'script, style, link, meta, base, iframe, frame, frameset, object, embed, applet, '
      + 'form, input, button, select, textarea, noscript, template, portal';
    holder.querySelectorAll(removed).forEach(el => el.remove());
    const urlAttributes = ['href', 'src', 'srcset', 'xlink:href', 'action', 'formaction', 'poster', 'data'];
    for (const el of holder.querySelectorAll('*')) {
      for (const attr of Array.from(el.attributes)) {
        const name = attr.name.toLowerCase();
        const value = attr.value.replace(/[\\s\\u0000-\\u001f]/g, '').toLowerCase();
        const scripted = urlAttributes.includes(name) && (value.startsWith('javascript:') || value.startsWith('vbscript:') || value.startsWith('data:text/html'));
        if (name.startsWith('on') || name === 'style' || name === 'srcdoc' || scripted) el.removeAttribute(attr.name);
      }
    }
    holder.querySelectorAll('img').forEach(img => img.setAttribute('loading', 'lazy'));
    const selector = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, figcaption, dt, dd';
    const blocks = [];
    for (const el of holder.querySelectorAll(selector)) {
      if (el.querySelector(selector)) continue;
      const text = (el.textContent || '').replace(/\\s+/g, ' ').trim();
      if (!text) continue;
      el.setAttribute('data-reader-block', String(blocks.length));
      blocks.push(text);
    }
    if (!blocks.length) {
      const text = (parsed.textContent || '').replace(/\\s+/g, ' ').trim();
      if (!text) return '';
      blocks.push(text);
    }
    return JSON.stringify({
      url: location.href,
      title: parsed.title || document.title || '',
      byline: parsed.byline || '',
      siteName: parsed.siteName || '',
      excerpt: parsed.excerpt || '',
      lang: parsed.lang || document.documentElement.lang || '',
      dir: parsed.dir || '',
      content: holder.innerHTML,
      blocks
    });
    """
}
