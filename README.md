# PALLSQL

**PALLSQL — Offline mobile web development environment built with Flutter for Android.**

PALLSQL adalah lingkungan pengembangan web lokal (mirip XAMPP) yang berjalan
sepenuhnya di HP Android, tanpa root, tanpa Termux, dan tanpa internet setelah
aplikasi dipasang. Di dalamnya ada HTTP server sungguhan, **server MariaDB
native yang dibangun dari source dan ikut di dalam APK**, file manager, code
editor, project manager, backup ZIP, log viewer, dan terminal terbatas berbasis
registry perintah.

Rilis terbaru: [halaman Releases](https://github.com/HOOOOOOQ/pallsql/releases/latest)
(terpasang langsung, ditandatangani debug key). Riwayat build dan artefak ada di
tab [Actions](https://github.com/HOOOOOOQ/pallsql/actions).

> **Status jujur:** versi 0.3 mengganti SQLite dengan **MariaDB Server 10.11.9**
> yang di-cross-compile untuk Android dengan NDK 27. Binary `libmariadbd.so`
> sudah berhasil dibangun di CI (validasi `readelf`, artefak
> `mariadb-runtime-arm64-v8a`) dan dibuktikan ikut masuk ke APK, dan seluruh
> lapisan data aplikasi memakai klien protokol MariaDB sendiri (tanpa SQLite,
> tanpa cloud, tanpa Connector/C). **Yang belum: menjalankan server itu di
> perangkat fisik** — belum ada uji perangkat/emulator. Runtime PHP juga belum
> dibundel, jadi permintaan `.php` dijawab `HTTP 501` dengan penjelasan, tidak
> pernah mengirim source code PHP ke browser. Rincian status:
> [`docs/mariadb-android.md`](docs/mariadb-android.md).

---

## Daftar isi

- [Fitur](#fitur)
- [Status fitur](#status-fitur)
- [Tangkapan layar](#tangkapan-layar)
- [Teknologi](#teknologi)
- [Struktur repositori](#struktur-repositori)
- [Menjalankan secara lokal](#menjalankan-secara-lokal)
- [Build APK](#build-apk)
- [GitHub Actions dan artefak](#github-actions-dan-artefak)
- [Membuat release](#membuat-release)
- [Arsitektur runtime PHP](#arsitektur-runtime-php)
- [Dukungan database](#dukungan-database)
- [Keamanan local server](#keamanan-local-server)
- [Batasan Android](#batasan-android)
- [Troubleshooting](#troubleshooting)
- [Lisensi runtime](#lisensi-runtime)
- [English summary](#english-summary)

---

## Fitur

- **Dashboard**: status layanan nyata (`stopped`, `starting`, `running`,
  `stopping`, `error`, `unavailable`), tombol Start All / Stop All, port HTTP,
  URL localhost, document root, jumlah project, pemakaian storage, log terbaru,
  dan tombol buka situs di browser.
- **Web server lokal**: `dart:io HttpServer` di `127.0.0.1:8080` (port bisa
  diubah), static file + MIME type, directory index (`index.html`), body dan
  `Content-Length` yang selalu cocok, HTML `no-store` (tidak pernah 304), ETag
  berbasis isi untuk aset, 404/403/405/500 yang benar, request logging, deteksi
  port bentrok, start / stop / restart yang idempoten, proteksi path traversal
  termasuk variasi URL-encoded. Detail: [`docs/http-server.md`](docs/http-server.md).
- **Database MariaDB + SQL editor**: server `mariadbd` native hasil
  cross-compile NDK 27 (`libmariadbd.so`, ABI `arm64-v8a`) dijalankan langsung
  oleh aplikasi, dan aplikasi bicara **protokol MariaDB** (handshake v10,
  `mysql_native_password`, text protocol, prepared statement) lewat TCP
  `127.0.0.1:3306` atau Unix socket. Semua operasi data — daftar/buat/hapus
  schema, tabel, kolom, CRUD, import/export SQL, backup konsisten
  (`START TRANSACTION WITH CONSISTENT SNAPSHOT`) — melewati server itu. Tidak
  ada SQLite sebagai engine, tidak ada fallback, tidak ada cloud. Halaman **SQL
  editor** dibuka dari tab Database (tombol *Open SQL editor* atau ikon terminal
  di app bar) maupun dari detail database: pilih schema, tulis statement,
  Execute / Clear, grid hasil, jumlah baris, durasi, diagnostik error, dan
  riwayat yang bisa diketuk untuk dipakai ulang.
- **File manager** di dalam `PALLSQL/`: list, buat, buka, edit, simpan, rename,
  copy, move, delete, import (document picker), export + share, multi-select,
  search, sort, ukuran file/folder.
- **Code editor**: HTML, CSS, JS, PHP, JSON, SQL, TXT, MD dengan line numbers,
  syntax highlight ringan, find & replace, undo/redo, indikator dirty,
  konfirmasi sebelum keluar, pengaturan font size, tema gelap.
- **Project manager**: template project (static site, PHP hello world, HTML
  form, database sample), duplicate, hapus dengan konfirmasi, ZIP export, ZIP
  import dengan proteksi zip-slip, validasi nama, metadata lokal.
- **Backup & restore**: ZIP dari project, htdocs, database, config dan log;
  validasi arsip sebelum restore; konfirmasi; export/share.
- **Log**: level `DEBUG/INFO/WARNING/ERROR`, sumber `APP/WEB/PHP/DATABASE/
  FILES/TERMINAL/BACKUP/NETWORK`, filter, pencarian, clear dengan konfirmasi,
  export. Log tidak menyimpan isi file atau token.
- **Terminal terbatas**: hanya perintah di registry (`help`, `clear`, `pwd`,
  `ls`, `projects`, `server status|start|stop|restart`, `logs`,
  `php version`, `database list|create|use|info`, `tables`, `desc`, `run`).
  Tidak ada `sh -c`, tidak ada shell bebas.
- **SQL console di terminal**: perintah `sql [schema]` masuk ke mode console
  yang mengirim statement ke server MariaDB yang sama dengan SQL editor.
  `.tables`, `.databases`, `.use`, `.read`, `.force on|off`, `.help` dan `\q`
  (keluar) tersedia, ditambah perintah shell `mariadb status|start|stop|restart|
  init|version|logs` yang melaporkan keadaan server apa adanya.
- **Metadata dijawab server sendiri**: `SHOW DATABASES`, `SHOW TABLES`,
  `DESCRIBE`, `SHOW CREATE TABLE`, `SHOW INDEX`, `SHOW STATUS`,
  `SELECT VERSION()`, `GRANT`, `SET`, transaksi, view, trigger, procedure —
  tidak ada lagi lapisan terjemahan ke SQLite. Klien tidak menerjemahkan SQL:
  yang dikirim adalah yang dieksekusi MariaDB. Detail:
  [`docs/sql-editor.md`](docs/sql-editor.md).
- **Tema & komponen 0.2**: palet hijau lembut (background `#101311`, accent
  `#9BCB91`), Material 3, tema gelap default + tema terang opsional, ukuran
  teks aplikasi, komponen bersama (`PallSQLAppBar`, `PallSQLButton`,
  `PallSQLCard`, `PallSQLTextField`, `PallSQLStatusBadge`, `PallSQLTerminal`,
  `PallSQLCodeEditor`, `PallSQLLoading`, `PallSQLDialog`,
  `PallSQLBottomNavigation`). Detail: [`docs/ui.md`](docs/ui.md).
- **Loading screen aplikasi**: logo, nama, "Mobile Development Environment",
  progres langkah bootstrap sungguhan (workspace → konfigurasi → log → device →
  PHP → runtime MariaDB → server MariaDB → project → environment), dan layar
  gagal dengan tombol Retry setelah batas waktu — bukan spinner tanpa akhir.
- **Halaman About**: aplikasi, versi, package, developer **pallxXx**, tombol
  *Visit Instagram* yang membuka tautan lewat `url_launcher`, kredit & lisensi
  (PHP, MariaDB Server GPLv2 yang dibangun dari source, paket Flutter, runtime
  native) tanpa klaim kepemilikan.
- **Workspace lengkap** di satu folder `PALLSQL/`: `htdocs/ projects/
  database/ (mariadb/data, data socket) config/ (php, server/mariadb.cnf,
  server/mariadb.json, queries) logs/ (app.log, mariadb-error.log) backups/
  tmp/ extensions/ terminal/`. Path lengkap ditampilkan di Dashboard dan Settings; tombol buka
  folder, export workspace ZIP, dan dokumentasi path nyata ada di
  [`docs/workspace.md`](docs/workspace.md).

## Status fitur

| Area | Status | Catatan |
| --- | --- | --- |
| UI tema gelap + Material 3 | Selesai | Komponen reusable: `PallSQLAppBar`, `ServerStatusCard`, `ServiceControlButton`, `TerminalOutput`, `DatabaseCard`, `ProjectCard`, `LogViewer`, `CodeEditorPanel`, `PALLSQLBottomNavigation` |
| HTTP server lokal | Selesai | Static file, MIME, 404/403/405/500, `Content-Length` persis, HTML `no-store`, ETag isi file, 304 hanya saat validator cocok, request log, port conflict, path traversal |
| SQL editor mandiri | Selesai | `SqlEditorPage`: pilih database, Execute/Clear, hasil + jumlah baris, error, riwayat, pembuatan database |
| **Engine database** | **MariaDB Server 10.11.9** | Satu-satunya engine; `libmariadbd.so` dibangun dari source di CI lalu dibundel dalam APK |
| File manager | Selesai | Sandboxed ke `PALLSQL/` |
| Code editor | Selesai | Highlight ringan, bukan IntelliSense/parser penuh |
| Project manager | Selesai | ZIP export/import aman |
| Backup & restore | Selesai | ZIP + validasi arsip |
| Log viewer | Selesai | Filter + export |
| Terminal terbatas | Selesai | Registry perintah, bukan shell |
| SQL console di terminal | Selesai | Mode `sql`, dot command, hasil tabel teks |
| Klien protokol MariaDB | Selesai (teruji di CI) | `SELECT VERSION()`, `SHOW DATABASES`, DDL/DML, prepared statement, multi-statement, error packet — diuji ke server MariaDB sungguhan di GitHub Actions |
| Migrasi data SQLite lama | Ada, opt-in | Tab Database → *Legacy SQLite data*: scan `PALLSQL/database/*.db`, import ke schema MariaDB, berkas asli tidak dihapus |
| Tema gelap/terang + ukuran teks | Selesai | Palet 0.2, Material 3, tanpa gradient berat |
| Loading screen + Retry | Selesai | Langkah bootstrap nyata, timeout, tanpa spinner tanpa akhir |
| Halaman About | Selesai | Developer, Instagram, kredit & lisensi |
| **Runtime PHP** | **Belum tersedia** | Request `.php` → HTTP 501; desain plugin `PhpBridge` siap dipasangi `php-cgi` native |
| **MariaDB di perangkat** | **Belum diuji di perangkat** | Binary sudah dibangun dan dipaketkan (CI hijau, `libmariadbd.so` ada di dalam APK), tetapi belum pernah dijalankan di HP/emulator. Kalau runtime tidak ada, aplikasi menampilkan *Not installed* dengan path yang diperiksa — tidak pernah `Running` palsu |
| Foreground service Android | Implementasi ada | Notification + `foregroundServiceType=dataSync`; lihat batasan Android |

## Tangkapan layar

Belum ada tangkapan layar yang dihasilkan dari perangkat nyata. Kalau Anda
menjalankan aplikasi, silakan tambahkan ke `docs/screenshots/` dan tautkan di
sini; kami tidak menambahkan mockup sebagai pengganti bukti.

## Teknologi

- Flutter 3.47.8 (stable), Dart 3.6+
- `flutter_riverpod` 2.6 sebagai satu-satunya state management
- `flutter_riverpod` + `archive` (ZIP), `path`, `path_provider`,
  `url_launcher`; `sqflite_common_ffi` hanya dipakai oleh test dan
  `sqflite` hanya oleh pembaca data SQLite lama (read-only)
- Klien MariaDB ditulis sendiri di `lib/services/mariadb/` (tanpa
  Connector/C, tanpa paket protokol pihak ketiga)
- Android native: Kotlin (`MainActivity`, `PallsqlForegroundService`), method
  channel `com.pallsql.mobile/native`
- AGP 9.1.0, Gradle 9.3.1, Kotlin 2.4.0, compileSdk 36, minSdk 24, targetSdk 36

## Struktur repositori

```
lib/
  core/
    constants/    AppInfo (nama, versi, port default, folder workspace)
    errors/       AppFailure dan turunannya
    theme/        PallSqlColors, PallSqlTheme
    utils/        PathGuard, Validators, Formatters, SqlUtils
  models/         ServiceStatus, LogEntry, Project, DatabaseModels,
                  AppSettings, FileEntry, BackupInfo
  repositories/   Log, Settings, Database (MariaDB), File, Project
  services/       WebServerService, PhpRuntimeService, BackupService,
                  TerminalService, WorkspaceService, NativeBridge,
                  AppBootstrap, MimeTypes, LinkOpener, SqlCompatibility,
                  QueryStore
  providers/      app_providers.dart (Riverpod graph)
  widgets/        komponen UI reusable (PallSQLAppBar, PallSQLButton,
                  PallSQLCard, PallSQLTextField, PallSQLStatusBadge,
                  PallSQLTerminal, PallSQLCodeEditor, PallSQLLoading,
                  PallSQLDialog, PallSQLBottomNavigation)
  features/       dashboard, servers, php, database, files, editor,
                  projects, logs, terminal, backups, settings, shell,
                  startup, about
android/          host Android (Kotlin, manifest, Gradle KTS)
test/             unit, service, repository, dan widget test
docs/             architecture, http-server, sql-editor, ui, workspace,
                  release
```

## Perubahan 0.2.0

- **UI/tema**: palet hijau lembut (bukan neon), Material 3, tema gelap default
  + tema terang opsional, pengaturan ukuran teks, komponen bersama baru.
- **Startup**: layar loading berbranding dengan progres langkah bootstrap nyata
  dan layar gagal + Retry setelah batas waktu.
- **SQL editor**: picker database + engine, Execute / Stop (aman di batas
  statement) / Clear / Format, Save & Load query, riwayat, durasi, jumlah baris,
  tab hasil & pesan, copy/export CSV, mode fullscreen.
- **Terminal**: SQL console nyata (`sql [database]`, dot command, `\q`) dan
  perintah baru `use`, `tables`, `desc`, `run`, `storage`, `version`.
- **Metadata tidak lagi diterjemahkan**: `SHOW ...`, `DESCRIBE`,
  `SELECT VERSION()` dijawab oleh MariaDB yang berjalan di perangkat.
- **Halaman About** dengan developer, tautan Instagram yang berfungsi, kredit &
  lisensi.
- **CI**: laporan kegagalan kini menyebut nama test yang gagal beserta konteks
  assertion langsung di anotasi job.

## Menjalankan secara lokal

Prasyarat:

- Flutter 3.47.8 (stable) dan Dart yang menyertainya
- JDK 17
- Android SDK dengan `compileSdk 36` dan satu device/emulator API 24+

```bash
flutter doctor
flutter pub get
flutter test
flutter run -d <device-id>
```

`android/local.properties` (berisi `flutter.sdk` dan `sdk.dir`) dibuat otomatis
oleh tooling Flutter dan tidak boleh di-commit.

## Build APK

```bash
flutter build apk --debug
flutter build apk --release
```

Hasil ada di `build/app/outputs/flutter-apk/`. Build release di repo ini
memakai debug signing key agar APK langsung bisa dipasang untuk pengujian.
Lihat [docs/release.md](docs/release.md) untuk cara mengganti dengan keystore
pribadi.

## GitHub Actions dan artefak

Workflow [`.github/workflows/android.yml`](.github/workflows/android.yml)
berjalan pada `push` dan `pull_request` ke `main` serta `workflow_dispatch`:

1. **Job `quality`** — set up JDK 17 + Flutter 3.47.8 (cache aktif),
   `flutter pub get`, `flutter analyze`, `flutter test`, lalu cek format
   (`dart format --output=none --set-exit-if-changed .`) sebagai gerbang
   terakhir. Kalau formatter menemukan drift, CI menerapkan `dart format` dan
   meng-commit hasilnya ke branch PR; bila token tidak boleh push, patch persis
   hasil formatter dipublikasikan sebagai komentar PR agar bisa di-`git apply`.
2. **Job `apk`** — `flutter pub get`, restore Gradle wrapper bila belum ada,
   `flutter build apk --debug`, `flutter build apk --release`, verifikasi file
   APK benar-benar ada dan berukuran wajar (≥ 1 MB), lalu upload artefak
   bernama **`PALLSQL-Android-APK`** (debug + release + `SHA256SUMS.txt`,
   retensi 30 hari). Log build di-upload bila terjadi kegagalan.

Mengunduh artefak:

```bash
gh run list --workflow=android.yml --limit 5
gh run download <run-id> -n PALLSQL-Android-APK -D apk
```

Permissions workflow dibatasi ke `contents: read`; tidak ada secret yang
dipakai untuk build APK.

## Membuat release

```bash
git tag -a v0.1.0 -m "PALLSQL 0.1.0"
git push origin v0.1.0
```

Tag `v*.*.*` memicu [`.github/workflows/release.yml`](.github/workflows/release.yml):
analyze, test, build release APK, verifikasi ukuran, lalu membuat GitHub Release
dengan APK + checksum terlampir. Bila build gagal, release tidak dibuat.

## Arsitektur runtime PHP

PHP **tidak** dikirim sebagai source code ke browser. `WebServerService`
mendeteksi ekstensi `.php` dan memanggil `PhpBridge`:

1. `ProcessPhpRuntime` mencari binary `php-cgi` di:
   path konfigurasi pengguna (relatif, di dalam workspace), `config/php/php-cgi`,
   `config/php/php`, `config/php/bin/php-cgi`, lalu
   `nativeLibraryDir/libphp-cgi.so` / `libphp.so`.
2. Bila tidak ada runtime, `NullPhpBridge` mengembalikan halaman `501` yang
   menjelaskan cara memasang runtime — source PHP tidak pernah dikirim.
3. Bila runtime ada, request diterjemahkan menjadi environment CGI standar
   (`REQUEST_METHOD`, `SCRIPT_FILENAME`, `QUERY_STRING`, …), dijalankan dengan
   `Process.start` (tanpa shell), output diparse menjadi status + header + body.

Detail kontrak packaging, ABI, dan lisensi ada di
[docs/php-runtime.md](docs/php-runtime.md). Sampai binary PHP untuk ABI
perangkat benar-benar dibundel dan diuji, fitur PHP tetap berstatus
**Unavailable** di UI.

## Dukungan database

- **MariaDB Server adalah satu-satunya engine.** Server `mariadbd` 10.11.9
  dibangun dari source MariaDB resmi di CI
  (`.github/workflows/mariadb-android.yml`), divalidasi `readelf` sebagai
  AArch64, di-strip, lalu dipaketkan sebagai
  `jniLibs/arm64-v8a/libmariadbd.so` + aset bootstrap SQL/charset/pesan error.
  Aplikasi menjalankan binary itu lewat `MariaDbProcessManager.kt`, menginisialisasi
  data directory sekali, dan berkomunikasi lewat klien protokol MariaDB sendiri
  (`lib/services/mariadb/`).
- **Tidak ada fallback.** Kalau runtime tidak ada atau gagal start, aplikasi
  menampilkan *Not installed* / pesan error dengan path yang diperiksa. Tidak
  ada SQLite, tidak ada database cloud, tidak ada hasil query palsu.
- **SQLite hanya tersisa sebagai pembaca data lama.** Berkas `.db` dari versi
  0.1/0.2 dapat dipindai (read-only) lewat tab Database → *Legacy SQLite data*
  dan disalin ke schema MariaDB atas permintaan pengguna; berkas asli tidak
  pernah dihapus otomatis.
- **Konfigurasi server di UI**: port 3306, bind `127.0.0.1` (LAN harus
  diaktifkan eksplisit), Unix socket, charset/collation, `max_connections`,
  buffer pool/InnoDB log, akun admin. Nilai disimpan di
  `PALLSQL/config/server/mariadb.json` (chmod 600) dan ditulis ke
  `mariadb.cnf`; password tidak pernah masuk log.
- **Detail teknis lengkap**: [`docs/mariadb-android.md`](docs/mariadb-android.md).

## Keamanan local server

- Default bind ke `127.0.0.1` saja. Opsi LAN (`0.0.0.0`) harus dinyalakan
  eksplisit di Settings dan menampilkan peringatan.
- Document root dibatasi pada `PALLSQL/htdocs` atau folder project aktif.
- Path traversal ditolak setelah decode ganda (`%2e%2e`, `%252e%252e`, `..%5c`),
  NUL byte, drive letter, dan dotfile.
- Symlink yang mengarah keluar document root ditolak.
- Directory listing dimatikan (403), hanya `index.html`/`index.htm`/`index.php`
  yang disajikan sebagai index.
- Metode selain `GET`/`HEAD` dijawab `405`.
- Body request dibatasi 8 MB; file PHP tidak pernah disajikan sebagai teks.
- File internal aplikasi (`config/`, `logs/`, `database/`) tidak berada di
  document root kecuali dipilih sebagai project.

## Batasan Android

- Android dapat menghentikan proses saat aplikasi di background. Foreground
  service + notifikasi dipakai saat server aktif, tetapi Doze/optimasi baterai
  dari vendor tetap bisa mematikan proses. Saat itu terjadi, server berhenti
  dan status di dashboard kembali ke `stopped` (tidak ada status palsu).
- Tidak ada root, tidak ada Termux, tidak ada eksekusi shell bebas.
- Android 13+ meminta izin notifikasi untuk menampilkan notifikasi server.
- Server hanya menerima koneksi dari device itu sendiri (atau LAN bila
  diaktifkan). `localhost` di browser HP lain tidak akan menunjuk ke device ini.

## Troubleshooting

| Gejala | Penyebab umum | Solusi |
| --- | --- | --- |
| `Port 8080 is already in use` | Aplikasi lain memakai port tersebut | Ganti port di Settings (1024–65535) |
| Halaman `.php` menampilkan "PHP runtime not installed" | Belum ada `php-cgi` | Lihat [docs/php-runtime.md](docs/php-runtime.md) |
| Dashboard tetap "Stopped" setelah start | Bind gagal / proses dimatikan OS | Cek log WEB di tab Logs |
| `flutter build apk` gagal di Gradle wrapper | `gradlew` tidak di-commit | CI membuat ulang; lokal: `flutter create --platforms=android .` di folder sementara lalu copy `gradlew` |
| Test gagal dengan `databaseFactory not initialized` | FFI belum di-init | Sudah ditangani `sqfliteFfiInit()` di `test/support/test_bootstrap.dart` |
| MariaDB *Not installed* di aplikasi | APK dibangun tanpa artefak runtime native | Jalankan workflow **MariaDB Android runtime**, lalu build ulang APK (CI mengambil artefak terakhir yang sukses) |
| Test integrasi MariaDB di-skip | `PALLSQL_MARIADB_IT` tidak di-set | CI menyalakan server sungguhan; lokal: jalankan `mariadb-server` lalu set variabel itu |

## Lisensi runtime

- Kode PALLSQL: MIT (lihat [LICENSE](LICENSE)).
- Flutter/Dart: BSD-3-Clause.
- MariaDB Server: GPLv2, dibangun dari source resmi (versi, sha256 dan
  ringkasan build tercatat di artefak `native/report/mariadb-build.md`).
- sqflite: BSD-2-Clause; SQLite: Public Domain (hanya untuk membaca data lama).
- archive (Dart): MIT.
- url_launcher, path, path_provider: BSD-3-Clause.
- Runtime PHP (bila nanti dibundel) akan mengikuti PHP License 3.01 beserta
  lisensi pustaka yang di-link; detail dan kewajiban atribusi ada di
  [docs/php-runtime.md](docs/php-runtime.md).

---

## English summary

PALLSQL is an offline, Android-only, XAMPP-like web development environment
written in Flutter/Dart with a thin Kotlin host layer. It runs a real local
HTTP server and a real **MariaDB Server 10.11.9** that is cross compiled from
the official source with the Android NDK and shipped inside the APK, plus a
sandboxed file manager and editor, project templates with safe ZIP
import/export, ZIP backups, structured logs and a restricted command registry
instead of a shell.

**What actually works today:** static site hosting on `127.0.0.1:8080`
(configurable), path-traversal and symlink protection, SQL editor and SQL
console that speak the MariaDB wire protocol to that server, consistent
snapshot backups, file management inside `PALLSQL/`, code editing, project and
backup management, log filtering/export, restricted terminal, opt-in import of
legacy SQLite files.

**Verified in CI, not on a phone:** the native build produces an AArch64
`libmariadbd.so` (validated with `readelf`, stripped, packaged in the APK), and
the Dart protocol client is tested against a real MariaDB server in GitHub
Actions. **Nothing has been run on a physical device or emulator yet**, so the
app shows the runtime state it can actually prove.

**What is not implemented:** a PHP interpreter (requests to `.php` return
`501` with an explanation and never leak source). No fake status indicators:
every service state comes from the real runtime.

CI (`.github/workflows/android.yml`) builds a debug and a release APK on every
push to `main` and uploads them as the `PALLSQL-Android-APK` artifact. Tagging
`v*.*.*` publishes a GitHub Release with the APK attached. Release APKs are
signed with the debug key so they are installable but not store-ready.

---

### Status verifikasi

Pipeline CI pada repositori ini sudah diverifikasi berjalan (lihat tab Actions):

- `flutter analyze`: **No issues found**
- `flutter test`: **lebih dari 170 test lulus** (unit, service, repository, dan
  widget), termasuk uji layout yang merender setiap tab dan setiap layar pada
  permukaan 360x780 dp, uji SQL editor (eksekusi query, error, riwayat,
  navigasi, pembuatan database dari editor), uji compatibility layer
  (`SHOW DATABASES`/`SHOW TABLES`/`DESCRIBE`/`SHOW CREATE TABLE`/`SHOW INDEX`
  dari metadata SQLite nyata, perintah tak didukung), uji SQL console terminal
  (mode `sql`, dot command, guard `.force`, data benar-benar tersimpan), uji
  loading screen/Retry, uji tema 0.2 + kontras, uji HTTP server (panjang body,
  304 hanya saat cocok, 404 index hilang, port bentrok), dan uji SQLite
  (CREATE/INSERT/SELECT + data bertahan setelah koneksi ditutup)
- `dart format --output=none --set-exit-if-changed .`: **bersih**
- `flutter build apk --debug` dan `--release`: **berhasil**, artefak
  `PALLSQL-Android-APK` terunggah (debug + release + checksum)
- `release.yml` pada tag `v0.1.0`, `v0.1.1`, `v0.1.2` dan `v0.2.0`:
  **berhasil** membuat GitHub Release dengan APK dan `SHA256SUMS.txt`
  (release `v0.2.0`: `PALLSQL-v0.2.0.apk`, 27.399.399 byte)

Yang **belum** diverifikasi karena keterbatasan lingkungan: aplikasi belum
pernah dijalankan di device/emulator Android sungguhan (tidak ada emulator di
lingkungan build ini), sehingga perilaku runtime seperti foreground service,
document picker, dan share sheet baru diverifikasi lewat build dan test, bukan
lewat uji perangkat.

---

Dibuat dan dirawat sebagai eksperimen teknis; kontribusi dan laporan bug
dipersilakan lewat GitHub Issues.
