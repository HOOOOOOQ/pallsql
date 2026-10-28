# Release PALLSQL

## Penandatanganan APK

Build release saat ini memakai **debug signing key**:

```kotlin
// android/app/build.gradle.kts
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

Artinya APK bisa dipasang di device untuk pengujian, tetapi **tidak layak
dipublikasikan** ke Play Store maupun ke pengguna umum. Tidak ada keystore,
password, atau token di repositori.

Untuk membuat build yang layak distribusi:

1. Buat keystore di mesin lokal:

   ```bash
   keytool -genkeypair -v -keystore ~/pallsql.jks -keyalg RSA \
     -keysize 2048 -validity 10000 -alias pallsql
   ```

2. Buat `android/key.properties` (sudah di-`.gitignore`):

   ```properties
   storeFile=/home/user/pallsql.jks
   storePassword=***
   keyAlias=pallsql
   keyPassword=***
   ```

3. Ubah `android/app/build.gradle.kts` agar membaca file tersebut dan
   menambahkan `signingConfig`, atau gunakan `flutter build apk
   --release --dart-define` dengan gradle property tambahan.

4. Jangan pernah meng-commit keystore, `key.properties`, atau password.

## Alur release otomatis

`.github/workflows/release.yml` berjalan pada tag `v*.*.*`:

1. Checkout tag.
2. Set up JDK 17 dan Flutter 3.47.8.
3. `flutter pub get` → `flutter analyze` → `flutter test`.
4. `flutter build apk --release`.
5. Verifikasi APK ada dan ukurannya wajar.
6. `gh release create` dengan APK + `SHA256SUMS.txt`.

Jika salah satu langkah gagal, release tidak dibuat.

## Versi

- `pubspec.yaml` → `version: <semver>+<build>`
- Tag harus `v<semver>` dan sebaiknya sama dengan versi di `pubspec.yaml`.
- `versionCode` APK berasal dari angka setelah `+`.

## Checklist rilis manual

- [ ] `flutter analyze` bersih
- [ ] `flutter test` lulus
- [ ] Uji pasang APK di device nyata, bukan emulator saja
- [ ] Catat perubahan di body release
- [ ] Lampirkan checksum
- [ ] Pastikan tidak ada file build/APK yang ter-commit
