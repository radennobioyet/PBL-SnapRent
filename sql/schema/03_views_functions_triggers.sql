-- =====================================================================
-- SnapRent - 03_views_functions_triggers.sql (PostgreSQL 12+)
-- Logika bisnis di level database:
--   1. Cek bentrok jadwal per unit barang (anti double booking)
--   2. Isi otomatis harga_satuan & subtotal pada detail_transaksi
--   3. Hitung ulang total_tagihan
--   4. Proses pengembalian + denda progresif otomatis
--   5. Fungsi pencarian barang tersedia
--   6. View reminder pengembalian untuk dasbor admin
-- Jalankan setelah 01 dan 02.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Cek bentrok jadwal
--    Barang dianggap terpakai jika ada transaksi berstatus 'disetujui'
--    atau 'disewa' yang rentang waktunya tumpang tindih.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ada_bentrok(
    p_id_barang          INTEGER,
    p_mulai              TIMESTAMP,
    p_kembali            TIMESTAMP,
    p_kecuali_transaksi  INTEGER DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM detail_transaksi dt
        JOIN transaksi t ON t.id_transaksi = dt.id_transaksi
        WHERE dt.id_barang = p_id_barang
          AND t.status_transaksi IN ('disetujui', 'disewa')
          AND (p_kecuali_transaksi IS NULL OR t.id_transaksi <> p_kecuali_transaksi)
          AND t.waktu_mulai_sewa < p_kembali
          AND p_mulai < t.waktu_rencana_kembali
    );
$$;

-- ---------------------------------------------------------------------
-- 2. Trigger BEFORE INSERT/UPDATE pada detail_transaksi
--    - menolak barang non-aktif atau bentrok jadwal
--    - mengisi harga_satuan (jika kosong) dan menghitung subtotal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_detail_before_write() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_mulai    TIMESTAMP;
    v_kembali  TIMESTAMP;
    v_status   VARCHAR(15);
    v_harga    NUMERIC(12,2);
    v_hari     INTEGER;
BEGIN
    SELECT waktu_mulai_sewa, waktu_rencana_kembali
      INTO v_mulai, v_kembali
      FROM transaksi
     WHERE id_transaksi = NEW.id_transaksi;

    SELECT status_barang, harga_sewa_per_hari
      INTO v_status, v_harga
      FROM barang
     WHERE id_barang = NEW.id_barang;

    IF v_status IS NOT NULL AND v_status <> 'aktif' THEN
        RAISE EXCEPTION 'Barang % tidak dapat disewa (status: %)', NEW.id_barang, v_status;
    END IF;

    IF v_mulai IS NOT NULL
       AND fn_ada_bentrok(NEW.id_barang, v_mulai, v_kembali, NEW.id_transaksi) THEN
        RAISE EXCEPTION 'Barang % sudah dipesan pada rentang waktu tersebut', NEW.id_barang;
    END IF;

    IF NEW.harga_satuan IS NULL THEN
        NEW.harga_satuan := v_harga;
    END IF;

    -- Lama sewa dibulatkan ke atas per hari (24 jam), minimal 1 hari
    v_hari := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (v_kembali - v_mulai))::NUMERIC / 86400)::INTEGER);
    NEW.subtotal := NEW.harga_satuan * v_hari;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_detail_before_write
    BEFORE INSERT OR UPDATE ON detail_transaksi
    FOR EACH ROW EXECUTE FUNCTION trg_detail_before_write();

-- ---------------------------------------------------------------------
-- 3. Hitung ulang total_tagihan = SUM(subtotal) + nominal_denda
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_refresh_total(p_id_transaksi INTEGER)
RETURNS VOID LANGUAGE sql AS $$
    UPDATE transaksi t
       SET total_tagihan = COALESCE(
               (SELECT SUM(dt.subtotal)
                  FROM detail_transaksi dt
                 WHERE dt.id_transaksi = t.id_transaksi), 0) + t.nominal_denda
     WHERE t.id_transaksi = p_id_transaksi;
$$;

CREATE OR REPLACE FUNCTION trg_detail_after_write() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM fn_refresh_total(OLD.id_transaksi);
    ELSE
        PERFORM fn_refresh_total(NEW.id_transaksi);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_detail_after_write
    AFTER INSERT OR UPDATE OR DELETE ON detail_transaksi
    FOR EACH ROW EXECUTE FUNCTION trg_detail_after_write();

-- ---------------------------------------------------------------------
-- 3b. Saat transaksi disetujui/disewa, cek ulang bentrok untuk semua
--     barangnya (mencegah dua booking 'menunggu' sama-sama disetujui)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_transaksi_before_update() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_barang INTEGER;
BEGIN
    IF NEW.status_transaksi IN ('disetujui', 'disewa')
       AND (OLD.status_transaksi NOT IN ('disetujui', 'disewa')
            OR NEW.waktu_mulai_sewa <> OLD.waktu_mulai_sewa
            OR NEW.waktu_rencana_kembali <> OLD.waktu_rencana_kembali) THEN
        FOR v_barang IN
            SELECT id_barang FROM detail_transaksi WHERE id_transaksi = NEW.id_transaksi
        LOOP
            IF fn_ada_bentrok(v_barang, NEW.waktu_mulai_sewa, NEW.waktu_rencana_kembali, NEW.id_transaksi) THEN
                RAISE EXCEPTION 'Barang % bentrok dengan transaksi aktif lain', v_barang;
            END IF;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transaksi_before_update
    BEFORE UPDATE ON transaksi
    FOR EACH ROW EXECUTE FUNCTION trg_transaksi_before_update();

