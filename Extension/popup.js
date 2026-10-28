const $ = (id) => document.getElementById(id);

function fmt(n) {
  if (!n) return "";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
}

async function main() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

  chrome.runtime.sendMessage({ type: "status" }, (s) => {
    const dot = $("dot"), t = $("statusText");
    if (!s || !s.host) {
      dot.className = "dot bad";
      t.textContent = "Uygulama kurulu değil";
    } else if (!s.app) {
      dot.className = "dot warn";
      t.textContent = "Uygulama kapalı (gerekince açılır)";
    } else {
      dot.className = "dot ok";
      t.textContent = "Bağlı · v" + (s.version || "");
    }
  });

  const s = await chrome.storage.local.get({ capture: true, videoButton: true });
  for (const k of ["capture", "videoButton"]) {
    $(k).checked = s[k];
    $(k).addEventListener("change", () => chrome.storage.local.set({ [k]: $(k).checked }));
  }

  const host = (() => { try { return new URL(tab.url).hostname.replace(/^www\./, ""); } catch (e) { return ""; } })();
  const st = await chrome.storage.local.get({ disabledSites: [], minSizeKB: 0 });
  $("siteName").textContent = host;
  $("siteOff").disabled = !host;
  $("siteOff").checked = st.disabledSites.includes(host);
  $("siteOff").addEventListener("change", async () => {
    const cur = (await chrome.storage.local.get({ disabledSites: [] })).disabledSites.filter((h) => h !== host);
    if ($("siteOff").checked) cur.push(host);
    chrome.storage.local.set({ disabledSites: cur });
  });
  $("minSize").value = String(st.minSizeKB);
  $("minSize").addEventListener("change", () => chrome.storage.local.set({ minSizeKB: parseInt($("minSize").value, 10) }));

  $("pageVideo").addEventListener("click", () => {
    chrome.runtime.sendMessage({ type: "video", pageUrl: tab.url, title: tab.title }, (r) => {
      $("pageVideo").textContent = r && r.ok ? "Gönderildi ✓" : "Uygulama açılamadı";
      setTimeout(() => window.close(), 900);
    });
  });

  $("allLinks").addEventListener("click", () => {
    $("allLinks").textContent = "Gönderiliyor…";
    chrome.runtime.sendMessage({ type: "allLinks", tabId: tab.id }, (r) => {
      $("allLinks").textContent = r && r.ok ? "MDM'de açıldı ✓" : "Linkler alınamadı";
      setTimeout(() => window.close(), 900);
    });
  });

  $("add").addEventListener("submit", (e) => {
    e.preventDefault();
    const url = $("url").value.trim();
    chrome.runtime.sendMessage({ type: "url", url }, () => window.close());
  });

  chrome.runtime.sendMessage({ type: "media", tabId: tab.id }, (list) => {
    if (!list || !list.length) return;
    const ul = $("media");
    ul.innerHTML = "";
    for (const m of list.slice().reverse()) {
      const li = document.createElement("li");
      const name = decodeURIComponent(new URL(m.url).pathname.split("/").pop() || m.url);
      li.innerHTML = `<span></span><small></small><button class="ghost">İndir</button>`;
      li.querySelector("span").textContent = name;
      li.querySelector("span").title = m.url;
      li.querySelector("small").textContent = [m.kind, fmt(m.size)].filter(Boolean).join(" · ");
      li.querySelector("button").addEventListener("click", () => {
        const msg = m.kind === "HLS" || m.kind === "DASH"
          ? { type: "video", pageUrl: tab.url, mediaUrl: m.url, title: tab.title }
          : { type: "link", url: m.url, referrer: tab.url };
        chrome.runtime.sendMessage(msg, () => window.close());
      });
      ul.appendChild(li);
    }
  });
}

main();
