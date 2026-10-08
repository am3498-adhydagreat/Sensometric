# Sensometrix — Workflow v5

Paket ini memperluas source yang dikirim pengguna. Perbandingan fitur menggunakan pemetaan RedJade yang diberikan dalam percakapan, bukan inspeksi ulang RedJade. Paket belum dipasang ke website atau database aktif.

## Instalasi pada aplikasi yang sudah berjalan

1. Simpan salinan source dan backup database sebelum memperbarui. Gunakan staging terlebih dahulu.
2. Pastikan database lama sudah mendukung versi v4 aplikasi ini. `upgrade-workflow-v5.sql` adalah migrasi TAMBAHAN, bukan pembuatan database dari nol. Ia bergantung pada `studies`, `samples`, `attributes`, `serving_orders` (kolom urutan JSONB), `panelist_sessions`, `responses`, Supabase Auth, dan fungsi lama.
3. Jalankan **upgrade-workflow-v5.sql** melalui Supabase SQL Editor. Satu transaksi: bila gagal, periksa error dan jangan unggah frontend v5 dahulu. Migrasi menambah satu tabel dengan RLS, indeks, fungsi RPC, dan trigger pemeriksaan event saat sesi peserta dibuat. Tidak ada penghapusan respons atau tabel lama.
4. Setelah SQL berhasil, unggah `index.html`, `sensometrix-workflow.js`, `sensometrix-workflow-utils.js`, `sensometrix-workflow.css`, dan seluruh folder `vendor/`. File lama lain tetap diperlukan. Jangan mengganti konfigurasi situs aktif dengan konfigurasi akun berbeda; pakai `config.js` situs Anda.
5. Buka `index.html` melalui web server/hosting HTTPS. Muat ulang tanpa cache. Menu **Project Workspace** muncul di navigasi peneliti. Ini bukan aplikasi yang dapat menerima respons secara offline.
6. Jalankan acceptance checklist di bawah pada akun/studi staging sebelum rilis ke peserta.

Jika SQL v5 belum tersedia, panelis pada frontend v5 akan mendapat error saat memuat RPC event. Karena itu, urutan database dahulu, frontend kemudian wajib diikuti. File README lama yang menunjuk `index(2).html` sudah diperbaiki: entry point adalah `index.html`.

## Alur penggunaan

1. **Proyek & tes → Tambah Proyek**: isi nama dan deskripsi.
2. **Sampel**: masukkan katalog formula, foto, kode internal, dan deskripsi. Impor CSV memakai template dari tombol di layar; maksimum 500 baris per impor. Katalog tidak otomatis mengubah sampel pada studi lama.
3. **Proyek & tes → Buat tes dari katalog**: pilih proyek, nama internal, nama peserta, CLT/QDA/Triangle, target, replikasi, dan sampel. CLT/QDA 2–8 sampel; Triangle tepat 2. Batas paket free/pro lama tetap berlaku. Alternatif: hubungkan studi yang sudah ada.
4. **Kuesioner / Desain**: gunakan editor lama untuk mengatur pertanyaan dan menghasilkan urutan serta blind code. Nama sampel katalog disalin ketika tes dibuat; perubahan katalog selanjutnya tidak mengubah studi. Foto katalog hanya untuk peneliti.
5. **Peserta & rekrutmen**: buat panel; catat peserta dengan kode unik, grup, tags, demografi dan catatan persetujuan. Kampanye menyimpan kriteria, panel tujuan, dan status; tidak mengirim email.
6. **Lokasi & media**: isi lokasi laboratorium dan pustaka gambar. Preferensi event menyediakan zona waktu, bahasa, serta instruksi awal ketika menambah event.
7. **Event & koleksi**: hubungkan satu event dengan satu studi. Pilih lokasi, panel opsional, jadwal menurut zona IANA (misalnya Asia/Jakarta), bahasa, judul, instruksi, kuota per grup, dan opsi check-in. Tanggal disimpan sebagai waktu UTC; label menampilkan zona event.
8. Aktifkan studi melalui **Studi Saya → Cek kesiapan**. Desain dan kuesioner menggunakan validasi lama.
9. **Console**: tetapkan peserta direktori ke kode desain, check-in, lalu tandai setiap sampel yang benar-benar disajikan. Bila panel ditentukan, peserta harus berasal dari panel itu. Satu peserta direktori tidak boleh mendapat dua kode pada event sama. Grup disalin saat penetapan, sehingga perubahan direktori kemudian tidak mengubah grup data historis.
10. **Undangan & QR** membuka fitur undangan lama. Nama peserta dan instruksi event tampil pada sesi panelis; kode internal formula, grup, dan data direktori tidak ikut dikirim melalui RPC event panelis.
11. **Laporan**: pilih studi, grup, dan replikasi. Tersedia pratinjau, XLSX asli, PPTX asli, JSON, serta HTML untuk cetak PDF. Grup yang belum dipetakan hanya masuk pilihan Semua grup. Sesi parsial tampil pada data mentah tetapi tidak masuk ringkasan numerik.

