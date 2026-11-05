// MDM Chrome extension: hands browser downloads and page videos to the Mac app
// through Chrome Native Messaging (host: com.savascitaner.idmmac).

if (typeof importScripts === "function") importScripts("i18n.js");

const HOST = "com.savascitaner.idmmac";

const DEFAULTS = {
  capture: true,
  videoButton: true,
  minSizeKB: 0,
  disabledSites: [],
  // Every file Chrome decides to download goes to MDM, not only the types in `exts`
  // (documents, images, files without an extension...). Web pages Chrome saves stay in Chrome.
  captureAll: true,
  exts: "zip rar 7z gz bz2 xz tar tgz dmg pkg iso img exe msi apk deb rpm appimage bin " +
    "mp3 m4a aac flac wav ogg opus mp4 m4v mkv avi mov wmv flv webm mpg mpeg ts " +
    "pdf epub djvu torrent psd ai",
};

async function settings() {
  return chrome.storage.local.get(DEFAULTS);
}

// ---------- Native messaging ----------

let port = null;
const pending = new Map();

function getPort() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    return null;
  }
  port.onMessage.addListener((m) => {
    if (m && m.type === "fallback" && m.url) {
      // The app couldn't fetch it (e.g. the server sent a web page); let Chrome download it itself.
      skipOnce.add(m.url);
      chrome.downloads.download({ url: m.url });
      return;
    }
    if (m && m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      clearTimeout(p.timer);
      pending.delete(m.id);
      p.resolve(m);
    }
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = null;
    for (const p of pending.values()) {
      clearTimeout(p.timer);
      p.resolve(null);
    }
    pending.clear();
  });
  return port;
}

/** Sends a message to the app; resolves with its reply, or null if the app could not be reached. */
function send(msg, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const p = getPort();
    if (!p) return resolve(null);
    msg.id = crypto.randomUUID();
    const timer = setTimeout(() => {
      pending.delete(msg.id);
      resolve(null);
    }, timeoutMs);
    pending.set(msg.id, { resolve, timer });
    try {
      p.postMessage(msg);
    } catch (e) {
      clearTimeout(timer);
      pending.delete(msg.id);
      resolve(null);
    }
  });
}

// ---------- Cookies ----------

async function cookiesFor(...urls) {
  const out = new Map();
  for (const url of urls) {
    if (!url || !/^https?:/i.test(url)) continue;
    for (const query of [{ url }, { url, partitionKey: {} }]) {
      try {
        for (const c of await chrome.cookies.getAll(query)) {
          out.set(`${c.domain}|${c.path}|${c.name}`, c);
        }
      } catch (e) {
        /* partitionKey not supported on this Chrome */
      }
    }
  }
  return [...out.values()].map((c) => ({
    name: c.name,
    value: c.value,
    domain: c.domain,
    path: c.path,
    secure: c.secure,
    httpOnly: c.httpOnly,
    hostOnly: c.hostOnly,
    expirationDate: c.expirationDate || 0,
  }));
}

// ---------- Download capture ----------

const skipOnce = new Set(); // URLs we hand back to Chrome on purpose
const postURLs = new Map(); // URL -> time of a recent POST (those can't be replayed)

chrome.webRequest.onBeforeRequest.addListener(
  (d) => {
    if (d.method !== "POST") return;
    postURLs.set(d.url, Date.now());
    if (postURLs.size > 300) {
      const cutoff = Date.now() - 120000;
      for (const [u, t] of postURLs) if (t < cutoff) postURLs.delete(u);
    }
  },
  { urls: ["<all_urls>"], types: ["main_frame", "sub_frame", "other", "xmlhttprequest"] }
);

function extOf(name) {
  const m = /\.([a-z0-9]{1,10})$/i.exec(name || "");
  return m ? m[1].toLowerCase() : "";
}

function siteOf(u) {
  try {
    // blob:https://site/uuid -> site
    return new URL(String(u || "").replace(/^blob:/i, "")).hostname.replace(/^www\./, "");
  } catch (e) {
    return "";
  }
}

/** A file the page made itself (blob: or data: URL, e.g. ElevenLabs audio): MDM can't fetch it. */
function isLocal(url) {
  return /^(blob|data):/i.test(url || "");
}

/**
 * What to do with a download Chrome just started:
 *  "fetch": cancel it in Chrome, MDM downloads the URL itself (with cookies, referrer, user agent);
 *  "adopt": a blob:/data: file only this tab has; Chrome writes it (instantly, nothing to download) and MDM
 *           then moves the finished file into its folder and list;
 *  "": Chrome keeps it.
 */
