# Laporan PALLSQL 0.3.0 — Native MariaDB Android Edition

Dokumen ini mencatat **apa yang benar-benar ada, apa yang sudah dibuktikan, dan
apa yang belum**. Tidak ada status yang dikarang: setiap klaim di bawah bisa
ditelusuri ke file, workflow run, atau artifact di repositori.

Versi: `0.3.0+5` (`pubspec.yaml`, `lib/core/constants/app_info.dart`) ·
Package: `com.pallsql.mobile` · Developer: **pallxXx** ·
Tautan Instagram: <https://www.instagram.com/pallemnih_?psln=MWNud3gxOHBvNTIyZw==>

---

## 1. Arsitektur

```
                    +-------------------------------+
   Flutter UI  ---> |  repositories/database_repository.dart (MariaDbRepository)
                    +---------------+---------------+
                                    |  SQL / dump / KILL QUERY
                    +---------------v---------------+
                    |  services/mariadb/             |
                    |  mariadb_client  (antrean)     |
                    |  mysql_connection (socket)     |
                    |  mysql_protocol   (v10, SHA-1) |
                    |  mysql_values     (tipe kolom) |
                    +---------------+---------------+
                                    |  TCP 127.0.0.1:3306 atau Unix socket
                    +---------------v---------------+
                    |  mariadbd 10.11.9 (native AArch64, libmariadbd.so)
                    |  dijalankan MariaDbProcessManager.kt (exec, bukan shell)
                    +-------------------------------+
```

* **Tidak ada SQLite** di jalur data. Satu-satunya sisa SQLite adalah
  `services/legacy_sqlite_migration.dart`, yang membuka file `.db` lama
  **read-only** dan hanya jalan bila pengguna menekan *Scan* lalu *Import*.
* **Tidak ada cloud, tidak ada mock, tidak ada Connector/C.** Klien protokol
  ditulis di Dart (`lib/services/mariadb/`), server adalah binary MariaDB asli.
* Satu server dipakai bersama oleh dashboard, Database manager, SQL editor,
  terminal (`sql …`), dan status di Settings/PHP.

### Siklus hidup server

`MariaDBServiceManager` (`lib/services/mariadb/mariadb_service.dart`) adalah
satu-satunya pemilik:

| Kemampuan | Implementasi |
| --- | --- |
| Init data dir sekali | `initialize()` → `--bootstrap` dengan aset `mysql_system_tables*.sql` |
| Start / stop / restart | `start()`, `stop()` (SIGTERM → SIGKILL), `restart()` |
| Status jujur | state hanya `running` setelah probe protokol sungguhan (`_probe`) |
| Deteksi crash & recovery | `recover()`, `refresh()`, `killStale()` di sisi Kotlin |
| Konflik port | `isPortFree()` sebelum start |
| Log error | `logs/mariadb-error.log` + `readErrorLogTail()` |
| Konfigurasi | `config/server/mariadb.json` (chmod 600) + `mariadb.cnf` |

State yang dipakai UI: `notInstalled`, `stopped`, `initializing`, `starting`,
`running`, `stopping`, `error`.

---

## 2. File yang berubah / bertambah (ringkas)

Lapisan MariaDB:

| File | Isi |
| --- | --- |
| `lib/services/mariadb/mysql_protocol.dart` | konstanta capability/command/type, reader/writer, OK/ERR/EOF, kolom, handshake v10, `nativePasswordScramble` |
| `lib/services/mariadb/mysql_values.dart` | decode nilai text/binary, `quoteIdentifier`, `quoteLiteral`, `MysqlParam` |
| `lib/services/mariadb/mysql_connection.dart` | koneksi TCP/socket, text protocol, prepared statement, batch multi-statement |
| `lib/services/mariadb/mariadb_client.dart` | antrean serial, satu percobaan ulang, `query`/`execute`/`ping`/`reconfigure` |
| `lib/services/mariadb/mariadb_config.dart` | validasi config, `toCnf`, `MariaDbConfigStore` |
| `lib/services/mariadb/mariadb_service.dart` | `MariaDBServiceManager`, `MariaDbStatus`, `MariaDbRuntimeInfo` |
| `lib/services/legacy_sqlite_migration.dart` | scan + impor read-only data SQLite lama |
| `lib/repositories/database_repository.dart` | semua operasi SQL lewat protokol MariaDB, dump konsisten, `KILL QUERY` |
| `lib/repositories/database_contract.dart` | kontrak repository yang dipakai UI |
| `lib/services/sql_compatibility.dart` | tinggal label dialek; `SqlCompatibility.parse()` sengaja `null` |

Native dan build:

