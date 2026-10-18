// MDM Safari extension. Safari has no downloads API, so download links are caught in the page
// (capture.js) and everything goes to the app through the extension's native handler.

const api = typeof browser !== "undefined" ? browser : chrome;
const APP = "com.savascitaner.idmmac";

async function send(msg) {
  msg.id = crypto.randomUUID();
  try {
    return await api.runtime.sendNativeMessage(APP, msg);
  } catch (e) {
    return null;
  }
}

async function cookiesFor(...urls) {
  const out = new Map();
  for (const url of urls) {
    if (!url || !/^https?:/i.test(url)) continue;
    try {
      for (const c of await api.cookies.getAll({ url })) out.set(`${c.domain}|${c.path}|${c.name}`, c);
    } catch (e) {
      /* cookies not available */
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

async function sendLink(url, referrer, filename) {
  return send({
    type: "download",
    url,
    filename: filename || "",
    referrer: referrer || "",
    userAgent: navigator.userAgent,
    cookies: await cookiesFor(url),
  });
}

const ok = (res) => !!res && res.type === "accepted";

api.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    switch (msg.type) {
      case "video":
        reply({ ok: ok(await sendVideo({ ...msg, referrer: msg.referrer || sender.tab?.url || "" })) });
        break;
      case "link":
        reply({ ok: ok(await sendLink(msg.url, msg.referrer, msg.filename)) });
        break;
      case "url":
        reply({ ok: ok(await send({ type: "url", url: msg.url, userAgent: navigator.userAgent, cookies: await cookiesFor(msg.url) })) });
        break;
      case "status": {
        const res = await send({ type: "ping" });
        reply({ host: !!res, app: !!res?.app });
        break;
      }
      case "media":
        reply([]); // Safari doesn't let extensions watch network responses the way Chrome does.
        break;
      default:
        reply(null);
    }
  })();
  return true;
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.removeAll(() => {
    api.contextMenus.create({ id: "idm-link", title: "MDM ile indir", contexts: ["link", "image", "audio"] });
    api.contextMenus.create({ id: "idm-video", title: "Bu videoyu MDM ile indir", contexts: ["video", "page", "frame"] });
  });
});

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "idm-link") {
    sendLink(info.linkUrl || info.srcUrl, info.pageUrl);
  } else if (info.menuItemId === "idm-video") {
    sendVideo({ pageUrl: info.frameUrl || info.pageUrl, mediaUrl: info.srcUrl, title: tab?.title, referrer: info.pageUrl });
  }
});
