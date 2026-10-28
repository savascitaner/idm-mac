// Turkish is the default text. For any other browser language the English text from this table is used.
// (The Mac app has its own language setting; the extension follows the browser language.)
(function () {
  const EN = {
    "Bu videoyu indir": "Download this video",
    "Gönderiliyor…": "Sending…",
    "İndirme başladı": "Download started",
    "Uygulama açılamadı": "Could not open the app",
    "MDM'ye gönderildi": "Sent to MDM",
    "Kaliteler alınıyor…": "Getting qualities…",
    "Seçenekler alınamadı. Butona tıklayıp uygulamada seçebilirsin.": "Could not get the options. Click the button and choose in the app.",
    "Uygulama kurulu değil": "The app is not installed",
    "Uygulama kapalı (gerekince açılır)": "The app is closed (opens when needed)",
    "Bağlı · v": "Connected · v",
    "Gönderildi ✓": "Sent ✓",
    "MDM'de açıldı ✓": "Opened in MDM ✓",
    "Linkler alınamadı": "Could not get the links",
    "İndir": "Download",
    "Kontrol ediliyor…": "Checking…",
    "Bu sayfadaki videoyu indir": "Download the video on this page",
    "Tüm linkleri listele": "List all links",
    "Bu sekmede bulunan medya": "Media found in this tab",
    "Henüz bir şey yakalanmadı.": "Nothing captured yet.",
    "Adres yapıştır": "Paste an address",
    "İndirmeleri otomatik yakala": "Capture downloads automatically",
    "Videoların üstünde buton göster": "Show a button on videos",
    "Bu sitede yakalamayı kapat": "Turn off capture on this site",
    "Küçük dosyaları Chrome indirsin": "Let the browser download small files",
    "Hepsini yakala": "Capture all",
    "1 MB altı": "Under 1 MB",
    "10 MB altı": "Under 10 MB",
    "100 MB altı": "Under 100 MB",
    "İpucu: linke ⌥ (Option) basılı tıklarsan o indirmeyi Chrome yapar.": "Tip: Option-click a link and the browser downloads it itself.",
    "MDM ile indir": "Download with MDM",
    "Bu videoyu MDM ile indir": "Download this video with MDM",
    "Sayfadaki tüm linkleri MDM ile indir…": "Download all links on this page with MDM…",
  };
  const lang = (typeof navigator !== "undefined" && navigator.language || "tr").toLowerCase();
  const turkish = lang.startsWith("tr");
  const T = (s) => (turkish ? s : EN[s] || s);
  // Replaces the Turkish text of a page's elements (popup) with the table's text.
  const translateDom = (root) => {
    if (turkish) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const k = n.nodeValue.trim();
      if (EN[k]) n.nodeValue = n.nodeValue.replace(k, EN[k]);
    }
    for (const el of root.querySelectorAll("[placeholder]")) {
      const p = el.getAttribute("placeholder");
      if (EN[p]) el.setAttribute("placeholder", EN[p]);
    }
  };
  globalThis.T = T;
  globalThis.translateDom = translateDom;
})();
