// Shows an IDM-style "Bu videoyu indir" button over videos the pointer is on; hovering it
// lists the qualities and audio languages so a download can start without the app window.
(() => {
  if (window.__idmMacLoaded) return;
  window.__idmMacLoaded = true;

  // Magnet links go to MDM's torrent engine instead of whatever app the system would open.
  document.addEventListener(
    "click",
    (e) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = e.composedPath().find((el) => el.tagName === "A" && el.href);
      if (!a || !/^magnet:/i.test(a.href)) return;
      e.preventDefault();
      e.stopPropagation();
      const href = a.href;
      chrome.runtime.sendMessage({ type: "url", url: href }, (res) => {
        void chrome.runtime.lastError;
        if (!res || !res.ok) location.href = href;
      });
    },
    true
  );

  // "Sayfadaki tüm linkleri indir": the toolbar menu asks the page for its links and media sources.
  if (window === top) {
    chrome.runtime.onMessage.addListener((m, _sender, reply) => {
      if (!m || m.type !== "collectLinks") return;
      const seen = new Set();
      const items = [];
      const add = (url, text) => {
        if (!url || !/^https?:/i.test(url) || seen.has(url)) return;
        seen.add(url);
        items.push({ url, text: (text || "").replace(/\s+/g, " ").trim().slice(0, 200) });
      };
      for (const a of document.querySelectorAll("a[href]")) add(a.href, a.textContent || a.title);
      for (const el of document.querySelectorAll("img[src], video[src], audio[src], source[src]")) {
        add(el.currentSrc || el.src, el.alt || el.title || "");
      }
      reply({ pageUrl: location.href, title: document.title, items: items.slice(0, m.max || 2000) });
    });
  }

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
        color: #fff; background: rgba(37, 99, 235, 0.72); padding: 7px 12px; border-radius: 12px;
        border: 1px solid rgba(255,255,255,.28);
        -webkit-backdrop-filter: blur(18px) saturate(180%); backdrop-filter: blur(18px) saturate(180%);
        box-shadow: 0 4px 16px rgba(0,0,0,.28), inset 0 1px 0 rgba(255,255,255,.3);
      }
      button:hover { background: rgba(29, 78, 216, 0.82); }
      button.done { background: rgba(22, 163, 74, 0.8); }
      button.err { background: rgba(220, 38, 38, 0.8); }
      @media (prefers-reduced-transparency: reduce) {
        button { background: #2563eb; -webkit-backdrop-filter: none; backdrop-filter: none; }
        .menu { background: #18181b; -webkit-backdrop-filter: none; backdrop-filter: none; }
      }
      svg { width: 15px; height: 15px; fill: currentColor; }
      .wrap { position: relative; }
      .menu {
        position: absolute; right: 0; top: calc(100% + 6px); min-width: 250px; max-height: 60vh; overflow-y: auto;
        font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #f4f4f5;
        background: rgba(30, 30, 36, 0.62); border-radius: 14px; padding: 6px;
        border: 1px solid rgba(255,255,255,.18);
        -webkit-backdrop-filter: blur(24px) saturate(180%); backdrop-filter: blur(24px) saturate(180%);
        box-shadow: 0 10px 32px rgba(0,0,0,.4), inset 0 1px 0 rgba(255,255,255,.18); box-sizing: border-box;
      }
      .menu[hidden] { display: none; }
      .head { padding: 6px 10px 3px; color: #a1a1aa; font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; }
      .item { display: flex; justify-content: space-between; gap: 18px; padding: 7px 10px; border-radius: 6px; cursor: pointer; }
      .item:hover { background: rgba(37, 99, 235, 0.85); }
      .item .d { color: #a1a1aa; }
      .item:hover .d { color: #dbeafe; }
      .note { padding: 8px 10px; color: #a1a1aa; }
      select {
        margin: 2px 10px 6px; width: calc(100% - 20px); font: 13px -apple-system, sans-serif; color: #f4f4f5;
        background: rgba(255,255,255,.14); border: 0; border-radius: 8px; padding: 5px 6px;
      }
    </style>
    <div class="wrap">
      <button type="button"><svg viewBox="0 0 24 24"><path d="M11 3h2v10.17l3.59-3.58L18 11l-6 6-6-6 1.41-1.41L11 13.17zM5 19h14v2H5z"/></svg><span>Bu videoyu indir</span></button>
      <div class="menu" hidden></div>
    </div>`;
  const btn = root.querySelector("button");
  const label = root.querySelector("span");
  const wrap = root.querySelector(".wrap");
  const menu = root.querySelector(".menu");

  let current = null;
  let hideTimer = null;
  let busy = false;

  function attach() {
    if (!host.isConnected) (document.fullscreenElement || document.documentElement).appendChild(host);
  }

  function hide() {
    host.style.display = "none";
    current = null;
    closeMenu();
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
          if (v !== current && !busy) {
            resetLabel();
            closeMenu();
          }
          current = v;
          place(v);
        } else if (current && !busy) {
          clearTimeout(hideTimer);
          hideTimer = setTimeout(() => menuInUse() || hide(), 1200);
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

  // ---------- Hover menu: pick quality and audio language without opening the app window ----------

  const infos = new Map(); // page URL -> answer from the app (qualities, audio tracks)
  let menuPage = null;
  let openTimer = 0;
  let closeTimer = 0;
  let unsupported = false; // Safari can't get answers back from the app

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // The language list's native popup takes the pointer off the page; don't close under it.
  function menuInUse() {
    return !menu.hidden && menu.contains(root.activeElement);
  }

  function closeMenu() {
    clearTimeout(openTimer);
    menu.hidden = true;
    menuPage = null;
  }

  function note(text) {
    menu.replaceChildren(el("div", "note", text));
  }

  function render(info, v) {
    menu.replaceChildren();
    let select = null;
    if (info.tracks && info.tracks.length > 1) {
      menu.append(el("div", "head", "Ses dili (dublaj)"));
      select = el("select");
      for (const t of info.tracks) {
        const o = el("option", null, t.label);
        o.value = t.code;
        o.selected = t.code === info.track;
        select.append(o);
      }
      select.addEventListener("click", (e) => e.stopPropagation());
      select.addEventListener("change", () => select.blur());
      menu.append(select);
    }
    menu.append(el("div", "head", "Kalite"));
    for (const opt of info.options || []) {
      const row = el("div", "item");
      row.append(el("span", null, opt.label), el("span", "d", opt.detail));
      row.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        grab(v, opt.label, select ? select.value : "");
      });
      menu.append(row);
    }
  }

  function openMenu() {
    if (!current || busy || unsupported) return;
    const v = current;
    const page = pageUrlFor(v);
    if (menuPage === page && !menu.hidden) return;
    menuPage = page;
    menu.hidden = false;
    const known = infos.get(page);
    if (known) return render(known, v);
    note("Kaliteler alınıyor…");
    const src = v.currentSrc || v.src || "";
    chrome.runtime.sendMessage(
      { type: "probe", pageUrl: page, mediaUrl: src, referrer: window === top ? "" : document.referrer },
      (res) => {
        void chrome.runtime.lastError;
        if (res && res.unsupported) {
          unsupported = true;
          return closeMenu();
        }
        if (res && res.ok && res.options && res.options.length) infos.set(page, res);
        if (menuPage !== page || menu.hidden) return;
        if (infos.has(page)) render(res, v);
        else note("Seçenekler alınamadı. Butona tıklayıp uygulamada seçebilirsin.");
      }
    );
  }

  function grab(v, option, track) {
    const page = pageUrlFor(v);
    closeMenu();
    busy = true;
    label.textContent = "Gönderiliyor…";
    const src = v.currentSrc || v.src || "";
    chrome.runtime.sendMessage(
      { type: "grab", pageUrl: page, mediaUrl: src, title: document.title, option, track,
        referrer: window === top ? "" : document.referrer },
      (res) => {
        void chrome.runtime.lastError;
        busy = false;
        btn.className = res && res.ok ? "done" : "err";
        label.textContent = res && res.ok ? "İndirme başladı" : "Uygulama açılamadı";
        setTimeout(resetLabel, 3000);
      }
    );
  }

  wrap.addEventListener("mouseenter", () => {
    clearTimeout(closeTimer);
    clearTimeout(openTimer);
    openTimer = setTimeout(openMenu, 250);
  });
  wrap.addEventListener("mouseleave", () => {
    clearTimeout(openTimer);
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => menuInUse() || closeMenu(), 450);
  });

  btn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!current || busy) return;
    closeMenu();
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