-- ---------------------------------------------------------------------
-- 4. Proses pengembalian + denda progresif
--    Aturan denda dicocokkan dari tabel denda:
--      batas_min_jam < keterlambatan (jam) <= batas_max_jam
--    jenis nominal_tetap -> nilai_denda
--    jenis sewa_harian   -> jumlah harga_satuan semua barang (1 hari penuh)
--    Pemakaian: CALL sp_proses_pengembalian(12);
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_proses_pengembalian(
    p_id_transaksi   INTEGER,
    p_waktu_kembali  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql AS $$
DECLARE
    v_rencana    TIMESTAMP;
    v_status     VARCHAR(15);
    v_telat_jam  NUMERIC;
    v_aturan     denda%ROWTYPE;
    v_id_denda   INTEGER := NULL;
    v_nominal    NUMERIC(12,2) := 0;
BEGIN
    SELECT waktu_rencana_kembali, status_transaksi
      INTO v_rencana, v_status
      FROM transaksi
     WHERE id_transaksi = p_id_transaksi
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaksi % tidak ditemukan', p_id_transaksi;
    END IF;

    IF v_status <> 'disewa' THEN
        RAISE EXCEPTION 'Hanya transaksi berstatus disewa yang dapat dikembalikan (status saat ini: %)', v_status;
    END IF;

    v_telat_jam := GREATEST(0, EXTRACT(EPOCH FROM (p_waktu_kembali - v_rencana))::NUMERIC / 3600);

    SELECT * INTO v_aturan
      FROM denda d
     WHERE v_telat_jam > d.batas_min_jam
       AND (d.batas_max_jam IS NULL OR v_telat_jam <= d.batas_max_jam)
     ORDER BY d.batas_min_jam DESC
     LIMIT 1;

    IF FOUND THEN
        v_id_denda := v_aturan.id_denda;
        IF v_aturan.jenis_denda = 'nominal_tetap' THEN
            v_nominal := v_aturan.nilai_denda;
        ELSE
            SELECT COALESCE(SUM(harga_satuan), 0) INTO v_nominal
              FROM detail_transaksi
             WHERE id_transaksi = p_id_transaksi;
        END IF;
    END IF;

    UPDATE transaksi
       SET waktu_aktual_kembali = p_waktu_kembali,
           status_transaksi     = 'selesai',
           id_denda             = v_id_denda,
           nominal_denda        = v_nominal
     WHERE id_transaksi = p_id_transaksi;

    PERFORM fn_refresh_total(p_id_transaksi);
END;
$$;

-- ---------------------------------------------------------------------
-- 5. Barang yang tersedia pada rentang waktu tertentu
--    Pemakaian: SELECT * FROM fn_barang_tersedia('2026-10-10 09:00', '2026-10-12 09:00');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_barang_tersedia(
    p_mulai        TIMESTAMP,
    p_kembali      TIMESTAMP,
    p_id_kategori  INTEGER DEFAULT NULL
) RETURNS TABLE (
    id_barang            INTEGER,
    id_kategori          INTEGER,
    nama_barang          VARCHAR,
    foto_barang          VARCHAR,
    harga_sewa_per_hari  NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT b.id_barang, b.id_kategori, b.nama_barang, b.foto_barang, b.harga_sewa_per_hari
      FROM barang b
     WHERE b.status_barang = 'aktif'
       AND (p_id_kategori IS NULL OR b.id_kategori = p_id_kategori)
       AND NOT fn_ada_bentrok(b.id_barang, p_mulai, p_kembali)
     ORDER BY b.nama_barang;
$$;

-- ---------------------------------------------------------------------
-- 6. Reminder pengembalian untuk dasbor admin
--    kuning = kurang dari 1 jam menuju batas, merah = sudah lewat batas
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_reminder_pengembalian AS
SELECT t.id_transaksi,
       p.nama_penyewa,
       p.no_telepon,
       t.waktu_rencana_kembali,
       CASE
           WHEN CURRENT_TIMESTAMP > t.waktu_rencana_kembali THEN 'merah'
           WHEN CURRENT_TIMESTAMP >= t.waktu_rencana_kembali - INTERVAL '1 hour' THEN 'kuning'
           ELSE 'normal'
       END AS level_reminder,
       ROUND(GREATEST(0, EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - t.waktu_rencana_kembali))::NUMERIC / 3600), 2)
           AS jam_terlambat
  FROM transaksi t
  JOIN penyewa p ON p.id_penyewa = t.id_penyewa
 WHERE t.status_transaksi = 'disewa'
 ORDER BY t.waktu_rencana_kembali;
