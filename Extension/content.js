// Shows an IDM-style "Bu videoyu indir" button over videos the pointer is on.
(() => {
  if (window.__idmMacLoaded) return;
  window.__idmMacLoaded = true;

  let enabled = true;
  chrome.storage.local.get({ videoButton: true }, (s) => (enabled = s.videoButton));
  chrome.storage.onChanged.addListener((c) => {
    if (c.videoButton) enabled = c.videoButton.newValue;
    if (!enabled) hide();
  });

  // The button lives in a shadow root so page CSS can't restyle it.
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;z-index:2147483647;top:0;left:0;display:none;";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `
    <style>
      button {
        all: initial; cursor: pointer; display: flex; align-items: center; gap: 6px;
        font: 600 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        color: #fff; background: rgba(37, 99, 235, 0.95); padding: 7px 12px; border-radius: 8px;
        box-shadow: 0 2px 10px rgba(0,0,0,.35);
      }
      button:hover { background: #1d4ed8; }
      button.done { background: #16a34a; }
      button.err { background: #dc2626; }
      svg { width: 15px; height: 15px; fill: currentColor; }
    </style>
    <button type="button"><svg viewBox="0 0 24 24"><path d="M11 3h2v10.17l3.59-3.58L18 11l-6 6-6-6 1.41-1.41L11 13.17zM5 19h14v2H5z"/></svg><span>Bu videoyu indir</span></button>`;
  const btn = root.querySelector("button");
  const label = root.querySelector("span");

  let current = null;
  let hideTimer = null;
  let busy = false;

  function attach() {
    if (!host.isConnected) (document.fullscreenElement || document.documentElement).appendChild(host);
  }

  function hide() {
    host.style.display = "none";
    current = null;
  }

  function place(v) {
    const r = v.getBoundingClientRect();
    if (r.width < 200 || r.height < 110 || r.bottom < 0 || r.top > innerHeight) return hide();
    attach();
    host.style.display = "block";
    const w = host.offsetWidth || 160;
    host.style.top = Math.max(4, r.top + 12) + "px";
    host.style.left = Math.max(4, Math.min(innerWidth - w - 8, r.right - w - 12)) + "px";
  }

  function videoAt(x, y) {
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom && r.width >= 200 && r.height >= 110) return v;
    }
    return null;
  }

  let raf = 0;
  document.addEventListener(
    "mousemove",
    (e) => {
      if (!enabled || raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        if (e.composedPath().includes(host)) {
          clearTimeout(hideTimer);
          return;
        }
        const v = videoAt(e.clientX, e.clientY);
        if (v) {
          clearTimeout(hideTimer);
          if (v !== current && !busy) resetLabel();
          current = v;
          place(v);
        } else if (current && !busy) {
          clearTimeout(hideTimer);
          hideTimer = setTimeout(hide, 1200);
        }
      });
    },
    { passive: true, capture: true }
  );
  addEventListener("scroll", () => current && place(current), { passive: true, capture: true });
  document.addEventListener("fullscreenchange", () => {
    host.remove();
    if (current) place(current);
  });

  function resetLabel() {
    btn.className = "";
    label.textContent = "Bu videoyu indir";
  }

  // Which URL identifies this video for yt-dlp. Feeds and timelines contain many videos,
  // so look for the post/item link around the player instead of using the page address.
  function pageUrlFor(v) {
    const h = location.hostname;
    const abs = (a) => (a ? new URL(a.getAttribute("href"), location.href).href : null);
    if (/(^|\.)(x|twitter)\.com$/.test(h)) {
      const art = v.closest("article");
      const a = art && [...art.querySelectorAll('a[href*="/status/"]')].find((x) => x.querySelector("time"));
      return abs(a) || location.href;
    }
    if (/(^|\.)youtube\.com$/.test(h)) {
      if (/^\/(watch|shorts\/|live\/|embed\/)/.test(location.pathname)) return location.href;
      const card = v.closest("ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-reel-item-renderer");
      return abs(card && card.querySelector("a#thumbnail, a[href*='/watch'], a[href*='/shorts/']")) || location.href;
    }
    if (/(^|\.)(instagram|facebook|reddit)\.com$/.test(h)) {
      const box = v.closest("article, [role='article'], shreddit-post");
      const a = box && box.querySelector('a[href*="/p/"], a[href*="/reel/"], a[href*="/videos/"], a[href*="/comments/"]');
      return abs(a) || location.href;
    }
    return location.href;
  }

  btn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!current || busy) return;
    busy = true;
    label.textContent = "Gönderiliyor…";
    const src = current.currentSrc || current.src || "";
    chrome.runtime.sendMessage(
      {
        type: "video",
        pageUrl: pageUrlFor(current),
        mediaUrl: src.startsWith("blob:") ? "" : src,
        title: document.title,
        referrer: window === top ? "" : document.referrer,
      },
      (res) => {
        void chrome.runtime.lastError;
        busy = false;
        if (res && res.ok) {
          btn.className = "done";
          label.textContent = "MDM'ye gönderildi";
        } else {
          btn.className = "err";
          label.textContent = "Uygulama açılamadı";
        }
        setTimeout(resetLabel, 3000);
      }
    );
  });
})();