## Makna aturan event

- **Batasi jadwal** membatasi check-in dan pembuatan sesi peserta baru; sesi yang sudah dibuat tetap dapat dilanjutkan sesudah waktu selesai, termasuk melalui tautan lama. Ini sengaja bukan batas waktu paksa pengisian respons.
- **Wajib check-in** mengharuskan pencatatan hadir sebelum peserta bergabung melalui undangan. Aturan dijalankan di database, bukan hanya tombol browser.
- **Kuota per grup** adalah batas jumlah check-in tercatat. Kuota panel pada direktori adalah target perencanaan anggota, bukan kuota respons.
- Pengaturan event dikunci setelah penetapan peserta/check-in atau sesi penilaian agar aturan tidak berubah di tengah koleksi. Siapkan event sebelum membuka undangan; gunakan studi baru/duplikat bila perlu sesi event terpisah.
- Console menggunakan kode desain tersimpan. Catatan penyajian berurutan, dengan waktu, posisi, dan operator; tidak otomatis mengirim jawaban kuesioner.
- Riwayat check-in tidak menyediakan pembatalan dalam v5. Periksa identitas sebelum check-in. Arsip merupakan penyembunyian administratif dan tidak menghapus data.
- Setiap record memakai versi untuk mendeteksi perubahan dari tab lain. Jika muncul konflik, muat ulang dan ulangi edit berdasarkan data terbaru. Operasi impor bersifat atomik; kegagalan satu baris membatalkan seluruh transaksi.

## Cakupan dibanding pemetaan RedJade

| Area | Implementasi paket ini | Batas cakupan |
|---|---|---|
| Proyek & tes | Proyek berisi beberapa studi/tes, nama internal dan nama peserta, arsip/pulihkan | Satu studi dikaitkan ke satu proyek |
| Sampel | Katalog, foto, impor CSV, pembuatan studi dari pilihan katalog | Blind code tetap memakai desain lama; katalog tidak mengubah studi aktif |
| Event | Lokasi, panel, jadwal, zona waktu, bahasa, instruksi, aturan masuk | Satu event per studi; multi-event satu studi belum ditambahkan |
| Peserta | Direktori, panel, kategori, grup, tags, catatan demografi/persetujuan, kuota check-in | Bukan sistem verifikasi identitas atau deduplikasi lintas akun |
| Rekrutmen | Catatan kampanye dan status | Belum ada pengiriman email/SMS, screener otomatis, atau portal rekrutmen publik |
| Kuesioner | Terhubung ke editor lama, bahasa dan instruksi event untuk panelis | Tidak menambah semua jenis pertanyaan RedJade; belum ada branching kompleks atau theme builder |
| Desain | Memakai randomisasi/blinding/replikasi lama; tabel audit posisi dan pasangan berurutan | Penetapan grup tidak melakukan stratified randomization atau custom block otomatis |
| Koleksi | Link/QR lama, check-in, riwayat, serving console | Belum ada hosting-request workflow, perangkat lab, atau sinkronisasi offline |
| Analisis & laporan | Filter grup/replikasi, XLSX/PPTX/JSON/HTML cetak, ringkasan per panelis | Menggunakan model analisis lama; tidak menambah mixed-effects inference atau analisis lanjutan RedJade |
| Administrasi | Lokasi, media, preferensi event, RLS per pemilik | Kolaborasi tim lintas akun dan permission delegation belum ditambahkan |

