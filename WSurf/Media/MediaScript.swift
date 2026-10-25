// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// The script every frame runs: it reports what plays, drives the transport,
/// and answers a Picture in Picture request with a gesture the app can supply.
enum MediaScript {
    nonisolated static let source = """
    (function () {
      if (window.__wsurfMedia) { return; }
      window.__wsurfMedia = true;
      const post = function (message) {
        try { globalThis.__wsurfSend?.('wsurfpip', message); } catch (e) {}
      };
      let video = null;
      let gestureAttempts = 0;
      let muteAll = false;
      // Each document names itself, so the app can tell the frames of one page apart and count the page as playing while any
      // of them does: a player in an iframe, of another site too. The same script reports the same way wherever it runs.
      const isTop = window === window.top;
      const frameKey = Math.random().toString(36).slice(2, 12) + Date.now().toString(36);
      let scanTimer = null;
      let pendingScan = null;
      let pageHidden = false;
      function media() {
        return Array.prototype.slice.call(document.querySelectorAll('video, audio'));
      }
      function primary() {
        if (video && !video.isConnected) { video = null; }
        return video || media()[0] || null;
      }
      // What the app silences it marks, so a tab it muted still counts as playing, and unmuting gives back only what it took:
      // a video the page muted itself (a quiet background loop) stays muted.
      function silence(m) {
        if (!m.muted) { m.__wsurfMuted = true; m.muted = true; }
      }
      function restore(m) {
        if (m.__wsurfMuted) { m.__wsurfMuted = false; m.muted = false; }
      }
      // The state lives in each frame, and a new document starts without it, so a frame passes it down to its frames and
      // a new frame asks its parent (`wsurf-mute?`).
      function setMuteAll(on) {
        muteAll = on;
        media().forEach(on ? silence : restore);
        Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (f) {
          try { f.contentWindow.postMessage('wsurf-mute:' + (on ? 1 : 0), '*'); } catch (e) {}
        });
      }
      function audible(m) {
        if (m.paused || m.ended) { return false; }
        if (m.muted ? m.__wsurfMuted !== true : m.volume <= 0) { return false; }
        var tracks = m.audioTracks;
        if (tracks && m.readyState >= 2 && tracks.length === 0) { return false; }
        return true;
      }
      function anyPlaying() {
        return media().some(audible);
      }
      // The page's own document says `audio:`, a frame `frameaudio:<key>:`. A frame starts out quiet: no word for a frame
      // that has nothing to play, which most of them have not.
      let lastAudio = isTop ? null : false;
      function audioMessage(playing) {
        return (isTop ? 'audio:' : 'frameaudio:' + frameKey + ':') + (playing ? 1 : 0);
      }
      function reportAudio() {
        // A frame that is going (`pagehide`) has said its sound is over; its player's last events say nothing new.
        if (pageHidden && !isTop) { return; }
        const playing = anyPlaying();
        if (playing === lastAudio) { return; }
        lastAudio = playing;
        post(audioMessage(playing));
      }
      let lastVideo = null;
      function reportVideo() {
        const has = media().some(function (m) { return m.videoWidth > 0; });
        if (has === lastVideo) { return; }
        lastVideo = has;
        post('video:' + (has ? 1 : 0));
      }
      let lastMeta = '';
      function posterImage() {
        if (window !== window.top) { return ''; }
        var m = primary();
        var found = (m && m.poster) || '';
        if (!found) {
          var sources = ['meta[property="og:image"]', 'meta[name="twitter:image"]', 'link[rel="image_src"]'];
          for (var i = 0; i < sources.length && !found; i += 1) {
            var node = document.querySelector(sources[i]);
            if (node) { found = node.content || node.href || ''; }
          }
        }
        if (!found) { return ''; }
        try { return new URL(found, location.href).href; } catch (e) { return ''; }
      }
      function sendMeta() {
        try {
          var m = navigator.mediaSession ? navigator.mediaSession.metadata : null;
          var art = '';
          if (m && m.artwork && m.artwork.length) {
            art = m.artwork[m.artwork.length - 1].src || '';
          }
          var guessed = !art;
          if (guessed) { art = posterImage(); }
          if (!m && !art) { return; }
          var payload = JSON.stringify({
            t: (m && m.title) || '',
            a: (m && m.artist) || '',
            al: (m && m.album) || '',
            art: art,
            g: guessed ? '1' : '0'
          });
          if (payload === lastMeta) { return; }
          lastMeta = payload;
          post('meta:' + payload);
        } catch (e) {}
      }
      function stageElement() {
        const media = primary();
        if (media) { return media; }
        let best = null;
        let bestArea = 40000;
        Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (frame) {
          const box = frame.getBoundingClientRect();
          const area = box.width * box.height;
          if (area > bestArea) { bestArea = area; best = frame; }
        });
        return best;
      }
      let lastRect = '';
      function reportRect() {
        if (window !== window.top) { return; }
        const stage = stageElement();
        let payload = '';
        if (stage) {
          const box = stage.getBoundingClientRect();
          if (box.width > 0 && box.height > 0) {
            payload = JSON.stringify({
              x: Math.round(box.left),
              y: Math.round(box.top),
              w: Math.round(box.width),
              h: Math.round(box.height)
            });
          }
        }
        if (payload === lastRect) { return; }
        lastRect = payload;
        post('rect:' + payload);
      }
      function forgetReportedRect() { lastRect = ''; }
      function revealStage() {
        forgetReportedRect();
        if (window !== window.top) { return; }
        const stage = stageElement();
        if (!stage) { return; }
        const box = stage.getBoundingClientRect();
        const outside = box.top < 0 || box.left < 0 ||
          box.bottom > window.innerHeight || box.right > window.innerWidth;
        if (outside) {
          try { stage.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (e) {}
        }
        reportRect();
      }
      const MAX_REAL_DURATION = 1e7;
      function realDuration(m) {
        const raw = m.duration;
        return (isFinite(raw) && raw > 0 && raw < MAX_REAL_DURATION) ? raw : 0;
      }
      let durationRises = 0;
      let lastDuration = -1;
      function forgetDuration() { durationRises = 0; lastDuration = -1; }
      function stretches(m) {
        const now = m.duration;
        if (lastDuration >= 0) {
          if (now > lastDuration + 0.2) {
            durationRises = Math.min(durationRises + 1, 3);
          } else if (Math.abs(now - lastDuration) <= 0.2) {
            durationRises = Math.max(durationRises - 1, 0);
          } else {
            durationRises = 0;
          }
        }
        lastDuration = now;
        return durationRises >= 2;
      }
      function isLive(m) {
        const raw = m.duration;
        if (isNaN(raw) || raw === 0) { return false; }
        if (realDuration(m) === 0) { return true; }
        return stretches(m);
      }
      function sendState() {
        const video = primary();
        if (!video) { return; }
        if (!video.paused && !video.ended) { lastPlayedAt = performance.now(); }
        post('state:' + JSON.stringify({
          t: video.currentTime || 0,
          d: realDuration(video),
          l: isLive(video) ? 1 : 0,
          p: video.paused ? 0 : 1,
          v: video.volume,
          m: video.muted ? 1 : 0,
          w: video.videoWidth || 0
        }));
      }
      function clamp(value, low, high) { return Math.max(low, Math.min(high, value)); }
      function command(data) {
        const arg = parseFloat(data.slice(data.indexOf(':') + 1));
        if (data === 'wsurf-reveal') {
          revealStage();
          return;
        }
        if (data === 'wsurf-rect') {
          forgetReportedRect();
          reportRect();
          return;
        }
        if (data === 'wsurf-resend') {
          lastMeta = '';
          lastAudio = null;
          lastVideo = null;
          sendMeta();
          sendState();
          reportAudio();
          reportVideo();
          updatePolling();
          Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (f) {
            try { f.contentWindow.postMessage('wsurf-resend', '*'); } catch (e) {}
          });
          return;
        }
        // Before the player is looked for: a page with nothing to play yet still has to start muted when it has some.
        if (data.indexOf('wsurf-mute:') === 0) {
          setMuteAll(arg === 1);
          if (primary()) { sendState(); }
          return;
        }
        const video = primary();
        if (!video) { return; }
        const duration = realDuration(video);
        if (data === 'wsurf-play') { const p = video.play(); if (p) { p.catch(function () {}); } }
        else if (data === 'wsurf-pause') { video.pause(); }
        else if (data.indexOf('wsurf-seek:') === 0) {
          video.currentTime = clamp(video.currentTime + arg, 0, duration || video.currentTime + arg);
        } else if (data.indexOf('wsurf-seekto:') === 0) {
          if (duration) { video.currentTime = clamp(duration * arg, 0, duration); }
        } else if (data.indexOf('wsurf-seekabs:') === 0) {
          video.currentTime = clamp(arg, 0, duration || arg);
        } else if (data.indexOf('wsurf-volume:') === 0) {
          video.muted = arg <= 0;
          video.volume = clamp(arg, 0, 1);
        }
        sendState();
      }
      let armedGesture = null;
      let armedGestureExpiry = null;
      let armedAt = 0;
      let lastPlayedAt = 0;
      function playedRecently() {
        return lastPlayedAt > 0 && performance.now() - lastPlayedAt < 4000;
      }
      function gesturePoint() {
        if (window !== window.top) { return null; }
        const box = video.getBoundingClientRect();
        const candidates = [
          [box.left + box.width / 2, box.top + box.height / 2],
          [box.left + 10, box.top + 10],
          [box.left + box.width / 2, Math.max(box.top - 12, 6)],
          [10, 10],
          [window.innerWidth / 2, 8]
        ];
        for (const pair of candidates) {
          const x = pair[0];
          const y = pair[1];
          if (x < 1 || y < 1 || x >= window.innerWidth - 1 || y >= window.innerHeight - 1) { continue; }
          const found = document.elementFromPoint(x, y);
          if (found && found.tagName !== 'IFRAME' && found.tagName !== 'EMBED' && found.tagName !== 'OBJECT') {
            return { x: Math.round(x), y: Math.round(y) };
          }
        }
        return null;
      }
      const swallowed = ['pointerdown', 'pointerup', 'mousedown', 'mouseup'];
      function isOurGesture() {
        return performance.now() - armedAt < 2000;
      }
      function swallow(event) {
        if (isOurGesture()) { event.stopPropagation(); }
      }
      function disarmGesture() {
        if (armedGesture) {
          document.removeEventListener('click', armedGesture, true);
          swallowed.forEach(function (name) {
            document.removeEventListener(name, swallow, true);
          });
          armedGesture = null;
        }
        if (armedGestureExpiry) {
          clearTimeout(armedGestureExpiry);
          armedGestureExpiry = null;
        }
      }
      function armGesture(onlyWhilePlaying) {
        if (!video || video.webkitPresentationMode === 'picture-in-picture') { return; }
        if (onlyWhilePlaying && (video.ended || (video.paused && !playedRecently()))) {
          post('diag:not-playing');
          return;
        }
        if (!video.videoWidth || typeof video.webkitSetPresentationMode !== 'function') {
          post('diag:no-video');
          return;
        }
        if (gestureAttempts >= 4) { post('diag:gave-up'); gestureAttempts = 0; return; }
        gestureAttempts += 1;
        disarmGesture();
        armedAt = performance.now();
        armedGesture = function (event) {
          const ours = isOurGesture();
          disarmGesture();
          if (ours && event) {
            event.stopPropagation();
            event.preventDefault();
          }
          const wasPlaying = !video.paused || playedRecently();
          try {
            allowPiP(video);
            video.webkitSetPresentationMode('picture-in-picture');
          } catch (err) {
            post('diag:error ' + err.message);
          }
          setTimeout(function () {
            if (wasPlaying && video && video.paused) {
              const p = video.play();
              if (p) { p.catch(function () {}); }
            }
            if (video && video.webkitPresentationMode !== 'picture-in-picture') {
              armGesture(onlyWhilePlaying);
            }
            else { gestureAttempts = 0; }
          }, 700);
        };
        document.addEventListener('click', armedGesture, true);
        swallowed.forEach(function (name) {
          document.addEventListener(name, swallow, true);
        });
        armedGestureExpiry = setTimeout(function () {
          disarmGesture();
          gestureAttempts = 0;
          post('diag:gesture-expired');
        }, 10000);
        const target = gesturePoint();
        if (target) { post('pipat:' + target.x + ',' + target.y); }
        post('diag:need-gesture');
      }
      window.addEventListener('message', function (event) {
        const data = event.data;
        if (typeof data !== 'string' || data.indexOf('wsurf-') !== 0) { return; }
        if (data === 'wsurf-mute?') {
          if (muteAll && event.source) { try { event.source.postMessage('wsurf-mute:1', '*'); } catch (e) {} }
          return;
        }
        if (event.source !== window && event.source !== window.parent) { return; }
        if (data === 'wsurf-pip' || data === 'wsurf-pip-auto') {
          gestureAttempts = 0;
          if (video && video.videoWidth) { revealStage(); }
          armGesture(data === 'wsurf-pip-auto');
          return;
        }
        if (data === 'wsurf-pip-exit') {
          disarmGesture();
          gestureAttempts = 0;
          if (video) { try { video.webkitSetPresentationMode('inline'); } catch (e) {} }
          return;
        }
        command(data);
      });
      function bind(found, asPrimary) {
        if (!found) { return; }
        if (asPrimary) { video = found; }
        if (!found.__wsurfBound) {
          found.__wsurfBound = true;
          if (muteAll) { silence(found); }
          ['play', 'pause', 'timeupdate', 'volumechange', 'durationchange', 'seeked', 'ended', 'loadedmetadata', 'emptied', 'resize']
            .forEach(function (name) { found.addEventListener(name, mediaChanged); });
          ['play', 'pause', 'ended', 'emptied', 'volumechange']
            .forEach(function (name) { found.addEventListener(name, reportAudio); });
          found.addEventListener('volumechange', function () {
            if (muteAll && !found.muted) {
              muteAll = false;
              post('tabunmuted');
            }
          });
          found.addEventListener('ended', function () { post('ended'); });
          found.addEventListener('webkitpresentationmodechanged', function () {
            post(found.webkitPresentationMode);
          });
        }
        sendState();
        reportAudio();
      }
      function mediaChanged(event) {
        sendState();
        if (!pageHidden && !document.hidden) { sendMeta(); }
        if (['loadedmetadata', 'emptied', 'resize'].includes(event.type)) { reportVideo(); }
        if (['play', 'pause', 'ended', 'emptied'].includes(event.type)) { updatePolling(); }
      }
      function allowPiP(v) {
        if (v.disablePictureInPicture) { v.disablePictureInPicture = false; }
        if (v.hasAttribute('disablepictureinpicture')) {
          v.removeAttribute('disablepictureinpicture');
        }
      }
      function mainVideo(visible) {
        let best = null;
        let bestScore = 0;
        Array.prototype.forEach.call(document.querySelectorAll('video'), function (v) {
          let score = 1;
          if (visible) {
            const box = v.getBoundingClientRect();
            score = Math.max(box.width * box.height, 1);
          }
          if (!v.paused && !v.ended) { score *= 4; }
          if (score > bestScore) { bestScore = score; best = v; }
        });
        return best;
      }
      // A frame that is removed, or shows another page, may not get to say its sound is over, so a document that sees one of its
      // frames go says so, and the app asks the frames that remain again (`wsurf-resend`).
      let frameCount = 0;
      function checkFrames() {
        const found = document.querySelectorAll('iframe').length;
        if (found < frameCount) { post('frames:moved'); }
        frameCount = found;
      }
      function scan() {
        if (pageHidden) { return; }
        checkFrames();
        const visible = !document.hidden;
        const main = mainVideo(visible);
        if (main && main !== video) {
          forgetDuration();
          bind(main, true);
        }
        media().forEach(function (m) {
          if (m.tagName === 'VIDEO') { allowPiP(m); }
          if (!m.__wsurfBound) { bind(m, false); }
        });
        if (visible) { sendMeta(); reportRect(); }
        reportAudio();
        reportVideo();
        updatePolling();
      }
      // Poll only visible playback; mutations and geometry events cover idle pages.
      function updatePolling() {
        const needsPolling = !pageHidden && !document.hidden && media().some(function (m) {
          return !m.paused && !m.ended;
        });
        if (needsPolling && scanTimer === null) { scanTimer = setInterval(scan, 500); }
        else if (!needsPolling && scanTimer !== null) {
          clearInterval(scanTimer);
          scanTimer = null;
        }
      }
      function scheduleScan(includeHidden) {
        if (pageHidden || (document.hidden && includeHidden !== true) || pendingScan !== null) { return; }
        pendingScan = setTimeout(function () {
          pendingScan = null;
          scan();
        }, 80);
      }
      const relevant = 'video,audio,iframe,meta,link,title';
      function containsRelevant(node, selector) {
        return node.nodeType === 1 && (node.matches(selector) || node.querySelector(selector) !== null);
      }
      const changes = new MutationObserver(function (records) {
        const selector = document.hidden ? 'video,audio,iframe' : relevant;
        const needsScan = records.some(function (record) {
          if (record.type === 'attributes') { return record.target.matches(selector); }
          if (record.target.nodeType === 1 && record.target.matches('title')) { return !document.hidden; }
          if (record.type === 'characterData') { return !document.hidden && record.target.parentElement?.matches('title'); }
          if (record.type === 'childList' && !document.hidden && video && video.isConnected) { return true; }
          return Array.from(record.addedNodes).some(node => containsRelevant(node, selector)) ||
            Array.from(record.removedNodes).some(node => containsRelevant(node, selector));
        });
        if (needsScan) { scheduleScan(true); }
      });
      function observeChanges() {
        changes.observe(document.documentElement || document, {
          childList: true, subtree: true, characterData: true, attributes: true,
          attributeFilter: ['src', 'poster', 'content', 'href', 'rel', 'style', 'class', 'disablepictureinpicture']
        });
      }
      addEventListener('load', scheduleScan, { once: true });
      document.addEventListener('scroll', scheduleScan, { capture: true, passive: true });
      window.addEventListener('resize', scheduleScan);
      document.addEventListener('load', function (event) {
        if (event.target && event.target.tagName === 'IFRAME') { post('frames:moved'); }
      }, true);
      document.addEventListener('visibilitychange', function () {
        updatePolling();
        if (!document.hidden) { scheduleScan(); }
        else {
          if (pendingScan !== null) { clearTimeout(pendingScan); pendingScan = null; }
          scan();
        }
      });
      window.addEventListener('pagehide', function () {
        pageHidden = true;
        // A frame that goes (removed, or showing another page) says its sound is over; the page may carry on without it.
        if (!isTop && lastAudio === true) { lastAudio = false; post(audioMessage(false)); }
        changes.disconnect();
        updatePolling();
        if (pendingScan !== null) { clearTimeout(pendingScan); pendingScan = null; }
      });
      window.addEventListener('pageshow', function () {
        if (!pageHidden) { return; }
        pageHidden = false;
        observeChanges();
        scheduleScan();
      });
      // A player the page starts while the app has it muted is silenced before the first sound, not at the next scan.
      document.addEventListener('play', function (event) {
        if (muteAll && event.target && event.target.muted === false) { silence(event.target); }
      }, true);
      if (isTop) { post('hello'); }
      else { try { window.parent.postMessage('wsurf-mute?', '*'); } catch (e) {} }
      scan();
      observeChanges();
    })();
    """
}
