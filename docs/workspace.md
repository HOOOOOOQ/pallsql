# Workspace PALLSQL

## Satu folder untuk semua modul

Semua data PALLSQL berada di satu pohon folder. File Manager, web server,
project manager, database manager, dan terminal membaca folder yang sama — tidak
ada modul yang memakai direktori sendiri.

```
PALLSQL/
├── htdocs/             document root default (index.html bawaan)
├── projects/           project website (satu folder per project)
├── database/           file .db SQLite
├── config/
│   ├── settings.json   preferensi aplikasi
│   ├── projects.json   metadata project
│   ├── query_history.json
│   ├── queries/        snippet SQL tersimpan (Save query)
│   ├── php/            tempat menaruh binary php-cgi + php.ini
│   └── server/         konfigurasi server lokal
├── logs/               app.log
├── backups/            ZIP backup & export workspace
├── tmp/                file sementara (boleh dihapus kapan saja)
├── extensions/         tempat extension/materi tambahan
└── terminal/           riwayat/skrip terminal
```

Folder dibuat otomatis saat aplikasi pertama kali dijalankan
(`Workspace.ensureStructure`). `htdocs/index.html` hanya ditulis sekali dan
**tidak pernah** ditimpa, jadi halaman yang sudah Anda edit tetap aman.

## Lokasi penyimpanan

- Default: penyimpanan privat aplikasi
  (`/data/data/com.pallsql.mobile/app_flutter/PALLSQL` di Android).
- Lokasi lengkap ditampilkan di **Settings → Workspace** dan di **Dashboard →
  Environment**, dan bisa dibuka lewat file manager internal
  (**Open workspace / Open htdocs / Open projects / Open database folder /
  Open logs**).
- Tidak ada file penting di direktori cache; `tmp/` hanya untuk file sementara.

Android modern memakai *scoped storage*: aplikasi tidak bisa menulis bebas ke
`/storage/emulated/0/PALLSQL/` tanpa izin khusus. Karena itu PALLSQL **tidak**
mengklaim memiliki folder publik tersebut. Untuk mengeluarkan data:

1. **Settings → Workspace → Export workspace** membuat ZIP di `backups/` lalu
   membukanya lewat share sheet Android (Drive, Files, dsb).
2. **File Manager** bisa membagikan satu file (Export) atau mengimpor file lewat
   document picker (SAF).

Database SQLite tetap berada di `database/` (bukan cache), sehingga data
bertahan setelah aplikasi ditutup atau perangkat di-restart.