Modul baru sengaja tetap menggunakan kepemilikan akun yang ada. Memberi tim lain akses ke studi memerlukan penyesuaian kebijakan seluruh tabel/RPC lama; itu tidak dilakukan diam-diam oleh migrasi ini.

## Verifikasi yang sudah dilakukan

- Sintaks seluruh inline script pada index.html dan JavaScript baru diperiksa dengan Node.
- Struktur HTML diperiksa: ID statis unik, semua referensi script/CSS lokal tersedia.
- CSV: BOM, koma dalam kutipan, newline dalam kutipan, serta input malformed diuji.
- Zona waktu Jakarta/New York, DST yang ambigu/tidak ada, dan tanggal tidak valid diuji.
- Validasi kuota, filter grup/replikasi dan perlindungan teks formula CSV diuji.
- Fungsi ekspor aktual dijalankan pada fixture: JSON, XLSX, PPTX, HTML, dan ringkasan. XLSX dibaca ulang menggunakan openpyxl; PPTX dibaca ulang menggunakan python-pptx. Nilai mean dan jumlah respons terfilter sesuai.
- Tidak ada koneksi pengujian ke Supabase pengguna dan tidak ada data produksi diubah.

## Batas verifikasi dan checklist staging

**Migrasi SQL belum dieksekusi pada PostgreSQL/Supabase. Pengujian tampilan dan klik pada browser belum berhasil dijalankan:** runtime lokal tidak menyediakan browser executable, browser jarak jauh tidak dapat menjangkau server lokal, dan pembukaan berkas lokal diblokir kebijakan browser. Karena itu paket ini perlu acceptance test staging, bukan klaim siap produksi tanpa pengujian.

- Jalankan SQL; pastikan tabel/RPC terbentuk tanpa error dan rerun migrasi aman.
- Akun A tidak dapat membaca/mengubah record akun B. Akun panelis anonim tidak bisa membaca direktori, desain, media, atau event pribadi melalui tabel v5.
- Buat proyek, dua sampel, tes, desain, event; pastikan kuota paket lama tetap ditolak bila terlampaui.
- Edit/arsip/pulihkan proyek, tes, katalog dan peserta. Simulasikan edit bersamaan: revisi lama harus ditolak.
- Uji impor CSV valid, kode peserta ganda, serta salah satu baris invalid: tidak boleh ada impor setengah jadi.
- Aktivasi studi → tetapkan peserta → check-in → sajikan sampai habis. Dua tab yang menandai posisi sama harus menghasilkan satu pencatatan dan satu konflik.
- Uji kuota grup dari dua tab, peserta dari panel yang salah, dan kode peserta yang tidak ada dalam desain.
- Uji tautan peserta sebelum mulai, sesudah selesai, dan sebelum check-in; opsi aktif harus ditolak server. Sesi lama dapat lanjut sesuai aturan di atas.
- Pastikan judul/instruksi/bahasa event benar pada sesi panelis dan identitas formula tidak bocor.
- Ekspor semua format dengan filter; buka di Excel/PowerPoint; periksa tampilan desktop dan ponsel.

## Pemulihan frontend

Bila pembaruan frontend perlu dibatalkan, pulihkan source versi sebelumnya. Tabel/fungsi v5 dapat tetap ada agar data baru tidak hilang. **Trigger jadwal tetap berlaku** meskipun frontend dikembalikan. Administrator dapat melepas trigger `sensometrix_event_entry_v5` pada `public.panelist_sessions` bila memang ingin menonaktifkan aturan event; lakukan hanya dengan keputusan operator dan catat dampaknya. Jangan hapus tabel v5 untuk sekadar mengembalikan frontend.

## Dependensi dan lisensi

Library export disertakan lokal: JSZip dan PptxGenJS (4.0.1). Lisensi di `vendor/`. Supabase client dan font tetap menggunakan sumber eksternal seperti versi awal. Tidak ada pengiriman pesan, telemetry baru, perubahan langganan, deployment, atau akses ke akun lain dari paket ini.
