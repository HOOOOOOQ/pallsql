# PHP runtime untuk PALLSQL

Dokumen ini menjelaskan kontrak teknis untuk menghadirkan eksekusi PHP
sungguhan di PALLSQL, dan **apa yang belum tersedia** saat ini.

## Status sekarang

- Tidak ada interpreter PHP di dalam APK.
- `GET /file.php` **tidak** mengirim source code. Server menjawab
  `HTTP 501 Not Implemented` dengan halaman penjelasan.
- Halaman PHP di aplikasi menampilkan `Unavailable` beserta alasan nyata dari
  probe runtime (bukan nilai karangan).
- Karena belum ada eksekusi PHP yang terverifikasi, fitur PHP **tidak** boleh
  disebut selesai.

## Arsitektur yang sudah ada

```
HTTP request  ->  WebServerService._servePhp()
                     |  PhpBridge.info.available ?
                     |        tidak -> 501 + penjelasan
                     v
                  PhpBridge.execute(PhpCgiRequest)
                     |
        +------------+-------------+
        |                          |
 NullPhpBridge              ProcessPhpRuntime
 (selalu 501)          (menjalankan php-cgi via Process.start)
```

`PhpCgiRequest` membawa `scriptPath`, `scriptName`, `documentRoot`, `method`,
`uri`, `headers`, `body`, `remoteAddress`, `serverName`, `serverPort` dan dapat
diterjemahkan menjadi environment CGI standar (`toEnvironment()`).

`ProcessPhpRuntime` mencari binary pada urutan berikut:

1. `phpBinaryPath` dari Settings (harus path relatif di dalam workspace)
2. `PALLSQL/config/php/php-cgi`
3. `PALLSQL/config/php/php`
4. `PALLSQL/config/php/bin/php-cgi`
5. `<nativeLibraryDir>/libphp-cgi.so`
6. `<nativeLibraryDir>/libphp.so`

Probe menjalankan `php-cgi -v`, `-m`, dan `-i` (tanpa shell), lalu mengisi
`PhpRuntimeInfo` (versi, ekstensi, nilai ini). Semua nilai yang ditampilkan UI
berasal dari output nyata ini.

## Cara memasang runtime (jalur yang direncanakan)

Android tidak mengizinkan eksekusi binary dari direktori biasa. Dua jalur yang
layak:

1. **`libphp-cgi.so` dengan `android:extractNativeLibs`**
   Binary `php-cgi` di-rename menjadi `libphp-cgi.so`, diletakkan di
   `android/app/src/main/jniLibs/<ABI>/`, dan dijadikan executable saat runtime
   (`chmod 700` di `nativeLibraryDir`). APK ini sudah memakai
   `jniLibs.useLegacyPackaging = true` sehingga library diekstrak ke disk dan
   dapat dieksekusi.
2. **Build PHP statis untuk Android** (NDK, `--disable-all` + ekstensi
   seperlunya), lalu dibundel per-ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`).

Yang belum ada di repo ini: hasil build tersebut. Tidak ada unduhan senyap,
tidak ada permintaan ke API eksternal, dan tidak ada dependensi Termux/proot.

## Checklist sebelum fitur PHP boleh disebut selesai

- [ ] Binary tersedia untuk semua ABI yang didukung dan tercatat checksum-nya
- [ ] `php -v` dan `php-cgi` benar-benar berjalan di device nyata
- [ ] `GET /index.php` mengembalikan HTML hasil eksekusi dengan status 200
- [ ] Kesalahan fatal PHP menghasilkan 500 + pesan di log, bukan source
- [ ] `POST` form terbaca (`php://input`/`$_POST`)
- [ ] Ukuran APK dan lisensi terdokumentasi
- [ ] Test otomatis membuktikan eksekusi (bukan sekadar file ada)

## Lisensi

PHP dirilis di bawah PHP License 3.01 (turunan BSD-style). Pustaka yang
di-link (OpenSSL, libxml2, PCRE, ICU, dsb.) memiliki lisensi masing-masing dan
wajib diatribusikan bila binary didistribusikan. Rencana distribusi harus
menyertakan berkas NOTICE berisi daftar versi, lisensi, dan sumber build.