| File | Isi |
| --- | --- |
| `android/app/src/main/kotlin/com/pallsql/mobile/MariaDbProcessManager.kt` | runtime info, init, start, stop, status, kill stale |
| `android/app/src/main/kotlin/com/pallsql/mobile/MainActivity.kt` | 6 method `mariadb*` di channel native |
| `lib/services/native_bridge.dart` | pembungkus Dart untuk method di atas |
| `.github/workflows/mariadb-android.yml` | pipeline build server MariaDB untuk Android |
| `native/patches/apply_android_patches.py` | patch portabilitas (juga dipakai untuk verifikasi lokal) |
| `.github/workflows/android.yml` | ambil artifact native, staging, verifikasi isi APK, analyze + test |

UI:

| File | Isi |
| --- | --- |
| `lib/features/settings/mariadb_config_page.dart` | layar konfigurasi server (port, bind, socket, charset, buffer, akun, start/stop/restart, log) |
| `lib/features/database/legacy_data_card.dart` | kartu *Legacy SQLite data* (scan + import opt-in) |
| `lib/features/database/database_page.dart` | status server, daftar schema, tombol ke editor/terminal, kartu legacy |
| `lib/features/servers/servers_page.dart`, `lib/features/terminal/terminal_page.dart`, `lib/features/settings/settings_page.dart`, `lib/widgets/database_card.dart` | istilah dan status mengikuti MariaDB, tanpa klaim SQLite |
| `lib/services/terminal_service.dart` | `mariadb status|start|stop|restart|init|version|logs`, SQL console ke server yang sama |
| `lib/features/startup/pallsql_splash.dart` | langkah loading mengikuti bootstrap yang nyata |

Dokumentasi: `docs/mariadb-android.md` (arsitektur, build, risiko Bionic, status
verifikasi), `README.md` (diperbarui total untuk 0.3), dan laporan ini.

Test: `test/mariadb_protocol_test.dart`, `test/mariadb_integration_test.dart`,
`test/sql_compatibility_test.dart`, `test/sql_editor_page_test.dart`,
`test/terminal_sql_test.dart`, `test/support/test_bootstrap.dart`.

---

## 3. Binary native dan ABI

| Item | Nilai |
| --- | --- |
| Versi MariaDB | 10.11.9 (source resmi `archive.mariadb.org`) |
| ABI yang dibangun | `arm64-v8a` (AArch64) |
| ABI yang belum | `armeabi-v7a` (tidak dibangun; APK hanya untuk perangkat 64-bit) |
| NDK | 27.0.12077973, `ANDROID_PLATFORM=android-24` |
| CMake | 3.22.1 dari Android SDK + `-DCMAKE_POLICY_DEFAULT_CMP0057=NEW` |
| Storage engine | InnoDB (+ Aria untuk tabel sistem); MyISAM/MRG dimatikan |
| Validasi | `readelf -h` = AArch64, `readelf -d` dicatat, lalu `llvm-strip` |
| Ukuran `.so` di APK | 26 MB (uncompressed) |
| Artifact | `mariadb-runtime-arm64-v8a` (server + aset + `readelf`) |

Patch source yang dipakai (semuanya **konfigurasi build**, bukan logika server),
tercatat di `native/patches/apply_android_patches.py`:

1. probe `MYSQL_CHECK_READLINE()` dilewati di Android (tidak ada ncurses di NDK);
2. plugin `MRG_MyISAM` (MANDATORY upstream) tidak disertakan;
3. `pcre2` ExternalProject diberi toolchain/ABI Android (kalau tidak, pcRE
   dibangun untuk host x86-64 dan link gagal);
4. Connector/C tidak memaksa GnuTLS di Android (PALLSQL tidak memakai
   Connector/C).
5. `native/android-flags.cmake` memaksa header POSIX (`ctype.h`, `pwd.h`,
   `unistd.h`, …) yang tidak otomatis ikut di Bionic;
6. fakta libc Bionic (`HAVE_ALARM`, `HAVE_MKSTEMP`, `HAVE_MEMMOVE`, …) dikirim
   sebagai **cache variable** karena `check_function_exists` tidak bisa dipakai
   di toolchain ini — ini juga menentukan file mana yang dikompilasi;
7. `HAVE_UINT` dikoreksi di `my_config.h` karena Bionic tidak punya
   `typedef unsigned int uint`.

---

## 4. Hasil GitHub Actions (yang benar-benar dijalankan)

| Workflow | Run | Hasil |
| --- | --- | --- |
| MariaDB Android runtime | `40990066614` | **sukses** — build `mariadbd` penuh: configure, host tools, kompilasi, validasi AArch64, strip, paket aset, upload artifact |
| MariaDB Android runtime | `40991906330` | **sukses** — build yang artifact-nya dipakai APK terakhir (`commit a86a473`) |
| Android CI — Analyze and test | `40992656414` | **sukses** — `flutter analyze` tanpa issue, seluruh test lulus (server MariaDB sungguhan dinyalakan CI), `dart format` bersih |
| Android CI — Build APKs | `40992656414` | **sukses** — debug + release APK, runtime native diambil lewat REST API, isi APK diverifikasi (`.so` + aset bootstrap) |

Catatan penting: test integrasi MariaDB **tidak** di-skip di CI. Job gagal kalau
suite itu tidak jalan (`SKIPPED: set PALLSQL_MARIADB_IT`).

