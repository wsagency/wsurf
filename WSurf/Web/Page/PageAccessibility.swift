// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// A compact outline of what a page exposes to assistive technology, computed from the DOM and ARIA attributes by the same
/// script on both engines. It lists roles, names and states, never field values: a sensitive field shows its role and name only.
/// It is not the platform accessibility tree, so CSS-generated text and closed shadow roots are not part of a name or the outline.
nonisolated enum PageAccessibility {
    /// Per call: nodes, escaped bytes (the same measure as `PageOutputBudget.cost`), elements scanned and nodes built.
    static let maxNodes = 400
    static let maxBytes = 24_000
    static let scanLimit = 20_000
    static let buildLimit = 5_000
    /// Elements read to work out names, over the whole call: a page cannot make the outline cost more than this.
    static let nameWorkLimit = 100_000

    /// Defines `axTree(offset, scope)` after the runtime. It returns an object, never throws for page content.
    static let script = #"""
      const axTree = (offset, scope) => {
        const MAX_NODES = \#(maxNodes), BUDGET = \#(maxBytes), SCAN_MAX = \#(scanLimit), BUILD_MAX = \#(buildLimit), WORK_MAX = \#(nameWorkLimit);
        const NAME_MAX = 100, MAX_NEST = 40, SVG_NS = 'http://www.w3.org/2000/svg';
        const norm = R.norm;
        const attr = (el, name) => el.getAttribute(name);
        const win = el => el.ownerDocument.defaultView || window;
        const styleOf = el => win(el).getComputedStyle(el);
        const encoder = new TextEncoder();
        // Bytes as the reply is delivered: the reader escapes & < >.
        const cost = text => {
          let bytes = encoder.encode(text).length;
          for (let i = 0; i < text.length; i++) {
            const c = text[i];
            if (c === '&') bytes += 4; else if (c === '<' || c === '>') bytes += 3;
          }
          return bytes;
        };
        const clip = text => {
          const chars = Array.from(norm(text));
          return chars.length > NAME_MAX ? chars.slice(0, NAME_MAX).join('') + '\u2026' : chars.join('');
        };

        if (scope && R.selectorProblem(scope)) return { error: 'The scope selector is invalid or reads an attribute value that is not exposed.' };
        let roots = [];
        try { roots = scope ? Array.from(document.querySelectorAll(scope)) : (document.body ? [document.body] : []); } catch (e) {}
        if (scope && !roots.length) return { error: 'No element matches that scope.' };
        roots = roots.filter(root => !roots.some(other => other !== root && other.contains(root)));

        // Refs are the ones readPage hands out, so a ref in this outline works with the observationID of this reply.
        const refOf = new Map();
        for (const entry of R.collect()) {
          const element = window.__wsurfRefs[entry.r - 1];
          if (element) refOf.set(element, entry.r);
        }

        const SKIP_TAGS = new Set(['script', 'style', 'template', 'noscript', 'head', 'meta', 'link', 'title', 'datalist', 'optgroup', 'option',
          'colgroup', 'col', 'source', 'track', 'param', 'object', 'embed', 'base']);
        const INLINE = new Set(['a', 'abbr', 'b', 'bdi', 'bdo', 'cite', 'code', 'data', 'dfn', 'em', 'font', 'i', 'kbd', 'label', 'mark', 'q',
          's', 'samp', 'small', 'span', 'strong', 'sub', 'sup', 'time', 'u', 'var']);
        const ROLES = new Set(['alert', 'alertdialog', 'application', 'article', 'banner', 'blockquote', 'button', 'caption', 'cell', 'checkbox',
          'columnheader', 'combobox', 'complementary', 'contentinfo', 'definition', 'dialog', 'directory', 'document', 'feed', 'figure', 'form',
          'grid', 'gridcell', 'group', 'heading', 'img', 'link', 'list', 'listbox', 'listitem', 'log', 'main', 'marquee', 'math', 'menu',
          'menubar', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'meter', 'navigation', 'option', 'paragraph', 'progressbar', 'radio',
          'radiogroup', 'region', 'row', 'rowgroup', 'rowheader', 'scrollbar', 'search', 'searchbox', 'separator', 'slider', 'spinbutton',
          'status', 'switch', 'tab', 'table', 'tablist', 'tabpanel', 'term', 'textbox', 'timer', 'toolbar', 'tooltip', 'tree', 'treegrid',
          'treeitem']);
        // Roles with no line of their own: their children are listed in their place.
        const PASSIVE = new Set(['application', 'blockquote', 'caption', 'directory', 'document', 'math', 'paragraph', 'rowgroup']);
        // Children are presentational (or a field's value), so they are neither listed nor read.
        const LEAF = new Set(['button', 'checkbox', 'img', 'meter', 'progressbar', 'radio', 'scrollbar', 'separator', 'slider', 'switch', 'tab',
          'menuitemcheckbox', 'menuitemradio', 'option', 'textbox', 'searchbox', 'combobox', 'spinbutton']);
        const FIELD = new Set(['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider', 'listbox', 'checkbox', 'radio', 'switch']);
        const EMBEDDED = new Set(['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider', 'listbox']);
        const CONTENT_NAMED = new Set(['button', 'link', 'heading', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
          'treeitem', 'checkbox', 'radio', 'switch', 'cell', 'gridcell', 'columnheader', 'rowheader', 'listitem', 'term', 'definition',
          'tooltip', 'alert', 'status', 'log', 'timer']);
        // Their name is the text they hold themselves; text inside a child that has its own line belongs to that line.
        const OWN_TEXT = new Set(['cell', 'gridcell', 'listitem', 'term', 'definition']);
        const DROP_EMPTY = new Set(['article', 'cell', 'definition', 'figure', 'gridcell', 'group', 'listitem', 'radiogroup', 'region', 'row',
          'tabpanel', 'term', 'toolbar']);
        const STATE_ROLES = new Set(['button', 'link', 'textbox', 'searchbox', 'checkbox', 'radio', 'switch', 'combobox', 'listbox', 'option',
          'slider', 'spinbutton', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem']);
        const BUTTON_TYPES = new Set(['button', 'submit', 'reset', 'image', 'file', 'color']);
        const MARKERS = ['data-wsurf-payment-card', 'data-wsurf-contact', 'data-wsurf-password'];

        const hasNameAttributes = el => !!(norm(attr(el, 'aria-label')) || norm(attr(el, 'aria-labelledby')) || norm(attr(el, 'title')));
        const explicitRole = el => {
          const value = attr(el, 'role');
          if (!value) return undefined;
          for (const token of value.toLowerCase().split(/\s+/)) {
            if (token === 'presentation' || token === 'none') return null;
            if (ROLES.has(token)) return token;
          }
          return undefined;
        };
        const scoped = el => !(el.parentElement && el.parentElement.closest('article,aside,main,nav,section,[role=article],[role=complementary],[role=main],[role=navigation],[role=region]'));
        const inputRole = el => {
          const type = (el.type || 'text').toLowerCase();
          if (type === 'hidden') return null;
          if (BUTTON_TYPES.has(type)) return 'button';
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (type === 'range') return 'slider';
          if (type === 'number') return 'spinbutton';
          if (el.hasAttribute('list')) return 'combobox';
          return type === 'search' ? 'searchbox' : 'textbox';
        };
        const implicitRole = el => {
          const tag = el.localName;
          switch (tag) {
            case 'a': return el.hasAttribute('href') ? 'link' : null;
            case 'article': return 'article';
            case 'aside': return 'complementary';
            case 'button': case 'summary': return 'button';
            case 'details': case 'fieldset': return 'group';
            case 'dialog': return 'dialog';
            case 'figure': return 'figure';
            case 'footer': return scoped(el) ? 'contentinfo' : null;
            case 'header': return scoped(el) ? 'banner' : null;
            case 'form': return hasNameAttributes(el) ? 'form' : null;
            case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
            case 'hr': return 'separator';
            case 'iframe': case 'frame': return 'iframe';
            case 'img': return attr(el, 'alt') === '' ? null : 'img';
            case 'input': return inputRole(el);
            case 'li': return 'listitem';
            case 'main': return 'main';
            case 'menu': case 'ol': case 'ul': return 'list';
            case 'meter': return 'meter';
            case 'nav': return 'navigation';
            case 'output': return 'status';
            case 'progress': return 'progressbar';
            case 'search': return 'search';
            case 'section': return hasNameAttributes(el) ? 'region' : null;
            case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
            case 'table': return 'table';
            case 'tbody': case 'thead': case 'tfoot': return 'rowgroup';
            case 'td': {
              const grid = el.closest('table');
              const gridRole = grid && attr(grid, 'role');
              return gridRole === 'grid' || gridRole === 'treegrid' ? 'gridcell' : 'cell';
            }
            case 'textarea': return 'textbox';
            case 'th': return (attr(el, 'scope') || '').toLowerCase() === 'row' ? 'rowheader' : 'columnheader';
            case 'tr': return 'row';
            case 'dt': return 'term';
            case 'dd': return 'definition';
          }
          return el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable) ? 'textbox' : null;
        };
        const roleOf = el => {
          const explicit = explicitRole(el);
          if (explicit === null) return null;
          return explicit || implicitRole(el);
        };
        const emitsOwnLine = el => {
          if (el.localName === 'svg' && el.namespaceURI === SVG_NS) return false;
          const role = roleOf(el);
          return !!role && !PASSIVE.has(role);
        };

        const childrenOf = node => {
          if (node.nodeType === 1) {
            if (node.shadowRoot) return Array.from(node.shadowRoot.childNodes);
            if (node.localName === 'slot') {
              const assigned = node.assignedNodes ? node.assignedNodes({ flatten: true }) : [];
              if (assigned.length) return assigned;
            }
          }
          return Array.from(node.childNodes);
        };
        const embedded = el => {
          const tag = el.localName;
          if (tag === 'textarea' || tag === 'select') return true;
          if (tag === 'input') return !BUTTON_TYPES.has((el.type || '').toLowerCase());
          if (el.isContentEditable) return true;
          const role = explicitRole(el);
          return !!role && EMBEDDED.has(role);
        };

        // Text of a subtree, bounded. Fields contribute nothing, so a value never becomes part of a name.
        let work = 0;
        const contentText = (start, options = {}) => {
          const parts = [];
          let length = 0, visited = 0;
          const add = text => { if (length < 600) { parts.push(text); length += text.length; } };
          const walk = (node, top) => {
            if (length >= 600 || ++visited > 300 || ++work > WORK_MAX) return;
            if (node.nodeType === 3) { add(node.nodeValue); return; }
            if (node.nodeType !== 1) return;
            const tag = node.localName;
            if (tag === 'br') { add(' '); return; }
            if (SKIP_TAGS.has(tag) || embedded(node)) return;
            if (!top) {
              if (attr(node, 'aria-hidden') === 'true' || node.hasAttribute('inert')) return;
              const style = styleOf(node);
              if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return;
              if (options.ownText && emitsOwnLine(node)) return;
              const label = norm(attr(node, 'aria-label'));
              if (label) { add(' ' + label + ' '); return; }
              if (tag === 'img') { add(' ' + norm(attr(node, 'alt')) + ' '); return; }
              if (tag === 'svg' && node.namespaceURI === SVG_NS) {
                const title = Array.from(node.children).find(child => child.localName === 'title');
                add(' ' + (title ? norm(title.textContent) : '') + ' ');
                return;
              }
            }
            for (const child of childrenOf(node)) walk(child, false);
            if (!INLINE.has(tag)) add(' ');
          };
          walk(start, true);
          return clip(parts.join(''));
        };
        const labelsText = el => {
          const labels = el.labels;
          if (!labels || !labels.length) return '';
          return norm(Array.from(labels).map(label => contentText(label)).join(' '));
        };
        const firstChild = (el, tag) => Array.from(el.children).find(child => child.localName === tag);
        const nativeName = (el, tag) => {
          switch (tag) {
            case 'input': {
              const type = (el.type || '').toLowerCase();
              if (type === 'image') return norm(attr(el, 'alt')) || norm(attr(el, 'value')) || 'Submit';
              const label = labelsText(el);
              if (label) return label;
              if (type === 'submit') return norm(attr(el, 'value')) || 'Submit';
              if (type === 'reset') return norm(attr(el, 'value')) || 'Reset';
              if (type === 'button') return norm(attr(el, 'value'));
              return norm(attr(el, 'placeholder'));
            }
            case 'textarea': return labelsText(el) || norm(attr(el, 'placeholder'));
            case 'select': case 'meter': case 'progress': case 'output': case 'button': return labelsText(el);
            case 'img': return norm(attr(el, 'alt'));
            case 'fieldset': { const legend = firstChild(el, 'legend'); return legend ? contentText(legend) : ''; }
            case 'table': { const caption = firstChild(el, 'caption'); return caption ? contentText(caption) : ''; }
            case 'figure': { const caption = firstChild(el, 'figcaption'); return caption ? contentText(caption) : ''; }
            case 'svg': { const title = firstChild(el, 'title'); return title ? norm(title.textContent) : ''; }
          }
          return '';
        };
        const nameOf = (el, role) => {
          const ids = norm(attr(el, 'aria-labelledby'));
          if (ids) {
            const root = el.getRootNode();
            const referenced = ids.split(' ').map(id => {
              const target = root.getElementById ? root.getElementById(id) : null;
              return target ? contentText(target) : '';
            }).join(' ');
            if (norm(referenced)) return clip(referenced);
          }
          const label = norm(attr(el, 'aria-label'));
          if (label) return clip(label);
          const native = nativeName(el, el.localName);
          if (native) return clip(native);
          if (CONTENT_NAMED.has(role)) {
            const text = contentText(el, { ownText: OWN_TEXT.has(role) });
            if (text) return text;
          }
          return clip(attr(el, 'title') || '');
        };

        let active = document.activeElement;
        for (let hops = 0; active && hops < 8; hops++) {
          if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue; }
          if (active.localName === 'iframe' || active.localName === 'frame') {
            let inner = null;
            try { inner = active.contentDocument && active.contentDocument.activeElement; } catch (e) {}
            if (inner && inner !== active.contentDocument.body) { active = inner; continue; }
          }
          break;
        }
        if (active === document.body) active = null;

        const isSensitive = (el, role) => {
          if (MARKERS.some(marker => el.hasAttribute(marker))) return true;
          const tag = el.localName;
          const field = tag === 'textarea' || tag === 'select' || (tag === 'input' && !BUTTON_TYPES.has((el.type || '').toLowerCase()))
            || FIELD.has(role) || el.isContentEditable;
          return field && R.isSensitiveField(el);
        };
        const flagsOf = (el, role) => {
          const tag = el.localName, flags = [];
          if (role === 'heading') {
            const level = parseInt(attr(el, 'aria-level') || (/^h[1-6]$/.test(tag) ? tag[1] : ''), 10);
            if (level >= 1) flags.push('level=' + level);
          }
          let checked = attr(el, 'aria-checked');
          if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) checked = el.indeterminate ? 'mixed' : String(el.checked);
          if (checked !== null || ['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
            flags.push(checked === 'mixed' ? 'mixed' : checked === 'true' ? 'checked' : 'unchecked');
          }
          const pressed = attr(el, 'aria-pressed');
          if (pressed !== null && role === 'button') flags.push(pressed === 'true' ? 'pressed' : pressed === 'mixed' ? 'pressed=mixed' : 'unpressed');
          let expanded = attr(el, 'aria-expanded');
          if (expanded === null && tag === 'details') expanded = String(el.open);
          if (expanded === null && tag === 'summary' && el.parentElement && el.parentElement.localName === 'details') expanded = String(el.parentElement.open);
          if (expanded !== null) flags.push(expanded === 'true' ? 'expanded' : 'collapsed');
          if (attr(el, 'aria-selected') === 'true' || (tag === 'option' && el.selected)) flags.push('selected');
          const current = attr(el, 'aria-current');
          if (current && current !== 'false') flags.push(current === 'true' ? 'current' : 'current=' + current);
          if (STATE_ROLES.has(role) && R.disabled(el)) flags.push('disabled');
          if (FIELD.has(role)) {
            if (el.required === true || attr(el, 'aria-required') === 'true') flags.push('required');
            if (el.readOnly === true || attr(el, 'aria-readonly') === 'true') flags.push('readonly');
          }
          const invalid = attr(el, 'aria-invalid');
          if (invalid && invalid !== 'false') flags.push('invalid');
          if (role === 'dialog' || role === 'alertdialog') {
            let modal = attr(el, 'aria-modal') === 'true';
            try { modal = modal || (tag === 'dialog' && el.matches(':modal')); } catch (e) {}
            if (modal) flags.push('modal');
          }
          if (attr(el, 'aria-busy') === 'true') flags.push('busy');
          const popup = attr(el, 'aria-haspopup');
          if (popup && popup !== 'false') flags.push(popup === 'true' ? 'haspopup' : 'haspopup=' + popup);
          if (el === active) flags.push('focused');
          return flags;
        };
        const makeNode = (el, role) => {
          const sensitive = isSensitive(el, role);
          return { el, role, sensitive, name: nameOf(el, role), flags: sensitive ? ['sensitive'] : flagsOf(el, role), kids: [], ref: refOf.get(el) || 0 };
        };

        // Build the outline in document order. Plain containers have no node of their own; their children join the nearest node above.
        const tree = { kids: [], depth: 0 };
        const stack = [{ kids: roots, i: 0, target: tree }];
        let scanned = 0, built = 0, truncated = false, skippedFrames = 0;
        while (stack.length && !truncated) {
          const frame = stack[stack.length - 1];
          if (frame.i >= frame.kids.length) { stack.pop(); continue; }
          const el = frame.kids[frame.i++];
          if (!el || el.nodeType !== 1) continue;
          if (++scanned > SCAN_MAX) { truncated = true; break; }
          const tag = el.localName;
          if (SKIP_TAGS.has(tag) || attr(el, 'aria-hidden') === 'true' || el.hasAttribute('inert')) continue;
          const style = styleOf(el);
          if (style.display === 'none') continue;
          let role = style.visibility === 'hidden' || style.visibility === 'collapse' ? null : roleOf(el);
          if (tag === 'svg' && el.namespaceURI === SVG_NS && explicitRole(el) === undefined) {
            if (!hasNameAttributes(el) && !firstChild(el, 'title')) continue;
            role = 'img';
          }
          if (role && PASSIVE.has(role)) role = null;
          let target = frame.target;
          let node = null;
          if (role) {
            if (++built > BUILD_MAX) { truncated = true; break; }
            node = makeNode(el, role);
            node.depth = frame.target.depth + 1;
            frame.target.kids.push(node);
            if (frame.target.depth + 1 < MAX_NEST) target = node;
          }
          if ((role && LEAF.has(role)) || (node && node.sensitive) || style.contentVisibility === 'hidden') continue;
          if (role === 'iframe') {
            let inner = null;
            try { inner = el.contentDocument; } catch (e) {}
            if (inner && inner.body) stack.push({ kids: [inner.body], i: 0, target });
            else { node.flags.push('skipped'); skippedFrames++; }
            continue;
          }
          let kids = childrenOf(el);
          if (tag === 'details' && !el.open) kids = kids.filter(child => child.nodeType === 1 && child.localName === 'summary');
          stack.push({ kids, i: 0, target });
        }

        const prune = parent => {
          for (const kid of parent.kids) prune(kid);
          if (parent.role === 'list') parent.items = parent.kids.filter(kid => kid.role === 'listitem').length;
          parent.kids = parent.kids
            .filter(kid => {
              if (kid.role === 'img' && parent.name && kid.name === parent.name && !kid.ref) return false;
              return !(DROP_EMPTY.has(kid.role) && !kid.name && !kid.kids.length && !kid.ref);
            })
            // An unnamed item that holds one node adds nothing the list's item count does not say.
            .map(kid => kid.role === 'listitem' && !kid.name && kid.kids.length === 1 ? kid.kids[0] : kid);
        };
        prune(tree);

        const flat = [];
        const flatten = (parent, depth) => { for (const kid of parent.kids) { flat.push([kid, depth]); flatten(kid, depth + 1); } };
        flatten(tree, 0);

        const start = Math.max(0, offset);
        const lines = [], refs = [];
        let used = 0, unnamed = 0;
        for (let i = start; i < flat.length; i++) {
          const [node, depth] = flat[i];
          let line = '  '.repeat(Math.min(depth, 12));
          if (node.ref) line += '[' + node.ref + '] ';
          line += node.role;
          if (node.name) line += ' ' + JSON.stringify(node.name);
          if (node.items !== undefined) line += ' items=' + node.items;
          for (const flag of node.flags) line += ' ' + flag;
          const bytes = cost(line) + 1;
          if (lines.length >= MAX_NODES || (lines.length && used + bytes > BUDGET)) break;
          lines.push(line);
          used += bytes;
          if (node.ref) refs.push(node.ref);
          if (!node.name && STATE_ROLES.has(node.role)) unnamed++;
        }
        return { text: lines.join('\n'), start, count: lines.length, total: flat.length, hasMore: start + lines.length < flat.length,
          truncated: truncated || work > WORK_MAX, skippedFrames, unnamed, refs, snapshot: window.__wsurfSnapshot, document: R.documentID, url: location.href };
      };
    """#
}

extension PageDriver {
    static func readAccessibility(offset: Int, scope: String, in webView: BrowserPage) async -> String {
        if !scope.isEmpty {
            switch PageRuntime.validate(selector: scope) {
            case .success:
                break
            case .failure(.invalid):
                return "Invalid scope selector."
            case .failure(.empty), .failure(.tooLong):
                return "The scope selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."
            }
        }
        guard let selector = jsonString(scope) else { return "Invalid page query." }
        await PageSettle.untilIdle(webView)
        await PageSettle.untilQuiet(webView)
        let script = scripted(PageAccessibility.script + "return JSON.stringify(axTree(\(max(0, offset)), \(selector)));")
        guard let object = await evaluateJSON(script, in: webView) else {
            return "The page did not respond. Use readAccessibility after it finishes loading."
        }
        if let error = object["error"] as? String { return error }
        guard let id = object["snapshot"] as? String, let documentID = object["document"] as? String,
            let url = object["url"] as? String, let text = object["text"] as? String
        else { return "The page changed. Use readAccessibility again." }
        let count = object["count"] as? Int ?? 0
        let total = object["total"] as? Int ?? 0
        let start = object["start"] as? Int ?? 0
        let truncated = object["truncated"] as? Bool == true
        let refs = Set((object["refs"] as? [Int]) ?? [])
        observations.setObject(PageObservation(id: id, documentID: documentID, url: url, refs: refs), forKey: webView)

        var result = count == 0
            ? "ACCESSIBILITY TREE: no nodes" + (start > 0 ? " at that offset (\(total) in total)." : ".")
            : "ACCESSIBILITY TREE (nodes \(start + 1)-\(start + count) of \(total)\(truncated ? "+" : "")):\n\(text)"
        if let unnamed = object["unnamed"] as? Int, unnamed > 0 {
            result += "\nControls without a name in this part: \(unnamed)."
        }
        if let skipped = object["skippedFrames"] as? Int, skipped > 0 {
            result += "\nFrames that could not be read: \(skipped)."
        }
        if PageOutputBudget.cost(url) <= 350 {
            result += "\nurl: \(url)"
        }
        result += "\nobservationID: \(id)"
        if truncated {
            result += "\nThe page is larger than the scan limit, so later nodes are not listed. Use scope to read part of it."
        }
        if object["hasMore"] as? Bool == true {
            result += "\nMore nodes: readAccessibility offset=\(start + count)\(scope.isEmpty ? "" : "; keep the same scope")."
        }
        return result
    }
}
