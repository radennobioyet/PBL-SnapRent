-- =====================================================================
-- SnapRent - 02_constraints_indexes.sql (PostgreSQL)
-- Constraint tambahan dan indeks untuk mempercepat query.
-- Jalankan setelah 01_create_tables.sql
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Constraint tambahan
-- ---------------------------------------------------------------------

-- Nomor telepon: hanya angka (boleh diawali +), 8-15 karakter
ALTER TABLE penyewa
    ADD CONSTRAINT ck_penyewa_telepon CHECK (no_telepon ~ '^\+?[0-9]{8,14}$');

-- Transaksi selesai wajib punya waktu pengembalian aktual
ALTER TABLE transaksi
    ADD CONSTRAINT ck_transaksi_selesai
    CHECK (status_transaksi <> 'selesai' OR waktu_aktual_kembali IS NOT NULL);

-- Transaksi yang sudah disetujui/disewa/selesai wajib diproses oleh admin
ALTER TABLE transaksi
    ADD CONSTRAINT ck_transaksi_admin
    CHECK (status_transaksi IN ('menunggu', 'dibatalkan') OR id_admin IS NOT NULL);

-- ---------------------------------------------------------------------
-- Indeks (PK dan UNIQUE sudah otomatis terindeks)
-- ---------------------------------------------------------------------

-- Katalog: filter barang per kategori dan status
CREATE INDEX idx_barang_kategori ON barang (id_kategori);
CREATE INDEX idx_barang_status   ON barang (status_barang);

-- Transaksi: FK dan pencarian umum
CREATE INDEX idx_transaksi_penyewa ON transaksi (id_penyewa);
CREATE INDEX idx_transaksi_admin   ON transaksi (id_admin);
CREATE INDEX idx_transaksi_denda   ON transaksi (id_denda);
CREATE INDEX idx_transaksi_status  ON transaksi (status_transaksi);

-- Pengecekan bentrok jadwal (rentang waktu transaksi aktif)
CREATE INDEX idx_transaksi_rentang
    ON transaksi (waktu_mulai_sewa, waktu_rencana_kembali)
    WHERE status_transaksi IN ('disetujui', 'disewa');

-- Detail: PK gabungan sudah mengindeks id_transaksi; tambahkan sisi id_barang
CREATE INDEX idx_detail_barang ON detail_transaksi (id_barang);

-- Jaminan per transaksi (sudah tercakup UNIQUE, indeks khusus mempercepat lookup)
CREATE INDEX idx_jaminan_transaksi ON jaminan (id_transaksi);

COMMIT;
