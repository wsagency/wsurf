// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The two scripts that route `navigator.credentials` public-key calls to the native authenticator on both engines.
///
/// - `relay` runs in an isolated content world. It owns the document fence: it forwards bounded requests to native,
///   forwards native results back only while its own document is live, and relays a trusted user activation for
///   conditional requests. The page cannot make it authorize anything; native derives origin, frame, policy and profile.
/// - `page` runs in the page world. It only marshals options and results into browser-facing objects.
///
/// Native decides the provider before the page script touches a call: `legacy` hands the untouched call to the engine,
/// `manager` is handled here and never falls back to the engine, and no answer is a refusal, never implicit legacy.
nonisolated enum WebAuthnScript {
    static let handlerName = "wsurfWebAuthn"
    static let requestEvent = "wsurf-webauthn-request"
    static let resultEvent = "wsurf-webauthn-result"

    static var page: String {
        pageSource
    }

    /// `nativeNonce`: a WebKit document is identified by the nonce the native frame registry issued over its private
    /// handshake (a non-writable global in this isolated world, never in the page world and never in any event or message
    /// to the page), so native can tell the live document from an older same-origin one. The relay waits on the
    /// handshake's own promise: no polling, no timer. A document with no handshake, or a failed one, is sent as
    /// unidentified: native passes it through under the legacy provider and refuses it under the encrypted one, and never
    /// builds a frame or ceremony for it. Chromium identifies documents natively over CDP, so its relay keeps a random
    /// per-document fence.
    static func relay(nativeNonce: Bool) -> String { "const NATIVE = \(nativeNonce);\n" + relaySource }

    private static let relaySource = #"""
    (() => {
      if (globalThis.__wsurfWebAuthnFence) return;
      const random = new Uint8Array(16);
      crypto.getRandomValues(random);
      let documentID = NATIVE ? null : Array.from(random, byte => byte.toString(16).padStart(2, '0')).join('');
      let unidentified = false;
      const requests = new Map();
      let active = true;
      // Bumped on every pagehide; a resume answer for an older epoch is ignored.
      let epoch = 0;
      // Pending while a restored document waits for native to re-confirm its live frame.
      let resuming = null;
      const post = body => globalThis.__wsurfSend('wsurfWebAuthn', {...body, document: documentID ?? ''});
      const send = body => { if (documentID && active) post(body); };
      // Settles once the native registry's current proof decided this document's identity: its ready promise must resolve
      // exactly `true` with its epoch unchanged meanwhile, and the marker must be a valid nonce.
      let identification = null;
      const identify = () => identification ??= (async () => {
        if (documentID) return;
        const ready = globalThis.__wsurfNativeFrameReady;
        const nativeEpoch = globalThis.__wsurfNativeFrameEpoch;
        let ok = false;
        try { ok = Number.isInteger(nativeEpoch) && ready instanceof Promise && (await ready) === true; } catch {}
        const nonce = globalThis.__wsurfNativeFrameNonce;
        if (ok && globalThis.__wsurfNativeFrameEpoch === nativeEpoch &&
            typeof nonce === 'string' && nonce.length > 0 && nonce.length <= 64) documentID = nonce;
        else unidentified = true;
      })();

      const emit = (id, value) => document.dispatchEvent(new CustomEvent('wsurf-webauthn-result',
        {detail: JSON.stringify({id, ...value})}));
      document.addEventListener('wsurf-webauthn-request', event => {
        if (typeof event.detail !== 'string' || event.detail.length > 262144) return;
        let body; try { body = JSON.parse(event.detail); } catch { return; }
        if (!body || typeof body.id !== 'string' || body.id.length === 0 || body.id.length > 80) return;
        if (body.action === 'cancel') {
          if (requests.delete(body.id)) { try { send({action: 'cancel', id: body.id}); } catch {} }
          return;
        }
        if (body.action !== 'request' || requests.size >= 8 || requests.has(body.id)) return;
        if (!active && !resuming) return;
        requests.set(body.id, {conditional: body.mediation === 'conditional', capabilities: body.operation === 'capabilities'});
        (resuming ? resuming.then(identify) : identify()).then(() => {
          if (!requests.has(body.id)) return;
          if (!active) return;
          try { post(body); }
          catch {
            requests.delete(body.id);
            emit(body.id, {error: {name: 'NotAllowedError', message: 'The native authenticator is unavailable.'}});
          }
        });
      });
      // A conditional request is only a pending discovery. Only a real user gesture on a webauthn field may start
      // the native account selection; scripted focus or synthetic events are not isTrusted and are ignored.
      const isWebAuthnField = node => {
        if (!(node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement)) return false;
        return (node.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).includes('webauthn');
      };
      const activate = event => {
        if (!active || !event.isTrusted || document.visibilityState !== 'visible') return;
        if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== 'ArrowDown') return;
        if (!isWebAuthnField(event.composedPath()[0])) return;
        for (const [id, request] of requests) {
          if (request.conditional) { try { send({action: 'conditionalActivate', id}); } catch {} return; }
        }
      };
      document.addEventListener('click', activate, true);
      document.addEventListener('keydown', activate, true);
      addEventListener('pagehide', () => {
        epoch += 1;
        resuming = null;
        const ids = [...requests.keys()];
        for (const id of ids) { try { send({action: 'cancel', id}); } catch {} }
        active = false;
        requests.clear();
      });
      // The same document restored from the back/forward cache stays inert until the native registry, which alone asks
      // native to resume (never this relay), proves the live native frame still matches. This relay captures its own and
      // the registry's epoch, awaits the registry's current ready promise, and reactivates only for exactly `true` with both
      // epochs unchanged and the marker still this document's nonce. Requests made meanwhile wait for that proof. Any other
      // outcome demotes the document to unidentified, exactly like one whose handshake failed: it keeps no identity, and
      // native then answers `legacy` or refuses it, never building a frame, context or ceremony. Chromium identifies
      // documents natively, so only its fence is re-armed.
      addEventListener('pageshow', event => {
        if (!event.persisted || !event.isTrusted || active) return;
        // A cached document runs none of the document-start scripts again, so its route may predate a provider change. The
        // page script treats `pending` asymmetrically (a previously-manager document keeps preparing manager requests that
        // native validates; a legacy or unrouted one is refused before any read) until native's single re-announcement.
        document.dispatchEvent(new CustomEvent('wsurf-webauthn-route', {detail: 'pending'}));
        try { post({action: 'route', id: 'route'}); } catch {}
        if (!NATIVE) { active = true; return; }
        const mine = epoch;
        const nativeEpoch = globalThis.__wsurfNativeFrameEpoch;
        const ready = globalThis.__wsurfNativeFrameReady;
        resuming = (async () => {
          let ok = false;
          try { ok = Number.isInteger(nativeEpoch) && ready instanceof Promise && (await ready) === true; } catch {}
          if (mine !== epoch) return;
          resuming = null;
          if (ok && globalThis.__wsurfNativeFrameEpoch === nativeEpoch &&
              (!documentID || globalThis.__wsurfNativeFrameNonce === documentID)) {
            active = true;
            return;
          }
          documentID = null;
          unidentified = true;
          // Sticky: a later request must not re-derive an identity from whatever the registry's current proof says.
          identification = Promise.resolve();
          active = true;
        })();
      });
      // The provider native decided for this document. Set by native's own document-start scripts (in order, so the last
      // one wins) and by a direct call for a document that is already live when the provider changes. A stale sequence
      // never overrides a newer one.
      let route = null;
      let routeSequence = -1;
      const announceRoute = () => { if (route) document.dispatchEvent(new CustomEvent('wsurf-webauthn-route', {detail: route})); };
      document.addEventListener('wsurf-webauthn-route-request', announceRoute);
      const fence = Object.freeze({
        deliver: (doc, id, value) => {
          const identity = documentID ?? (unidentified ? '' : null);
          if (!active || identity === null || doc !== identity || !requests.has(id)) return false;
          // A ceremony result is never delivered to an unidentified or hidden document. A capability answer carries no
          // secret and no authority; unidentified documents need it to learn which provider owns them.
          if (value.result && !requests.get(id).capabilities && (unidentified || document.visibilityState !== 'visible')) return false;
          requests.delete(id);
          emit(id, value);
          return true;
        },
        // Read-only: whether this live, identified document still holds exactly this request. Native asks before it prompts.
        isPending: (doc, id) => active && !!documentID && doc === documentID && requests.has(id),
        route: (value, sequence) => {
          if ((value !== 'legacy' && value !== 'manager') || !Number.isInteger(sequence) || sequence < routeSequence) return false;
          route = value;
          routeSequence = sequence;
          announceRoute();
          return true;
        }
      });
      Object.defineProperty(globalThis, '__wsurfWebAuthnFence', {value: fence});
    })();
    """#

    /// The provider announcement native installs right after the relay (the document-start order is the contract: the
    /// frame registry, then the relay, then this): `value` is `legacy` or `manager`, `sequence` grows with every provider
    /// change so a newer announcement always wins and an identical source is never deduplicated. Runs in the relay's
    /// isolated world, and is also evaluated in a live document when the provider changes.
    static func route(_ value: String, sequence: Int) -> String {
        precondition(value == "legacy" || value == "manager")
        return "globalThis.__wsurfWebAuthnFence?.route('\(value)', \(sequence));"
    }

    private static let pageSource = #"""
    (() => {
      const container = globalThis.navigator && navigator.credentials;
      if (!container || !globalThis.PublicKeyCredential || container.__wsurfWebAuthn) return;
      const proto = Object.getPrototypeOf(container) || container;
      const originals = {create: container.create.bind(container), get: container.get.bind(container)};
      const requests = new Map();

      const fail = (name, message) => new DOMException(message, name);
      const MAX_TEXT = 262144;

      // BufferSource per WebIDL, without [AllowShared]: a real ArrayBuffer or a view over one, from any realm. Brand checks use
      // the intrinsic getters captured here at document start (they throw for anything without the internal slot, including
      // a SharedArrayBuffer), never instanceof (false across realms) and never properties a page could have replaced.
      const getter = (proto, name) => Object.getOwnPropertyDescriptor(proto, name).get;
      const TypedArray = Object.getPrototypeOf(Uint8Array);
      const bufferLength = getter(ArrayBuffer.prototype, 'byteLength');
      const typedBuffer = getter(TypedArray.prototype, 'buffer');
      const typedOffset = getter(TypedArray.prototype, 'byteOffset');
      const typedLength = getter(TypedArray.prototype, 'byteLength');
      const viewBuffer = getter(DataView.prototype, 'buffer');
      const viewOffset = getter(DataView.prototype, 'byteOffset');
      const viewLength = getter(DataView.prototype, 'byteLength');
      const isBuffer = value => { try { bufferLength.call(value); return true; } catch { return false; } };
      const bytesOf = input => {
        if (isBuffer(input)) return new Uint8Array(input);
        for (const [bufferOf, offsetOf, lengthOf] of [[typedBuffer, typedOffset, typedLength], [viewBuffer, viewOffset, viewLength]]) {
          let backing;
          try { backing = bufferOf.call(input); } catch { continue; }
          if (!isBuffer(backing)) break;
          return new Uint8Array(backing, offsetOf.call(input), lengthOf.call(input));
        }
        throw new TypeError('Expected a BufferSource.');
      };
      const encode = input => {
        const bytes = bytesOf(input);
        if (bytes.byteLength > 65536) throw new TypeError('BufferSource is too large.');
        let raw = '';
        for (let index = 0; index < bytes.byteLength; index++) raw += String.fromCharCode(bytes[index]);
        return btoa(raw).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
      };
      const decode = value => {
        const raw = atob(value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4));
        const bytes = new Uint8Array(raw.length);
        for (let index = 0; index < raw.length; index++) bytes[index] = raw.charCodeAt(index);
        return bytes.buffer;
      };
      const emit = value => document.dispatchEvent(new CustomEvent('wsurf-webauthn-request',
        {detail: JSON.stringify(value)}));
      const randomID = () => {
        const random = new Uint8Array(16);
        crypto.getRandomValues(random);
        return Array.from(random, byte => byte.toString(16).padStart(2, '0')).join('');
      };
      const text = (value, label) => {
        if (typeof value !== 'string') throw new TypeError(label + ' must be a string.');
        return value;
      };
      const descriptors = list => {
        if (list === undefined) return [];
        if (!Array.isArray(list)) throw new TypeError('Credential descriptors must be a sequence.');
        return list.filter(item => item && item.type === 'public-key').map(item => {
          const descriptor = {id: encode(item.id)};
          if (Array.isArray(item.transports)) descriptor.transports = item.transports.map(String);
          return descriptor;
        });
      };

      function marshal(pk, operation) {
        if (!pk || typeof pk !== 'object') throw new TypeError('publicKey options are required.');
        const result = {challenge: encode(pk.challenge)};
        if (pk.timeout !== undefined) {
          if (!Number.isFinite(pk.timeout) || pk.timeout < 0) throw new TypeError('timeout must be a finite number.');
          result.timeout = pk.timeout;
        }
        const extensions = pk.extensions && typeof pk.extensions === 'object' ? pk.extensions : {};
        if (extensions.largeBlob && extensions.largeBlob.support === 'required') {
          throw fail('NotSupportedError', 'largeBlob is not supported.');
        }
        if (operation === 'create') {
          if (!pk.rp || typeof pk.rp !== 'object') throw new TypeError('rp is required.');
          if (!pk.user || typeof pk.user !== 'object') throw new TypeError('user is required.');
          result.rp = {name: text(pk.rp.name, 'rp.name')};
          if (pk.rp.id !== undefined) result.rp.id = text(pk.rp.id, 'rp.id');
          result.user = {id: encode(pk.user.id), name: text(pk.user.name, 'user.name'),
            displayName: text(pk.user.displayName, 'user.displayName')};
          if (!Array.isArray(pk.pubKeyCredParams)) throw new TypeError('pubKeyCredParams must be a sequence.');
          const params = pk.pubKeyCredParams.filter(item => item && item.type === 'public-key');
          if (pk.pubKeyCredParams.length > 0 && params.length === 0) {
            throw fail('NotSupportedError', 'No supported public-key credential type was requested.');
          }
          result.algorithms = params.map(item => {
            if (!Number.isInteger(item.alg)) throw new TypeError('alg must be an integer.');
            return item.alg;
          });
          result.excludeCredentials = descriptors(pk.excludeCredentials);
          const selection = pk.authenticatorSelection || {};
          result.authenticatorAttachment = selection.authenticatorAttachment;
          result.residentKey = selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged');
          result.userVerification = selection.userVerification || 'preferred';
          result.attestation = pk.attestation || 'none';
          result.credProps = extensions.credProps === true;
        } else {
          if (pk.rpId !== undefined) result.rpId = text(pk.rpId, 'rpId');
          result.allowCredentials = descriptors(pk.allowCredentials);
          result.userVerification = pk.userVerification || 'preferred';
        }
        return result;
      }

      function define(target, properties) {
        for (const [key, item] of Object.entries(properties)) {
          Object.defineProperty(target, key, {value: item, enumerable: true, configurable: true});
        }
        return target;
      }

      function credential(value) {
        const r = value.response;
        const clientDataJSON = decode(r.clientDataJSON), authenticatorData = decode(r.authenticatorData);
        const results = value.clientExtensionResults || {};
        let response, responseJSON;
        if (value.operation === 'create') {
          const attestationObject = decode(r.attestationObject), publicKey = decode(r.publicKey);
          const transports = ['internal'];
          response = define(Object.create(AuthenticatorAttestationResponse.prototype), {
            clientDataJSON, attestationObject,
            getTransports: () => transports.slice(),
            getPublicKeyAlgorithm: () => r.publicKeyAlgorithm,
            getPublicKey: () => publicKey.slice(0),
            getAuthenticatorData: () => authenticatorData.slice(0)
          });
          responseJSON = () => ({clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData,
            transports: transports.slice(), publicKey: r.publicKey, publicKeyAlgorithm: r.publicKeyAlgorithm,
            attestationObject: r.attestationObject});
        } else {
          response = define(Object.create(AuthenticatorAssertionResponse.prototype), {
            clientDataJSON, authenticatorData, signature: decode(r.signature),
            userHandle: r.userHandle ? decode(r.userHandle) : null
          });
          responseJSON = () => {
            const json = {clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature};
            if (r.userHandle) json.userHandle = r.userHandle;
            return json;
          };
        }
        Object.defineProperty(response, 'toJSON', {value: responseJSON, configurable: true});
        const object = define(Object.create(PublicKeyCredential.prototype), {
          id: value.id, rawId: decode(value.rawId), type: 'public-key',
          authenticatorAttachment: 'platform', response,
          getClientExtensionResults: () => JSON.parse(JSON.stringify(results))
        });
        Object.defineProperty(object, 'toJSON', {
          value: () => ({id: value.id, rawId: value.rawId, type: 'public-key', authenticatorAttachment: 'platform',
            response: responseJSON(), clientExtensionResults: JSON.parse(JSON.stringify(results))}),
          configurable: true
        });
        return object;
      }

      function settle(id, error, result) {
        const pending = requests.get(id);
        if (!pending) return;
        requests.delete(id);
        clearTimeout(pending.timer);
        pending.signal?.removeEventListener('abort', pending.abort);
        if (error) {
          pending.reject(error instanceof DOMException || error instanceof Error ? error : fail(error.name, error.message));
        } else { try { pending.resolve(credential(result)); } catch (failure) { pending.reject(failure); } }
      }

      const queryHandlers = new Map();
      document.addEventListener('wsurf-webauthn-result', event => {
        if (typeof event.detail !== 'string' || event.detail.length > MAX_TEXT) return;
        let value; try { value = JSON.parse(event.detail); } catch { return; }
        if (!value || typeof value.id !== 'string') return;
        const query = queryHandlers.get(value.id);
        if (query) { queryHandlers.delete(value.id); query(value.result ?? null); return; }
        settle(value.id, value.error, value.result);
      });
      // The provider routing for this document is native's: delivered as an event by the isolated relay, which holds the
      // announcement of the document-start script native installed (and of every later change). It is a hint, not an
      // authority: the page can forge it, and native refuses any manager request it does not itself serve. `pending` is a
      // document restored from the back/forward cache, whose route may predate a provider change: native re-announces it
      // once. Until that answer, `known` (the last explicit answer) decides: a previously-manager document still prepares
      // manager requests, which native validates; anything else is refused briefly (cached legacy calls are not supported
      // before revalidation, and are never queued or read).
      let route = null, known = null;
      document.addEventListener('wsurf-webauthn-route', event => {
        if (event.detail === 'legacy' || event.detail === 'manager') route = known = event.detail;
        else if (event.detail === 'pending') route = 'pending';
      });
      document.dispatchEvent(new CustomEvent('wsurf-webauthn-route-request'));

      // The provider is decided by native before any manager-only processing. Legacy hands the engine the caller's own
      // arguments in the caller's own turn: before any read of them, with no marshalling, no manager restriction and no
      // manager error. Nothing manager-owned ever falls back to the engine.
      function intercept(operation, options) {
        if (route === 'legacy') return originals[operation](options);
        // Restore window (`pending`): native has not yet said which provider owns this restored document. A document that was
        // last known to be the encrypted provider's keeps preparing manager requests (never the engine): its buffers are
        // snapshotted in this turn, the relay holds the request until the native frame proof, and native refuses it unless it
        // still serves the document. A legacy or never-routed document is refused for this window, before any read of the
        // caller's options: a call already delegated to the engine cannot be recalled. Nothing is queued or retried.
        if (route === 'pending' && known !== 'manager') return Promise.reject(fail('NotAllowedError', 'The request is not allowed by the user agent or the platform.'));
        let publicKey;
        try { publicKey = options && options.publicKey; } catch (error) { return Promise.reject(error); }
        if (!publicKey) return originals[operation](options);
        // Never announced is the encrypted provider's refusal, not an implicit engine fallback.
        if (route !== 'manager' && route !== 'pending') return Promise.reject(fail('NotAllowedError', 'The request is not allowed by the user agent or the platform.'));
        return manage(operation, options, publicKey);
      }

      // Every property of the caller's options this request needs is read exactly once, here, before anything can suspend;
      // the BufferSources are copied by `marshal` in the same turn.
      function manage(operation, options, publicKey) {
        return new Promise((resolve, reject) => {
          let mediation, signal, mixed;
          try {
            mediation = options.mediation;
            signal = options.signal;
            mixed = ['password', 'federated', 'identity', 'otp'].some(key => options[key] !== undefined);
          } catch (error) { reject(error); return; }
          const conditional = operation === 'get' && mediation === 'conditional';
          try {
            if (mixed) throw new TypeError('A public-key request cannot be combined with other credential types.');
            if (signal !== undefined && !(signal instanceof AbortSignal)) throw new TypeError('signal must be an AbortSignal.');
            if (operation === 'create' && mediation === 'conditional') {
              throw fail('NotSupportedError', 'Conditional registration is not supported.');
            }
            if (mediation === 'silent') throw fail('NotAllowedError', 'Silent public-key requests are not allowed.');
          } catch (error) { reject(error); return; }
          if (signal?.aborted) { reject(signal.reason ?? fail('AbortError', 'The request was aborted.')); return; }
          let marshalled;
          try { marshalled = marshal(publicKey, operation); } catch (error) { reject(error); return; }

          // A foreground request supersedes a background conditional one; two foreground requests cannot overlap.
          for (const [otherID, other] of [...requests]) {
            if (other.conditional && !conditional) {
              emit({action: 'cancel', id: otherID});
              settle(otherID, fail('AbortError', 'A new credential request replaced the conditional request.'));
            } else if (!other.conditional || conditional) {
              reject(fail('NotAllowedError', 'Another credential request is already pending.'));
              return;
            }
          }
          const id = randomID();
          // WebAuthn L3: a conditional get has an infinite lifetime timer. It ends only by abort, navigation or a native
          // answer. Every other request is bounded (10 s to 10 min, 5 min by default), and native keeps its own expiry.
          let timer = null;
          if (conditional) {
            delete marshalled.timeout;
          } else {
            const requested = marshalled.timeout === undefined ? 300000 : marshalled.timeout;
            const timeout = Math.min(600000, Math.max(10000, requested));
            marshalled.timeout = timeout;
            timer = setTimeout(() => {
              emit({action: 'cancel', id});
              settle(id, fail('NotAllowedError', 'The credential request timed out.'));
            }, timeout);
          }
          const abort = () => {
            emit({action: 'cancel', id});
            settle(id, signal.reason ?? fail('AbortError', 'The request was aborted.'));
          };
          requests.set(id, {resolve, reject, timer, signal, abort, conditional, operation});
          signal?.addEventListener('abort', abort, {once: true});
          const body = {action: 'request', id, operation, options: marshalled, mediation: mediation || 'optional'};
          try {
            if (JSON.stringify(body).length > MAX_TEXT) throw new TypeError('The request is too large.');
            emit(body);
          } catch (error) { emit({action: 'cancel', id}); settle(id, error); }
        });
      }

      for (const operation of ['create', 'get']) {
        const wrapper = {[operation](options) { return intercept(operation, options); }}[operation];
        Object.defineProperty(proto, operation, {value: wrapper, writable: true, enumerable: true, configurable: true});
      }
      Object.defineProperty(container, '__wsurfWebAuthn', {value: true});

      // Capability answers come from the native side so they track the selected provider and the Mac's real ability to
      // verify the user. Native names the provider explicitly: 'legacy' (the engine keeps its own behaviour) or 'manager'
      // (enabled only for a live document of the page's own profile). Anything else, including no answer, is a refusal.
      const queryCapabilities = () => new Promise(resolve => {
        const id = randomID();
        const timer = setTimeout(() => { queryHandlers.delete(id); emit({action: 'cancel', id}); resolve(null); }, 2000);
        queryHandlers.set(id, value => { clearTimeout(timer); resolve(value); });
        emit({action: 'request', id, operation: 'capabilities'});
      });
      const defineStatic = (name, ours, fallback) => {
        const original = typeof PublicKeyCredential[name] === 'function' ? PublicKeyCredential[name].bind(PublicKeyCredential) : null;
        const wrapper = {[name]: async function () {
          const state = await queryCapabilities();
          // The engine's own answer only for an explicit native "legacy" decision. Manager unavailable, stale or unknown
          // is a truthful "unavailable", never the other provider's answer.
          if (state && state.provider === 'legacy') return original ? original() : fallback;
          if (state && state.provider === 'manager' && state.enabled === true) return ours(state);
          return fallback;
        }}[name];
        Object.defineProperty(PublicKeyCredential, name, {value: wrapper, writable: true, configurable: true});
      };
      defineStatic('isConditionalMediationAvailable', () => true, false);
      defineStatic('isUserVerifyingPlatformAuthenticatorAvailable', state => state.canVerifyUser === true, false);
      defineStatic('getClientCapabilities', state => ({
        conditionalGet: true, conditionalCreate: false, hybridTransport: false,
        passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: state.canVerifyUser === true,
        relatedOrigins: false, signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false
      }), {});
      // Signal APIs ask the authenticator to update or hide credentials it holds. This authenticator does not implement
      // them, and forwarding them to the engine would address the system store, not the encrypted manager (a credential
      // ID imported from another provider could be altered at its source). So in manager mode they reject honestly; with
      // the legacy provider the engine's own behaviour is untouched. An engine that lacks a signal method keeps lacking it.
      for (const name of ['signalUnknownCredential', 'signalAllAcceptedCredentials', 'signalCurrentUserDetails']) {
        if (typeof PublicKeyCredential[name] !== 'function') continue;
        const original = PublicKeyCredential[name].bind(PublicKeyCredential);
        const wrapper = {[name]: async function (...args) {
          const state = await queryCapabilities();
          // Only an explicit native "legacy" decision reaches the engine. No answer, a stale or unknown page and the
          // manager itself all reject: an unavailable bridge is never taken to mean the legacy provider.
          if (!state || state.provider !== 'legacy') throw fail('NotSupportedError', 'This authenticator does not support credential signals.');
          return original(...args);
        }}[name];
        Object.defineProperty(PublicKeyCredential, name, {value: wrapper, writable: true, configurable: true});
      }
      addEventListener('pagehide', () => {
        for (const id of [...requests.keys()]) {
          emit({action: 'cancel', id});
          settle(id, fail('AbortError', 'The document navigated away.'));
        }
      });
    })();
    """#
}