function captureMode(item, s) {
  const url = item.finalUrl || item.url;
  if (!s.capture) return "";
  const off = new Set(s.disabledSites || []);
  if (off.has(siteOf(item.referrer)) || off.has(siteOf(url)) || off.has(siteOf(item.url))) return "";
  if (item.byExtensionId === chrome.runtime.id) return "";
  if (item.state && item.state !== "in_progress") return "";
  if (skipOnce.has(url) || skipOnce.has(item.url)) {
    skipOnce.delete(url);
    skipOnce.delete(item.url);
    return "";
  }
  if (s.minSizeKB > 0 && item.totalBytes > 0 && item.totalBytes < s.minSizeKB * 1024) return "";
  if (isLocal(item.url) || isLocal(url)) return "adopt";
  if (!/^https?:/i.test(url)) return ""; // file:, filesystem: stay in Chrome
  if (postURLs.has(url) || postURLs.has(item.url)) return ""; // a form POST can't be replayed

  const name = (item.filename || "").split("/").pop();
  let path = "";
  try {
    path = new URL(url).pathname;
  } catch (e) {
    /* not a URL */
  }
  const ext = extOf(name) || extOf(path);
  const mime = (item.mime || "").toLowerCase();
  // "Save page as…" and pages served as attachments: MDM would only get the page again.
  if (/^text\/html|application\/xhtml/.test(mime) || ["htm", "html", "mhtml", "xhtml"].includes(ext)) return "";
  if (s.captureAll) return "fetch";

  const list = s.exts.split(/[\s,]+/).filter(Boolean);
  if (ext && list.includes(ext)) return "fetch";
  return /^(video|audio)\/|octet-stream|zip|compressed|diskimage|x-msdownload|x-iso|x-apple|x-tar|x-7z|x-rar|pdf/i.test(mime)
    ? "fetch"
    : "";
}

async function handOff(item) {
  const url = item.finalUrl || item.url;
  try {
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
  } catch (e) {
    /* already gone */
  }
  const res = await send({
    type: "download",
    url,
    originalUrl: item.url,
    filename: (item.filename || "").split("/").pop(),
    referrer: item.referrer || "",
    mime: item.mime || "",
    size: item.totalBytes || 0,
    // If the server refuses MDM (HTTP 403, a web page instead of the file...), the app hands it back here.
    fallback: "browser",
    userAgent: navigator.userAgent,
    cookies: await cookiesFor(url),
  });
  if (!res || res.type !== "accepted") {
    // App unavailable: give the download back to Chrome.
    skipOnce.add(url);
    chrome.downloads.download({ url });
  }
}

// ---------- Files the page made itself (blob:/data:) ----------

// Download ids Chrome is writing for MDM to adopt once they are complete. Kept in session storage too,
// because the service worker can stop in between.
const ADOPT_KEY = "adoptIds";
const adoptMem = new Map();

async function rememberAdopt(item) {
  adoptMem.set(item.id, { referrer: item.referrer || "", time: Date.now() });
  const cur = (await chrome.storage.session.get({ [ADOPT_KEY]: {} }))[ADOPT_KEY];
  cur[item.id] = { referrer: item.referrer || "", time: Date.now() };
  for (const [k, v] of Object.entries(cur)) if (Date.now() - v.time > 3600000) delete cur[k];
  await chrome.storage.session.set({ [ADOPT_KEY]: cur });
}

async function takeAdopt(id) {
  const mem = adoptMem.get(id);
  adoptMem.delete(id);
  const cur = (await chrome.storage.session.get({ [ADOPT_KEY]: {} }))[ADOPT_KEY];
  const v = cur[id] || mem;
  if (!v) return null;
  if (cur[id]) {
    delete cur[id];
    await chrome.storage.session.set({ [ADOPT_KEY]: cur });
  }
  return v;
}

/** Chrome finished writing a blob:/data: file: MDM moves it into its download folder and lists it. */
async function adopt(item, info) {
  const url = item.url || "";
  // A data: URL can be megabytes long: only its type goes along.
  const shownUrl = url.startsWith("data:") ? url.split(/[;,]/)[0] : url;
  let referrer = info.referrer || item.referrer || "";
  if (!referrer && url.startsWith("blob:")) {
    try {
      referrer = new URL(url.slice(5)).origin + "/";
    } catch (e) {
      /* opaque origin */
    }
  }
  const res = await send(
    {
      type: "adopt",
      path: item.filename,
      url: shownUrl,
      referrer,
      mime: item.mime || "",
      size: item.fileSize || item.totalBytes || 0,
    },
    30000
  );
  if (res && res.type === "adopted" && res.ok) {
    // The file now lives in MDM's folder; Chrome's entry would point to nothing.
    chrome.downloads.erase({ id: item.id });
  }
  // Otherwise (app not reachable, file could not be moved) the file simply stays where Chrome saved it.
}

