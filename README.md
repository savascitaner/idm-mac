# IDM Mac

Apple Silicon Mac'ler için IDM (Internet Download Manager) benzeri indirme yöneticisi ve Chrome eklentisi.

- **Otomatik yakalama:** Chrome'da bir indirme linkine tıklayınca indirme uygulamaya geçer ve çok bağlantıyla (varsayılan 8) iner. Duraklat/sürdür desteklenir, uygulama kapansa da kaldığı yerden devam eder.
- **"Bu videoyu indir" butonu:** YouTube, Vimeo, X, Instagram vb. sitelerde videonun üstüne gelince çıkar; kalite seçilir, indirme [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg ile yapılır. yt-dlp günde bir kez kendini günceller.
- Menü çubuğu simgesi, bildirimler, indirme sürerken uykuyu engelleme, indirilen dosyalara macOS karantina/kaynak bilgisi.

## İndir

Son sürüm: [IDM-Mac.dmg](../../releases/download/latest/IDM-Mac.dmg) (her `main` gönderiminde GitHub Actions üretir). Kurulum adımları DMG içindeki `BENİ OKU.txt` dosyasında.

## Yapı

| Klasör | İçerik |
|---|---|
| `Sources/IDMMac` | SwiftUI uygulaması: çok parçalı indirme motoru, yt-dlp sarmalayıcı, Unix soket sunucusu |
| `Sources/IDMMacHost` | Chrome Native Messaging köprüsü (uygulama paketinin içinde durur) |
| `Extension` | Manifest V3 Chrome eklentisi (paketlenmemiş olarak yüklenir) |
| `Packaging` | `.app` + `.dmg` üreten betik |

Akış: Eklenti → `chrome.runtime.connectNative` → `IDMMacHost` (stdin/stdout) → `~/Library/Application Support/IDMMac/ipc.sock` → uygulama.

Yerelde derleme (Xcode komut satırı araçları gerekir): `./Packaging/package.sh`
