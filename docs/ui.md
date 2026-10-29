# UI PALLSQL 0.2

## Palet

| Token | Nilai | Pemakaian |
| --- | --- | --- |
| `background` | `#101311` | Latar aplikasi |
| `surface` | `#181D19` | Kartu |
| `surfaceElevated` | `#202721` | Dialog, bottom sheet |
| `border` | `#303A32` | Garis tipis kartu dan input |
| `textPrimary` | `#E4E9E4` | Teks utama |
| `textSecondary` | `#A0AAA1` | Teks pendukung |
| `accent` | `#9BCB91` | Tombol utama, indikator aktif, link |
| `accentSoft` | `#B6D8A8` | Teks di atas accentMuted |
| `error` | `#D77C7C` | Error dan aksi destruktif |
| `warning` | `#D6B477` | Peringatan |

Hijau neon tidak lagi dipakai untuk border, seluruh tombol, atau teks badan.
Hanya **satu** aksi utama per layar yang memakai `accent`; tombol lain netral.

## Tema dan keterbacaan

- Dark theme (default) dan Light theme (opsional), plus mode *System*.
- Ukuran teks global 85 %–130 % yang tersimpan di `config/settings.json`.
- Ukuran font editor 10–24 pt.
- Kontras teks utama terhadap latar > 7:1 (diuji di `test/theme_test.dart`).
- Transisi halaman singkat, ripple lembut (`InkRipple`, alpha rendah).

## Komponen reusable

| Komponen | File | Kegunaan |
| --- | --- | --- |
| `PallSQLAppBar` | `widgets/pallsql_app_bar.dart` | App bar + wordmark + logo mark |
| `PallSQLButton` | `widgets/pallsql_components.dart` | Primary / secondary / danger + busy state |
| `PallSQLTextField` | `widgets/pallsql_components.dart` | Input standar (monospace opsional) |
| `PallSQLCard` (`PallSqlCard`) | `widgets/pallsql_card.dart` | Permukaan kartu |
| `PallSQLStatusBadge` | `widgets/pallsql_components.dart` | Pill status/engine |
| `PallSQLTerminal` | `widgets/pallsql_components.dart` | Panel output monospace |
| `PallSQLCodeEditor` | `widgets/pallsql_components.dart` | Editor + nomor baris + highlight |
| `PallSQLLoading` | `widgets/pallsql_components.dart` | Spinner/bar dengan caption |
| `PallSQLDialog` | `widgets/pallsql_components.dart` | `prompt`, `confirm`, `info` |
| `PallSQLBottomNavigation` | `widgets/pallsql_bottom_navigation.dart` | Navigasi 5 tab |

`ServiceControlButton` tetap ada sebagai alias tipis dari `PallSQLButton` agar
layar lama dan test lama tidak berubah.

## Loading screen

`lib/features/startup/`:

- `PallsqlSplashScreen` — logo, nama, tagline **Mobile Development Environment**,
  bar progres, langkah yang sedang berjalan, dan teks
  **Initializing local environment**.
- `StartupGate` — menjalankan `AppBootstrap.create` dengan `onProgress`, batas
  waktu 30 detik, lalu membuka dashboard. Jika gagal/timeout, muncul
  `StartupFailureScreen` dengan tombol **Retry** (bukan loading tanpa akhir).
- Splash sistem Android (`LaunchTheme`, plus `values-v31` untuk Android 12+)
  hanya menampilkan latar gelap + ikon; status PHP/MariaDB tidak pernah
  ditampilkan aktif sebelum runtime benar-benar diperiksa.

## Halaman About

`lib/features/about/about_page.dart` menampilkan aplikasi, versi, package,
developer **pallxXx**, tautan Instagram dengan tombol **Visit Instagram**,
lokasi workspace, credits & licenses (Flutter/Dart, sqflite, SQLite, riverpod,
path/path_provider/archive/url_launcher, catatan PHP dan MariaDB tidak
dibundel), tombol daftar lisensi open source, dan footer
`© 2026 PALLSQL. Developed by pallXxX.`