chrome.downloads.onChanged.addListener(async (d) => {
  if (!d.state || d.state.current !== "complete") return;
  let info = await takeAdopt(d.id);
  if (!info && !chrome.downloads.onDeterminingFilename) {
    // Firefox: a tiny blob can finish before onCreated's bookkeeping is done.
    await new Promise((r) => setTimeout(r, 800));
    info = await takeAdopt(d.id);
  }
  if (!info) return;
  const [item] = await chrome.downloads.search({ id: d.id });
  if (item && item.filename && item.exists !== false) adopt(item, info);
});

function route(item, s) {
  const mode = captureMode(item, s);
  if (mode === "fetch") handOff(item);
  else if (mode === "adopt") return rememberAdopt(item);
  return Promise.resolve();
}

// Firefox has no onDeterminingFilename; onCreated fires a little earlier (file name and MIME type may still be empty).
if (!chrome.downloads.onDeterminingFilename) {
  chrome.downloads.onCreated.addListener((item) => {
    settings().then((s) => route(item, s));
  });
}

// onDeterminingFilename fires once the response headers are in, so the real file name and MIME type are known.
if (chrome.downloads.onDeterminingFilename) chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  settings()
    .then((s) => route(item, s))
    .catch(() => {})
    .finally(() => {
      try {
        suggest();
      } catch (e) {
        /* download was already cancelled */
      }
    });
  return true;
});

// ---------- Media detection (for pages without a <video> the button can find) ----------

function header(headers, name) {
  const h = (headers || []).find((x) => x.name.toLowerCase() === name);
  return h ? h.value : "";
}

async function addMedia(tabId, entry) {
  const key = `media_${tabId}`;
  const cur = (await chrome.storage.session.get({ [key]: [] }))[key];
  if (cur.some((m) => m.url === entry.url)) return;
  cur.push(entry);
  if (cur.length > 30) cur.shift();
  await chrome.storage.session.set({ [key]: cur });
  chrome.action.setBadgeBackgroundColor({ color: "#2563eb", tabId });
  chrome.action.setBadgeText({ text: String(cur.length), tabId });
}

chrome.webRequest.onHeadersReceived.addListener(
  (d) => {
    if (d.tabId < 0) return;
    const ct = header(d.responseHeaders, "content-type").toLowerCase();
    const len = parseInt(header(d.responseHeaders, "content-length") || "0", 10);
    const u = d.url;
    if (/googlevideo\.com|\.m4s(\?|$)|\.ts(\?|$)|seg-\d+|\/range\//i.test(u)) return; // stream fragments
    let kind = null;
    if (/mpegurl/.test(ct) || /\.m3u8(\?|$)/i.test(u)) kind = "HLS";
    else if (/dash\+xml/.test(ct) || /\.mpd(\?|$)/i.test(u)) kind = "DASH";
    else if (/^(video|audio)\//.test(ct) && !/mp2t|iso\.segment/.test(ct) && len > 300 * 1024) kind = ct.split(";")[0];
    if (!kind) return;
    addMedia(d.tabId, { url: u, kind, size: len, time: Date.now() });
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] },
  ["responseHeaders"]
);

chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === "loading" && info.url) {
    chrome.storage.session.remove(`media_${tabId}`);
    chrome.action.setBadgeText({ text: "", tabId });
  }
});
chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove(`media_${tabId}`));

// ---------- Video hand-off ----------

async function sendVideo({ pageUrl, mediaUrl, title, referrer }) {
  return send({
    type: "video",
    pageUrl,
    mediaUrl: mediaUrl && !mediaUrl.startsWith("blob:") ? mediaUrl : "",
    title: title || "",
    referrer: referrer || "",
    userAgent: navigator.userAgent,
    cookies: await cookiesFor(pageUrl, mediaUrl),
  });
}