---

## 5. Ukuran APK (dari artifact run `40992656414`)

| APK | Ukuran | Runtime MariaDB di dalamnya |
| --- | --- | --- |
| `PALLSQL-release.apk` | 36.451.628 byte (±35 MB) | `lib/arm64-v8a/libmariadbd.so` 26 MB |
| `PALLSQL-debug.apk` | 90.939.137 byte (±87 MB) | `lib/arm64-v8a/libmariadbd.so` 26 MB |

Artifact: `PALLSQL-Android-APK` (berisi dua APK + `SHA256SUMS.txt`).

APK diambil dari:
<https://github.com/HOOOOOOQ/pallsql/actions> → run **Android CI** terakhir →
artifact **PALLSQL-Android-APK**. (Artifact GitHub Actions butuh login; release
bertag akan melampirkan APK yang sama.)

---

## 6. Uji perangkat — BELUM DILAKUKAN

Belum ada perangkat fisik maupun emulator yang menjalankan PALLSQL 0.3. Karena
itu checklist acceptance berikut **belum** dicentang, dan aplikasi tidak
mengklaimnya:

| # | Langkah acceptance | Status |
| --- | --- | --- |
| 1 | Binary dijalankan dari `nativeLibraryDir` | belum diuji |
| 2 | Inisialisasi data directory (`--bootstrap`) | belum diuji |
| 3 | Start / stop / restart dari UI | belum diuji |
| 4 | Koneksi lokal (`127.0.0.1:3306` / socket) | belum diuji di perangkat (klien teruji di CI ke server desktop) |
| 5 | `SELECT VERSION()` | teruji di CI, belum di perangkat |
| 6 | `SHOW DATABASES` | teruji di CI, belum di perangkat |
| 7 | `CREATE DATABASE palltest`, `USE` | teruji di CI, belum di perangkat |
| 8 | CREATE TABLE, INSERT/SELECT, UPDATE/DELETE | teruji di CI, belum di perangkat |
| 9 | Editor dan terminal memakai schema yang sama | teruji di CI (widget + service test) |
| 10 | PHP ↔ MariaDB (`pdo_mysql`) | belum — runtime PHP belum dibundel |
| 11 | Persistensi setelah restart aplikasi | belum diuji |
| 12 | Backup / restore | logika ada, belum diuji di perangkat |
| 13 | APK memuat runtime | **terbukti di CI** (isi APK diperiksa otomatis) |

Konsekuensinya: status di aplikasi tetap **Not installed** bila APK dibangun
tanpa artifact runtime, dan **Running** hanya setelah probe protokol berhasil —
tidak ada state palsu.

---

## 7. Batasan yang masih ada

1. **Belum ada uji perangkat.** Ini batasan terbesar dan tidak bisa ditutupi
   dokumentasi.
2. **Hanya `arm64-v8a`.** Perangkat 32-bit tidak bisa menjalankan server.
3. **`armeabi-v7a` belum dibangun** (ruang lingkup tahap ini).
4. **Source pin belum diverifikasi checksum-nya.** `MARIADB_SHA256` masih
   kosong; workflow mencatat hash yang diamati di build report dan memberi
   peringatan. Bila diisi, mismatch akan **menggagalkan** build.
5. **Runtime PHP belum ada**, jadi `pdo_mysql`/`mysqli` belum bisa dipakai; tab
   PHP melaporkan ketiadaannya, bukan status palsu.
6. **`mariadbd` belum pernah dijalankan di Android**, sehingga hal-hal seperti
   permission data dir di scoped storage, `--bootstrap` dengan aset APK, dan
   penggunaan memori InnoDB di HP belum terbukti.
7. **Bionic tetap sumber risiko**: setiap kegagalan kompilasi yang ditemukan
   sudah diperbaiki di level build (lihat daftar patch), tetapi kode yang belum
   pernah dieksekusi bisa memunculkan masalah runtime (mis. `sigwait`, thread,
   `O_DIRECT`).
8. **Backup** memakai dump konsisten (bukan menyalin file data hidup), dan
   restore tidak bisa di-rollback karena MariaDB melakukan commit implisit pada
   DDL — UI menyatakan ini.
9. **Bukan kesiapan Play Store**: APK release ditandatangani debug key.

---

## 8. Cara mereproduksi

```bash
# 1. Bangun runtime native (GitHub Actions)
#    workflow_dispatch / push ke native/** → "MariaDB Android runtime"
# 2. Build APK (otomatis mengambil artifact runtime terakhir yang sukses)
#    workflow "Android CI" → job "Build APKs"
# 3. Verifikasi lokal patch source (opsional)
python3 native/patches/apply_android_patches.py /path/ke/mariadb-10.11.9
```

Pemeriksaan lokal cepat untuk kode Dart di sandbox ini: `python3
scripts/dart_sanity.py lib test` (hanya sintaks, bukan analyzer).
