# HTTP server lokal PALLSQL

Dokumen ini menjelaskan perilaku `WebServerService` (`lib/services/web_server_service.dart`)
dan cara memeriksa kalau website di `http://127.0.0.1:8080/` tidak tampil.

## Alamat dan document root

| Hal | Nilai |
| --- | --- |
| Alamat default | `http://127.0.0.1:8080/` |
| Document root default | `PALLSQL/htdocs/` |
| Document root proyek aktif | `PALLSQL/projects/<proyek>/` |
| Health check | `/__pallsql/health` (JSON) |
| Halaman awal | `index.html`, lalu `index.htm`, lalu `index.php` |

`Workspace.ensureStructure()` membuat `htdocs/index.html` **hanya jika belum ada**.
Halaman bawaan berisi judul *PALLSQL Local Server*, tulisan
*Your local server is running*, keterangan bahwa halaman berasal dari file lokal,
CSS tema hitam–hijau neon, dan `viewport` responsif. File yang sudah diedit
pengguna tidak pernah ditimpa.

Kalau `index.html` tidak ada, `/` menjawab **404** dengan halaman penjelasan
(bukan `200` dengan body kosong). Folder tanpa `index.html` menjawab **403**
karena directory listing memang dimatikan.

## Panjang respons dan pembacaan file

File dibaca lebih dulu (maksimal 8 MB, `maxBufferedFileBytes`) lalu dikirim
dengan `Content-Length` yang persis sama dengan jumlah byte yang dikirim.
Konsekuensinya:

- kegagalan baca menghasilkan **500**, bukan `200 OK` dengan body kosong;
- tidak ada kemungkinan body terpotong karena file berubah di tengah pengiriman;
- file yang lebih besar dari 8 MB (video/arsip) dialirkan (`openRead`) dengan
  `Content-Length` dari `stat` — ini satu-satunya jalur yang masih bergantung
  pada ukuran file saat itu.

Tipe konten ditentukan `MimeTypes.forFileName()`: `text/html; charset=utf-8`,
`text/css; charset=utf-8`, `text/javascript; charset=utf-8`,
`application/json; charset=utf-8`, dan MIME gambar/font yang sesuai. Setiap
respons menyertakan `X-Content-Type-Options: nosniff`.

## Caching dan HTTP 304

| Resource | Header | 304 diizinkan? |
| --- | --- | --- |
| Dokumen HTML (`index.html`, halaman apa pun) | `Cache-Control: no-store`, tanpa `ETag` | **tidak** |
| Aset (CSS, JS, JSON, gambar, font) | `ETag` (hash FNV-1a isi file + ukuran + mtime), `Last-Modified`, `Cache-Control: no-cache` | ya, hanya jika validator cocok |

Aturan validasi:

1. `If-None-Match` dibandingkan dengan perbandingan lemah (RFC 9110): awalan
   `W/` diabaikan, daftar dipisah koma didukung, `*` selalu cocok.
2. `If-Modified-Since` hanya dipakai kalau request **tidak** mengirim
   `If-None-Match`, dan waktunya dipotong ke presisi detik seperti
   `Last-Modified`.
3. Isi file ikut di-hash, jadi mengedit file selalu mengubah `ETag` — 304 tidak
   mungkin muncul untuk konten yang sudah berubah.
4. HTML tidak pernah 304. Inilah penyebab paling umum "halaman kosong setelah
   edit": body lama di cache dipakai ulang. Sekarang setiap reload mengambil
   dokumen terbaru dari disk.

`GET /` yang biasa selalu `200` dengan body lengkap. `304` hanya muncul untuk
aset dengan validator yang benar-benar cocok, dan body-nya memang harus kosong
menurut spesifikasi HTTP — jadi 304 bukan error dengan sendirinya.

## Siklus hidup server

- `start()` idempoten: pemanggilan kedua saat `starting`/`running` mengembalikan
  future yang sama, tidak membuka socket kedua.
- `stop()` menunggu proses bind yang sedang berjalan, lalu menutup socket.
- `restart()` menyimpan port/LAN sebelum `stop()` supaya tidak kembali ke 8080
  secara tak sengaja.
- Port yang sudah dipakai menghasilkan `PortInUseFailure` dengan pesan
  "Port 8080 is already in use" dan saran pindah port di tab Servers.
- Status di UI berasal dari `WebServerSnapshot` (state, port, jumlah request),
  bukan boolean yang di-hardcode.

## PHP

File `.php` **tidak pernah** dikirim sebagai teks. Tanpa runtime, server menjawab
**501** beserta halaman penjelasan, dan log mencatat sekali bahwa
`PHP runtime is not available`. File statis (HTML/CSS/JS/gambar) tetap dilayani
normal. Lihat `docs/php-runtime.md`.

## Cara memeriksa kalau situs tidak tampil

1. Tab **Servers** → pastikan state `running` dan port yang tampil sama dengan
   yang dibuka di browser.
2. Buka `/__pallsql/health` — JSON berisi `state`, `port`, `documentRoot`,
   `requests`, `errors`, dan `php`.
3. Tab **Files** → `htdocs/index.html` harus ada dan berisi HTML.
4. Tab **Logs** (sumber `webServer`) → setiap request tercatat sebagai
   `GET /path -> status (ms)`. Status yang muncul adalah status HTTP sebenarnya.
5. `curl -i http://127.0.0.1:8080/` dari dalam app tidak diperlukan; cukup lihat
   log, karena browser dan server berada di perangkat yang sama.
