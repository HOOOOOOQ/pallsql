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
| `ServerController` | `WebServerController` | `webServerProvider` |
| `PhpRuntimeController` | `PhpRuntimeController` | `phpRuntimeProvider`, `phpStatusProvider` |
| `DatabaseController` | `DatabaseController` | `databaseProvider`, `databaseStatusProvider` |
| `ProjectController` | `ProjectController` | `projectsProvider`, `activeProjectProvider` |
| `FileSystemController` | `FileRepository` | `fileRepositoryProvider` |
| `LogController` | `LogRepository` | `logRepositoryProvider`, `logEntriesProvider` |

Konvensi: operasi async yang dipicu UI mengembalikan `Future<String?>` dengan
`null` berarti sukses dan isi string adalah pesan error siap tampil. UI
menampilkannya lewat `showPallSqlSnack`.

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
