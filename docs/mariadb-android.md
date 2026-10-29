# MariaDB di Android (PALLSQL 0.3)

Dokumen ini menjelaskan arsitektur database PALLSQL setelah migrasi ke MariaDB
Server asli, apa yang **sudah** berjalan, dan apa yang **belum** diverifikasi.
Tidak ada klaim yang melebihi isi dokumen ini.

## 1. Keputusan arsitektur

| Komponen | Implementasi |
| --- | --- |
| Database engine | **MariaDB Server** (`mariadbd`) yang dijalankan sebagai proses native di HP |
| Klien | Implementasi protokol MariaDB di Dart (`lib/services/mariadb/`) |
| SQLite | **Bukan engine aplikasi.** Hanya dipakai oleh `LegacySqliteMigration` untuk membaca berkas lama secara read-only |
| Proot / distro Linux | Tidak dipakai |
| Database cloud / API eksternal | Tidak dipakai |
| ABI target | `arm64-v8a` (wajib), `armeabi-v7a` (opsional) |

Alasan klien protokol sendiri (bukan Connector/C atau Connector/J):

* MariaDB tidak menyediakan paket pub.dev, jadi UI Flutter tidak bisa memanggil
  server tanpa lapisan native;
* JNI + Connector/C berarti dua ABI library native tambahan (libmariadb,
  libssl, libcrypto) yang harus dibangun ulang untuk Bionic;
* protokol MySQL/MariaDB (protocol 10) sudah stabil dan terdokumentasi, dan
  PALLSQL hanya butuh `COM_QUERY`, `COM_INIT_DB`, `COM_PING`, `COM_QUIT`,
  `COM_STMT_*` — cukup kecil untuk diimplementasikan dengan benar dan diuji.

Konsekuensinya: **tidak ada** SQLite, tidak ada mock, dan tidak ada fallback.
Kalau server tidak berjalan, repository mengembalikan error sungguhan dari
server (atau `Unavailable` saat benar-benar tidak ada koneksi).

## 2. Peta kode

```
lib/services/mariadb/
  mysql_protocol.dart   handshake, packet, tipe kolom, SHA-1 + mysql_native_password
  mysql_values.dart     encoding/decoding nilai (text + binary), quoting, parameter
  mysql_connection.dart socket, COM_* commands, prepared statement, KILL QUERY
  mariadb_client.dart   satu koneksi serial, auto-reconnect sekali, status server
  mariadb_config.dart   konfigurasi server (port, bind, charset, buffer, socket)
  mariadb_service.dart  MariaDBServiceManager: lifecycle + status nyata
lib/repositories/
  database_contract.dart  antarmuka DatabaseRepository
  database_repository.dart MariaDbRepository (SQL nyata ke server)
lib/services/legacy_sqlite_migration.dart
                        pemindai + migrator berkas .db lama (read-only)
android/app/src/main/kotlin/com/pallsql/mobile/
  MariaDbProcessManager.kt  exec mariadbd, bootstrap, SIGTERM/SIGKILL, pid
```

## 3. Lifecycle server

`MariaDBServiceManager` adalah satu-satunya pemilik proses:

| Aksi | Yang benar-benar terjadi |
| --- | --- |
| `refreshRuntime()` | memeriksa `nativeLibraryDir/libmariadbd.so` untuk ABI aktif |
| `initialize()` | `mariadbd --bootstrap` dengan SQL sistem; **dilewati** bila `ibdata1` sudah ada |
| `start()` | exec `mariadbd`, lalu menunggu handshake nyata (maks 10 detik) |
| `stop()` | `SHUTDOWN` lewat protokol, lalu SIGTERM, lalu SIGKILL bila perlu |
| `refresh()` | `SELECT VERSION()` + `SHOW STATUS LIKE 'Uptime'` |
| `recover()` | membersihkan pid yatim (hanya bila cmdline-nya `mariadbd`), lalu start |

Status yang ditampilkan: `Not installed`, `Stopped`, `Initializing`, `Starting`,
`Running`, `Stopping`, `Error`. `Running` hanya muncul setelah koneksi protokol
berhasil, bukan setelah `Process.start()`.

Data directory: `PALLSQL/database/mariadb/data`. Bila Android menolak lokasi
tersebut, proses memakai `filesDir/mariadb/data` dan path sebenarnya
ditampilkan di UI serta terminal (`mariadb status`). Direktori yang sudah berisi
data **tidak pernah** diinisialisasi ulang.

## 4. Konfigurasi

`PALLSQL/config/server/mariadb.cnf` dihasilkan dari `MariaDbConfigStore`, dan
`mariadb.json` menyimpan pengaturan aplikasi (termasuk kredensial, dengan
`chmod 600` bila filesystem mendukung).

Default aman:

* port `3306`, bind `127.0.0.1` (bukan `0.0.0.0`);
* `utf8mb4` / `utf8mb4_unicode_ci`;
* `max_connections = 20`, `innodb_buffer_pool_size = 32M`;
* `skip-name-resolve`, `local-infile = 0`, `secure-file-priv = NULL`;
* password tidak pernah ditulis ke log; `describe()` hanya menampilkan
  `user@host:port`.

Bind ke alamat non-loopback ditolak sampai pengguna mengaktifkan "Share on LAN".

## 5. Build native

Workflow: `.github/workflows/mariadb-android.yml`.

1. Unduh `https://archive.mariadb.org/mariadb-<versi>/source/mariadb-<versi>.tar.gz`
   dan verifikasi SHA-256 (`MARIADB_SHA256`).
2. Cross-compile dengan NDK 27 dan toolchain CMake Android:
   `-DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24`.
3. Build hanya target `mariadbd`, dengan plugin yang tidak dibutuhkan
   dimatikan (ARCHIVE, FEDERATEDX, CONNECT, SPHINX, S3, MROONGA, WSREP,
   TOKUDB, MARIABACKUP, embedded server).
4. **Validasi** keluaran: `readelf -h` harus `AArch64`, `readelf -d` dicatat
   untuk melihat `NEEDED`/`RPATH`.
5. Paketkan sebagai `jniLibs/arm64-v8a/libmariadbd.so` (di-extract Android
   karena `useLegacyPackaging = true`) plus aset bootstrap
   (`assets/mariadb/*.sql`, charsets, error messages).
6. Unggah artifact `mariadb-runtime-arm64-v8a`; job APK mengambil artifact itu.

### Komponen yang paling mungkin bermasalah saat porting

| Komponen | Risiko di Bionic | Rencana |
| --- | --- | --- |
| `getpwnam`/`getgrnam` | Android tidak punya `/etc/passwd` | dihindari dengan `--user=` dan `skip-name-resolve` |
| `setuid`/`setgid` | aplikasi tidak boleh menurunkan privilege | tidak dipakai; server berjalan sebagai uid aplikasi |
| `pthread_setname_np`, `dl_iterate_phdr` | tersedia sejak API 21/24 | OK di `minSdk 24` |
| `Locale`/`nl_langinfo` | terbatas | `--lc-messages-dir` menunjuk ke aset, bukan locale sistem |
| Plugin autentikasi (PAM, unix_socket) | butuh PAM | hanya `mysql_native_password` yang dipakai |
| Charset/collation kompleks (`uca1400`) | butuh ICU | build memakai `utf8mb4_unicode_ci` |
| `mysqld_safe`, script shell | tidak ada `bash` | lifecycle ditangani Kotlin, bukan script |
| InnoDB + `O_DIRECT` | tidak didukung di sebagian storage | `innodb_flush_method = fsync` |

## 6. Status verifikasi (jujur)

| Hal | Status |
| --- | --- |
| Klien protokol (handshake, text protocol, prepared statement, error packet) | **Teruji otomatis** terhadap server MariaDB sungguhan di CI (`test/mariadb_integration_test.dart`) |
| Repository SQL (CREATE DATABASE, USE, DDL, INSERT/SELECT/UPDATE/DELETE, multi-statement, DESCRIBE, SHOW CREATE TABLE) | **Teruji otomatis** terhadap server sungguhan |
| Migrasi data SQLite lama | Kode ada; pengujian memakai berkas `.db` contoh |
| `MariaDBServiceManager` + `MariaDbProcessManager.kt` | Kode ada; **belum dijalankan di perangkat** karena binary Android belum dibangun |
| `libmariadbd.so` untuk arm64 | **Belum tersedia** — workflow build native ada, hasilnya harus dilihat di tab Actions |
| PHP ↔ MariaDB | Belum diuji; runtime PHP belum tersedia |

Sampai baris "libmariadbd.so" berstatus tersedia, aplikasi menampilkan
**Not installed** beserta path yang diperiksa dan alasan ABI. Tidak ada status
`Running` palsu.

## 7. Data pengguna lama

`LegacySqliteMigration.scan()` membaca `PALLSQL/database/*.db` (read-only) dan
menampilkan daftar tabel. Migrasi hanya berjalan setelah pengguna memilih.
Aturannya:

* schema tujuan tidak pernah di-`DROP`;
* `CREATE TABLE` diterjemahkan (`AUTOINCREMENT` → `AUTO_INCREMENT`,
  `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);
* baris disalin lewat prepared statement;
* berkas asli **tidak** dihapus.

## 8. Lisensi

MariaDB Server: GPLv2. PALLSQL tidak mengklaim kepemilikan atas MariaDB dan
tidak mengubah lisensi komponennya. Sumber dan checksum dicatat oleh workflow
build (`native/src/SOURCE_SHA256.txt` + ringkasan di artifact build report).
