# Arsitektur PALLSQL

## Lapisan

```
main.dart
  └─ AppBootstrap.create(databaseFactory, workspaceRoot?, native?)
        ├─ Workspace            (folder + PathGuard)
        ├─ SettingsRepository   (config/settings.json)
        ├─ LogRepository        (logs/app.log + ring buffer)
        ├─ NativeBridge         (method channel com.pallsql.mobile/native)
        ├─ PhpRuntimeService    (probe + CGI bridge)
        ├─ WebServerService     (dart:io HttpServer)
        ├─ FileRepository       (sandboxed file IO)
        ├─ ProjectRepository    (config/projects.json + ZIP)
        ├─ SqliteDatabaseRepository (database/*.db)
        └─ BackupService        (backups/*.zip)
              ↑
         ProviderScope + app_providers.dart (Riverpod)
              ↑
         features/*  (UI)
```

Satu-satunya state management adalah **flutter_riverpod**. Tidak ada Provider
class dari `provider` package, tidak ada `setState` global.

## Interface controller

| Interface | Implementasi UI | Provider |
| --- | --- | --- |
| `ServerController` | `WebServerNotifier` | `webServerProvider` |
| `PhpRuntimeController` | `PhpRuntimeNotifier` | `phpRuntimeProvider`, `phpStatusProvider` |
| `DatabaseController` | `DatabaseNotifier` | `databaseProvider`, `databaseStatusProvider`, `queryHistoryProvider` |
| `ProjectController` | `ProjectsNotifier` | `projectsProvider`, `activeProjectProvider` |
| `FileSystemController` | `FileRepository` | `fileRepositoryProvider` |
| `LogController` | `LogRepository` | `logRepositoryProvider`, `logEntriesProvider` |

Konvensi: operasi async yang dipicu UI mengembalikan `Future<String?>` dengan
`null` berarti sukses dan isi string adalah pesan error siap tampil. UI
menampilkannya lewat `showPallSqlSnack`.

## Halaman fitur

| Folder | Isi |
| --- | --- |
| `features/shell` | `HomeShell` + bottom navigation (5 tab) |
| `features/dashboard` | ringkasan lingkungan, status layanan, quick actions |
| `features/servers` | kontrol HTTP server, port, LAN |
| `features/database` | `database_page` (daftar + riwayat), `database_detail_page` (browser tabel), `sql_editor_page` (editor SQL mandiri) |
| `features/files` | file manager |
| `features/editor` | `editor_page` (editor file) + syntax highlighter |
| `features/projects`, `backups`, `logs`, `terminal`, `php`, `settings` | fitur pendukung |

`SqlEditorPage` adalah satu-satunya jalur untuk SQL ad-hoc: pilih database,
tulis statement, jalankan, lihat hasil/error, dan riwayat. Halaman ini memakai
`SqliteDatabaseRepository` yang sama dari bootstrap, jadi tidak ada koneksi
SQLite kedua. Riwayat diekspos lewat `queryHistoryProvider` supaya daftar di tab
Database dan di editor selalu sinkron.

## Status layanan

`ServiceState` = `stopped | starting | running | stopping | error | unavailable`.
Tidak ada boolean "server aktif" yang di-hardcode. `WebServerService` mengubah
state setelah bind/close sungguhan, dan `WebServerSnapshot` membawa port, URL,
request count, error, serta uptime nyata.

## Keamanan path

Semua operasi file melewati `PathGuard`:

- menolak path absolut, drive letter, NUL byte, dan segmen `..`
- `toRelative()` selalu mengembalikan path dalam workspace
- server memakai guard yang sama untuk document root, ditambah pengecekan
  symlink (`resolveSymbolicLinksSync`) sebelum file dikirim
- detail aturan HTTP (panjang respons, ETag/304, 404 untuk index yang hilang)
  ada di `docs/http-server.md`

## Native bridge

Method channel: `com.pallsql.mobile/native`

| Method | Tujuan |
| --- | --- |
| `getDeviceInfo` | versi Android, SDK int, ABI, versi app |
| `getStorageStats` | ukuran app, sisa dan total storage |
| `getNativeLibraryDir` | lokasi binary native (untuk PHP) |
| `startForegroundService` / `stopForegroundService` | notifikasi server |
| `pickFile` | document picker, menyalin file ke workspace |
| `shareFile` | share sheet lewat FileProvider |
| `openUrl` | membuka `http`/`https` saja |

Tidak ada method yang mengeksekusi perintah shell sembarang.
