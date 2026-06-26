# Changelog

## v0.2.0
- **Web panel v2:** kullanıcı/şifre **login** (ilk girişte zorunlu sıfırlama, ADB'den şifre yönetimi), profesyonel **mobil uyumlu** yeniden tasarım.
- **Magisk modül yöneticisi:** kurulu modülleri aç/kapa/kaldır, dikeckaan kataloğundan kur, **zip ile yükleme** (panel + bot).
- **Entegrasyon yönetimi:** Tailscale/SSH/Tor başlat-durdur; **durdurulan servis reboot'ta geri açılmaz** (tüm servislerin on/off kararı kalıcı).
- **VPN güvenilirliği:** tun0 route için kalıcı bekçi (netd periyodik flush'a karşı → client'lar VPN'i kaybetmez).
- **Profil hız testi** (`/probe`, en hızlıya geç) · **per-client bypass** sekmesi.
- Self-update workflow'u self-contained (otomatik build + release + update.json senkron).
- Güvenlik: şifre hash (iterated), SMS/import/modül-zip injection & path-traversal sertleştirmeleri.


## v0.1.0 — İlk sürüm
İlk public sürüm. ZTE F50 için xray tabanlı VPN + web panel + Telegram bot + SMS merkezi, hepsi tek ortak backend (`lib/action.sh`).

- **Xray VPN:** vmess/vless/trojan + abonelik import; tun0/tproxy; profil hız testi → en hızlıya geç; allowInsecure→cert-pin (xray 26.3.27); tun0 route için kalıcı bekçi (netd flush'a karşı).
- **Web panel:** profesyonel + mobil uyumlu; kullanıcı/şifre login (ilk girişte zorunlu sıfırlama); ADB'den şifre yönetimi; localhost/LAN.
- **Telegram bot:** 80+ komut + VPN/Xray/adblock/SMS kontrolü; 12 dil.
- **SMS merkezi:** oku/gönder/sil + SMS ile uzaktan komut (gizli kod + whitelist + rate-limit).
- **Adblock:** dnsmasq sinkhole (AdGuard Home yerine).
- **Per-client bypass · Entegrasyon yönetimi** (Tailscale/SSH/Tor başlat-durdur).
- **Self-update** (latest.txt + SHA256).