async function sendLink(url, referrer) {
  return send({
    type: "download",
    url,
    filename: "",
    referrer: referrer || "",
    userAgent: navigator.userAgent,
    cookies: await cookiesFor(url),
  });
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    switch (msg.type) {
      case "video": {
        const res = await sendVideo({ ...msg, referrer: msg.referrer || sender.tab?.url || "" });
        reply({ ok: !!res && res.type === "accepted" });
        break;
      }
      case "link": {
        const res = await sendLink(msg.url, msg.referrer);
        reply({ ok: !!res && res.type === "accepted" });
        break;
      }
      case "probe": {
        // yt-dlp needs a few seconds (longer for YouTube), so wait well past the usual timeout.
        const res = await send(
          {
            type: "probe",
            pageUrl: msg.pageUrl,
            mediaUrl: msg.mediaUrl && !msg.mediaUrl.startsWith("blob:") ? msg.mediaUrl : "",
            referrer: msg.referrer || sender.tab?.url || "",
            userAgent: navigator.userAgent,
            cookies: await cookiesFor(msg.pageUrl, msg.mediaUrl),
          },
          90000
        );
        reply(res && res.type === "info" ? res : null);
        break;
      }
      case "grab": {
        const res = await send({
          type: "grab",
          pageUrl: msg.pageUrl,
          mediaUrl: msg.mediaUrl && !msg.mediaUrl.startsWith("blob:") ? msg.mediaUrl : "",
          title: msg.title || "",
          option: msg.option,
          track: msg.track || "",
          referrer: msg.referrer || sender.tab?.url || "",
          userAgent: navigator.userAgent,
          cookies: await cookiesFor(msg.pageUrl, msg.mediaUrl),
        });
        reply({ ok: !!res && res.type === "accepted" });
        break;
      }
      case "url": {
        const res = await send({ type: "url", url: msg.url, userAgent: navigator.userAgent, cookies: await cookiesFor(msg.url) });
        reply({ ok: !!res && res.type === "accepted" });
        break;
      }
      case "allLinks":
        reply({ ok: await sendAllLinks(msg.tabId) });
        break;
      case "bypass":
        // Option-click on a link: Chrome downloads this one itself.
        skipOnce.add(msg.url);
        setTimeout(() => skipOnce.delete(msg.url), 60000);
        reply({ ok: true });
        break;
      case "status": {
        const res = await send({ type: "ping" }, 4000);
        reply({ host: !!res, app: !!res?.app, version: chrome.runtime.getManifest().version });
        break;
      }
      case "media": {
        const key = `media_${msg.tabId}`;
        reply((await chrome.storage.session.get({ [key]: [] }))[key]);
        break;
      }
      default:
        reply(null);
    }
  })();
  return true;
});

// ---------- All links on a page ----------

/** Asks the page for every link on it and opens MDM's picker with them. */
async function sendAllLinks(tabId) {
  const res = await new Promise((resolve) =>
    chrome.tabs.sendMessage(tabId, { type: "collectLinks" }, { frameId: 0 }, (r) => {
      void chrome.runtime.lastError;
      resolve(r);
    })
  );
  if (!res) return false;
  // Cookies for the page and the sites its links point to; the app sends each link only its own.
  const origins = new Set();
  for (const i of res.items) {
    try {
      origins.add(new URL(i.url).origin + "/");
    } catch (e) {
      /* not a URL */
    }
    if (origins.size >= 15) break;
  }
  const reply = await send({
    type: "links",
    pageUrl: res.pageUrl,
    title: res.title,
    items: res.items,
    referrer: res.pageUrl,
    userAgent: navigator.userAgent,
    cookies: await cookiesFor(res.pageUrl, ...origins),
  });
  return !!reply && reply.type === "accepted";
}

// ---------- Updates ----------

// After MDM updates itself it writes the new extension files to the folder Chrome loads them from;
// reloading picks them up. reloadedFor stops a loop if Chrome loads the extension from another folder.
async function reloadIfUpdated() {
  const res = await send({ type: "ping" }, 4000);
  const want = res && res.extension;
  if (!want || want === chrome.runtime.getManifest().version) return;
  const { reloadedFor } = await chrome.storage.local.get({ reloadedFor: "" });
  if (reloadedFor === want) return;
  await chrome.storage.local.set({ reloadedFor: want });
  chrome.runtime.reload();
}
reloadIfUpdated();

// ---------- Keyboard shortcut ----------

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "download-page-video") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab && tab.url) sendVideo({ pageUrl: tab.url, title: tab.title, referrer: tab.url });
});

// ---------- Context menu ----------

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "idm-link", title: T("MDM ile indir"), contexts: ["link", "image", "audio"] });
    chrome.contextMenus.create({ id: "idm-video", title: T("Bu videoyu MDM ile indir"), contexts: ["video", "page", "frame"] });
    chrome.contextMenus.create({ id: "idm-all", title: T("Sayfadaki tüm linkleri MDM ile indir…"), contexts: ["page"] });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "idm-link") {
    sendLink(info.linkUrl || info.srcUrl, info.pageUrl);
  } else if (info.menuItemId === "idm-video") {
    const pageUrl = info.frameUrl && info.frameUrl !== info.pageUrl && /player|embed|video/i.test(info.frameUrl)
      ? info.frameUrl
      : info.pageUrl;
    sendVideo({ pageUrl, mediaUrl: info.srcUrl, title: tab?.title, referrer: info.pageUrl });
  } else if (info.menuItemId === "idm-all" && tab) {
    sendAllLinks(tab.id);
  }
});
