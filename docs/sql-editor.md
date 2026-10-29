# SQL Editor, SQL Console, dan Compatibility Layer

Dokumen ini menjelaskan apa yang **benar-benar** dijalankan PALLSQL saat Anda
menulis SQL, apa yang diterjemahkan, dan apa yang sengaja ditolak.

## Engine

| Hal | Nilai |
| --- | --- |
| Engine bawaan | SQLite (melalui `sqflite` di Android, `sqflite_common_ffi` di test) |
| Dialect yang ditampilkan | `SQLite <versi> — SQLite dialect` |
| MySQL/MariaDB | **Tidak tersedia.** Tidak ada server MariaDB yang dibundel |
| Lokasi file | `PALLSQL/database/<nama>.db` |

PALLSQL tidak pernah menyebut SQLite sebagai MySQL/MariaDB. Label engine di
editor, terminal, Settings, dan Dashboard selalu menyebut SQLite dan dialect-nya.

## SQL Editor

Buka dari tab **Database**:

- tombol **Open SQL editor** (selalu aktif, walaupun belum ada database), atau
- ikon terminal di app bar Database.

Fitur yang benar-benar berfungsi:

| Aksi | Perilaku |
| --- | --- |
| Pilih database | Dropdown diisi dari file `.db` nyata di `PALLSQL/database` |
| New database | Membuat file SQLite baru, divalidasi nama, langsung bisa dipakai |
| Execute | Menjalankan semua statement (dipisah `;`) lewat `SqliteDatabaseRepository` |
| Stop | Muncul untuk script > 1 statement; SQLite tidak bisa dihentikan di tengah satu statement, jadi token dicek **antar** statement |
| Clear | Mengosongkan editor dan hasil |
| Format | `SqlUtils.format`: rapikan huruf besar keyword dan pemisahan klausa, literal string tidak diubah |
| Save query / Load query | File `.sql` di `PALLSQL/config/queries` (maks. 40 file terbaru) |
| Font size | Slider yang tersimpan di `config/settings.json` |
| Fullscreen | Editor memenuhi layar, tombol keluar di kanan atas |
| Copy result | Menyalin grid sebagai TSV |
| Export CSV | Menulis CSV ke `tmp/` lalu membagikannya lewat share sheet Android |
| Riwayat | `config/query_history.json` (maks. 50), bisa diketuk untuk dipakai ulang |
| Error | Pesan SQLite asli, dipotong 800 karakter, tanpa path absolut |
| Destruktif | `DROP`, `TRUNCATE`, `DELETE/UPDATE` tanpa `WHERE` meminta konfirmasi |

Hasil ditampilkan di panel dengan dua tab: **Result** (grid yang bisa digulir
horizontal) dan **Messages** (jumlah statement, durasi, row terpengaruh,
`last_insert_rowid`, serta notice dari compatibility layer).

## SQL Console di terminal

Terminal punya dua mode. Ketik `sql` untuk masuk ke SQL console:

```
> sql app
SQL console - SQLite dialect, database app.db
> CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
1 statement ok in 3 ms
> INSERT INTO users (name) VALUES ('pallxXx');
1 statement ok in 1 ms, 1 row(s) affected
> SELECT * FROM users;
id  name
--  -------
1   pallxXx
1 row in 0 ms
```

Perintah console:

| Perintah | Fungsi |
| --- | --- |
| `<sql>;` | Menjalankan statement sungguhan |
| `.databases` | Daftar file database |
| `.tables` | Daftar tabel database aktif |
| `.use <nama>` | Ganti database aktif |
| `.read <file.sql>` | Menjalankan script dari workspace |
| `.force on|off` | Konfirmasi eksplisit untuk statement destruktif |
| `.help` | Bantuan console |
| `\q` | Keluar ke PALLSQL shell |

Dari shell (tanpa masuk console) juga tersedia `use`, `tables`, `desc`, `run` dan
`database create|use|list|info|tables|status`.

> Keamanan: tidak ada `sh -c`, tidak ada root, tidak ada shell bebas. Semua
> perintah masuk lewat registry dan semua SQL lewat repository yang memblokir
> `ATTACH`/`DETACH`.

## Compatibility layer (MySQL → SQLite metadata)

Perintah berikut **diterjemahkan** dan dijawab dari metadata SQLite yang nyata
(`sqlite_master`, `PRAGMA table_info`, `PRAGMA index_list`) serta daftar file
database di workspace:

| Perintah | Sumber data nyata |
| --- | --- |
| `SHOW DATABASES;` | Isi folder `PALLSQL/database` (`*.db`) |
| `SHOW TABLES;` | `sqlite_master` database terpilih |
| `SHOW TABLES FROM <db>;` | `sqlite_master` database lain yang benar-benar ada |
| `DESCRIBE <t>;` / `DESC <t>` | `PRAGMA table_info` |
| `SHOW COLUMNS FROM <t>;` | `PRAGMA table_info` |
| `SHOW CREATE TABLE <t>;` | DDL asli tersimpan di `sqlite_master` |
| `SHOW INDEX FROM <t>;` | `PRAGMA index_list` + `index_info` |
| `SELECT VERSION();` | `sqlite_version()` yang sebenarnya |
| `SELECT DATABASE();` | Nama file database terpilih |

Nama kolom hasil dibuat mirip MySQL (`Field`, `Type`, `Null`, `Key`, `Default`,
`Extra`, `Tables_in_<db>`), tetapi setiap hasil menyertakan notice yang
menjelaskan asalnya.

Perintah yang **tidak** bisa dijawab dengan aman akan gagal dengan pesan yang
menyebutkan (1) dialect aktif, (2) alasan penolakan, (3) alternatifnya. Contoh:
`USE`, `SET`, `SHOW STATUS`, `SHOW VARIABLES`, `FLUSH`, `GRANT`,
`CREATE DATABASE`.

## Batasan yang jujur

- Ini bukan kompatibilitas MySQL penuh: tipe data MySQL, `AUTO_INCREMENT`,
  storage engine, user/grant, dan `mysql` schema tidak ada.
- `SHOW INDEX` pada SQLite tidak mengenal konsep `Non_unique` MySQL, jadi nilai
  diturunkan dari `PRAGMA index_list` (`0` = unique).
- Tidak ada koneksi jaringan ke server database; semua lokal dan offline.
