// Safari has no downloads API, so clicks on links to downloadable files are caught here and sent to MDM.
// If the app can't be reached the link is opened normally and Safari downloads it.
(() => {
  if (window.__idmMacCapture) return;
  window.__idmMacCapture = true;

  const DEFAULT_EXTS =
    "zip rar 7z gz bz2 xz tar tgz dmg pkg iso img exe msi apk deb rpm appimage bin " +
    "mp3 m4a aac flac wav ogg opus mp4 m4v mkv avi mov wmv flv webm mpg mpeg ts " +
    "pdf epub djvu torrent psd ai";
  let s = { capture: true, exts: DEFAULT_EXTS };
  chrome.storage.local.get(s, (v) => (s = v));
  chrome.storage.onChanged.addListener((c) => {
    for (const k of Object.keys(c)) if (k in s) s[k] = c[k].newValue;
  });

  function extOf(name) {
    const m = /\.([a-z0-9]{1,10})$/i.exec(name || "");
    return m ? m[1].toLowerCase() : "";
  }

  // Hosts whose links are always files (Discord attachments come with ?ex=…&hm=… after the name).
  const FILE_HOSTS = /(^|\.)(cdn\.discordapp\.com|media\.discordapp\.net|attachments\.discordapp\.net)$/i;
  // Sites that only answer a request made by their own page (an authorized origin, the page's cookies):
  // MDM would get HTTP 503 and the link can't be opened again from outside the page, so Safari downloads these itself.
  const SAFARI_ONLY_HOSTS = /(^|\.)(opensubtitles\.(com|org)|subdl\.com|yifysubtitles\.[a-z]+|subscene\.[a-z]+)$/i;
  const PAGE_EXTS = new Set(["", "html", "htm", "php", "asp", "aspx", "jsp", "cgi"]);
  const DOWNLOAD_WORDS = /download|indir|i̇ndir|herunterladen|télécharger|descargar|scarica/i;

  /** The link, or a button right around it, says "download" (e.g. Discord's download icon). */
  function saysDownload(a) {
    let el = a;
    for (let i = 0; el && i < 3; i++, el = el.parentElement) {
      const text = [el.getAttribute("aria-label"), el.getAttribute("title"), el.getAttribute("data-tooltip")].join(" ");
      if (DOWNLOAD_WORDS.test(text)) return true;
    }
    const own = (a.textContent || "").trim();
    return own.length > 0 && own.length < 40 && DOWNLOAD_WORDS.test(own);
  }

  /** Download redirectors without a file name, like discord.com/api/download?platform=osx. The app
   *  checks what the server sends and opens the link in Safari again if it turns out to be a page. */
  function looksLikeRedirect(u) {
    const path = u.pathname.toLowerCase();
    if (!/(^|\/)(download|downloads|dl|getfile|get-file)(\.[a-z]+)?(\/|$)/.test(path)) return false;
    return !!u.search || /(^|\/)api\//.test(path);
  }

  function wanted(a) {
    if (!s.capture) return false;
    let u;
    try {
      u = new URL(a.href, location.href);
    } catch (e) {
      return false;
    }
    if (!/^https?:$/.test(u.protocol)) return false;
    if (SAFARI_ONLY_HOSTS.test(u.hostname)) return false;
    let last = u.pathname.split("/").pop();
    try {
      last = decodeURIComponent(last);
    } catch (e) {
      /* keep as is */
    }
    const ext = extOf(a.getAttribute("download")) || extOf(last);
    if (ext && s.exts.split(/[\s,]+/).includes(ext)) return true;
    // Any file the page itself marks as a download: a download attribute, or a "Download" button
    // pointing at a file (not at a web page) or at a file host.
    const isFile = !PAGE_EXTS.has(ext) || FILE_HOSTS.test(u.hostname);
    if (!isFile) return looksLikeRedirect(u) ? "guess" : false;
    if (a.hasAttribute("download") || saysDownload(a)) return true;
    // A file link on a file host (Discord's attachment name), but not an image that opens a viewer.
    return FILE_HOSTS.test(u.hostname) && !a.querySelector("img, video");
  }

  document.addEventListener(
    "click",
    (e) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = e.composedPath().find((el) => el.tagName === "A" && el.href);
      const want = a && wanted(a);
      if (!want) return;
      e.preventDefault();
      e.stopPropagation();
      const href = a.href;
      const newTab = a.target === "_blank";
      chrome.runtime.sendMessage(
        { type: "link", url: href, referrer: location.href, filename: a.getAttribute("download") || "", guess: want === "guess" },
        (res) => {
          void chrome.runtime.lastError;
          if (res && res.ok) return;
          if (newTab) window.open(href, "_blank");
          else location.assign(href);
        }
      );
    },
    true
  );
})();
