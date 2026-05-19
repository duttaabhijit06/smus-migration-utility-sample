-- seed/rds/fixtures/seed.sql
--
-- Schema + data fixture loaded into the seed RDS Postgres instance by
-- the one-shot seeder Lambda (see seed/rds/create.sh, step 6). Two
-- tables backing the seed Glue ETL job that lifts RDS rows into the
-- curated S3 zone (s3://<data-bucket>/curated/{customers,products}/)
-- as Parquet via seed/glue/fixtures/<prefix>-rds-to-parquet.py.
--
-- Idempotent: re-runs are safe. CREATE TABLE uses IF NOT EXISTS, and
-- the data load uses ON CONFLICT (id) DO NOTHING so a second seed run
-- against an already-populated database is a no-op.

CREATE TABLE IF NOT EXISTS customers (
    id           INTEGER PRIMARY KEY,
    name         VARCHAR(120) NOT NULL,
    email        VARCHAR(160) NOT NULL,
    country      VARCHAR(64),
    signup_date  DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
    id           INTEGER PRIMARY KEY,
    sku          VARCHAR(32)  NOT NULL,
    name         VARCHAR(160) NOT NULL,
    price_usd    NUMERIC(10, 2) NOT NULL,
    category     VARCHAR(80)
);

-- 50 deterministic customer rows. Names + emails + countries chosen so
-- the Parquet output covers a useful set of partitions for downstream
-- migration smoke tests. Signup dates span 2023-01 through 2024-12.
INSERT INTO customers (id, name, email, country, signup_date) VALUES
 ( 1, 'Alice Andersen',    'alice.andersen@example.com',    'US', '2023-01-05'),
 ( 2, 'Bruno Bianchi',     'bruno.bianchi@example.com',     'IT', '2023-01-12'),
 ( 3, 'Chen Wei',          'chen.wei@example.com',          'CN', '2023-02-03'),
 ( 4, 'Daria Dvorak',      'daria.dvorak@example.com',      'CZ', '2023-02-15'),
 ( 5, 'Erik Eriksen',      'erik.eriksen@example.com',      'NO', '2023-03-01'),
 ( 6, 'Fatima Farsi',      'fatima.farsi@example.com',      'EG', '2023-03-18'),
 ( 7, 'Greta Galimberti',  'greta.galimberti@example.com',  'IT', '2023-04-02'),
 ( 8, 'Hiroshi Hayashi',   'hiroshi.hayashi@example.com',   'JP', '2023-04-20'),
 ( 9, 'Imani Ibrahim',     'imani.ibrahim@example.com',     'KE', '2023-05-04'),
 (10, 'Joost Janssen',     'joost.janssen@example.com',     'NL', '2023-05-19'),
 (11, 'Kira Klimova',      'kira.klimova@example.com',      'RU', '2023-06-02'),
 (12, 'Liam Lochlann',     'liam.lochlann@example.com',     'IE', '2023-06-21'),
 (13, 'Mei Lin',           'mei.lin@example.com',           'TW', '2023-07-04'),
 (14, 'Niko Nieminen',     'niko.nieminen@example.com',     'FI', '2023-07-18'),
 (15, 'Olivia Oduya',      'olivia.oduya@example.com',      'KE', '2023-08-03'),
 (16, 'Paolo Pellegrini',  'paolo.pellegrini@example.com',  'IT', '2023-08-17'),
 (17, 'Quinn Quigley',     'quinn.quigley@example.com',     'IE', '2023-09-01'),
 (18, 'Renata Rossi',      'renata.rossi@example.com',      'IT', '2023-09-22'),
 (19, 'Sergio Salinas',    'sergio.salinas@example.com',    'MX', '2023-10-04'),
 (20, 'Tomoko Takahashi',  'tomoko.takahashi@example.com',  'JP', '2023-10-19'),
 (21, 'Umar Usman',        'umar.usman@example.com',        'NG', '2023-11-01'),
 (22, 'Valentina Vargas',  'valentina.vargas@example.com',  'AR', '2023-11-20'),
 (23, 'Walter Weber',      'walter.weber@example.com',      'DE', '2023-12-03'),
 (24, 'Xochitl Xicoténcatl','xochitl.x@example.com',        'MX', '2023-12-18'),
 (25, 'Yara Yousif',       'yara.yousif@example.com',       'AE', '2024-01-04'),
 (26, 'Zane Zoltan',       'zane.zoltan@example.com',       'HU', '2024-01-19'),
 (27, 'Aiko Abe',          'aiko.abe@example.com',          'JP', '2024-02-01'),
 (28, 'Bjorn Berg',        'bjorn.berg@example.com',        'SE', '2024-02-22'),
 (29, 'Camila Costa',      'camila.costa@example.com',      'BR', '2024-03-04'),
 (30, 'Dmitri Dragunov',   'dmitri.dragunov@example.com',   'RU', '2024-03-19'),
 (31, 'Esther Eze',        'esther.eze@example.com',        'NG', '2024-04-02'),
 (32, 'Felipe Ferreira',   'felipe.ferreira@example.com',   'BR', '2024-04-20'),
 (33, 'Gita Gomes',        'gita.gomes@example.com',        'IN', '2024-05-04'),
 (34, 'Hank Hartmann',     'hank.hartmann@example.com',     'DE', '2024-05-19'),
 (35, 'Ines Ilic',         'ines.ilic@example.com',         'RS', '2024-06-01'),
 (36, 'Juno Jokinen',      'juno.jokinen@example.com',      'FI', '2024-06-22'),
 (37, 'Kofi Kwame',        'kofi.kwame@example.com',        'GH', '2024-07-03'),
 (38, 'Luna Larsen',       'luna.larsen@example.com',       'DK', '2024-07-19'),
 (39, 'Marco Moretti',     'marco.moretti@example.com',     'IT', '2024-08-04'),
 (40, 'Nadia Nguyen',      'nadia.nguyen@example.com',      'VN', '2024-08-20'),
 (41, 'Omar Othman',       'omar.othman@example.com',       'EG', '2024-09-02'),
 (42, 'Petra Poláková',    'petra.polakova@example.com',    'CZ', '2024-09-21'),
 (43, 'Qiang Qin',         'qiang.qin@example.com',         'CN', '2024-10-04'),
 (44, 'Rosa Rodriguez',    'rosa.rodriguez@example.com',    'ES', '2024-10-19'),
 (45, 'Soren Sandberg',    'soren.sandberg@example.com',    'DK', '2024-11-02'),
 (46, 'Talia Tanaka',      'talia.tanaka@example.com',      'JP', '2024-11-21'),
 (47, 'Ulrich Ungar',      'ulrich.ungar@example.com',      'AT', '2024-12-03'),
 (48, 'Vera Vlasova',      'vera.vlasova@example.com',      'RU', '2024-12-12'),
 (49, 'Wesley Whitaker',   'wesley.whitaker@example.com',   'US', '2024-12-19'),
 (50, 'Yusra Younis',      'yusra.younis@example.com',      'SD', '2024-12-29')
ON CONFLICT (id) DO NOTHING;

-- 25 deterministic product rows across 5 categories. Prices are USD with
-- two decimal places to exercise the NUMERIC(10,2) → Parquet `decimal`
-- mapping in the Glue ETL job.
INSERT INTO products (id, sku, name, price_usd, category) VALUES
 ( 1, 'BK-001', 'Foundations of Distributed Systems', 39.95, 'books'),
 ( 2, 'BK-002', 'Hands-On Data Engineering',          44.50, 'books'),
 ( 3, 'BK-003', 'Streaming Architectures',            52.00, 'books'),
 ( 4, 'BK-004', 'Practical SQL',                      31.75, 'books'),
 ( 5, 'BK-005', 'Cloud Cost Optimization',            28.95, 'books'),
 ( 6, 'EL-001', 'Mechanical Keyboard',               129.00, 'electronics'),
 ( 7, 'EL-002', 'USB-C Hub (8-port)',                 49.00, 'electronics'),
 ( 8, 'EL-003', 'Noise-Cancelling Headphones',       249.99, 'electronics'),
 ( 9, 'EL-004', 'Webcam 1080p',                       59.50, 'electronics'),
 (10, 'EL-005', 'External SSD 1TB',                   89.00, 'electronics'),
 (11, 'KT-001', 'Pour-Over Coffee Kettle',            64.00, 'kitchen'),
 (12, 'KT-002', 'Ceramic Knife Set',                  79.95, 'kitchen'),
 (13, 'KT-003', 'Sourdough Starter Kit',              22.50, 'kitchen'),
 (14, 'KT-004', 'Cast-Iron Skillet 12in',             45.00, 'kitchen'),
 (15, 'KT-005', 'Espresso Tamper',                    18.75, 'kitchen'),
 (16, 'OF-001', 'Standing Desk Mat',                  39.00, 'office'),
 (17, 'OF-002', 'Ergonomic Mouse',                    74.50, 'office'),
 (18, 'OF-003', 'Monitor Arm (single)',               99.00, 'office'),
 (19, 'OF-004', 'Cable Organizer Tray',               24.00, 'office'),
 (20, 'OF-005', 'Whiteboard 36x24',                   58.95, 'office'),
 (21, 'OD-001', 'Trekking Poles',                     85.00, 'outdoor'),
 (22, 'OD-002', '40L Backpack',                      119.00, 'outdoor'),
 (23, 'OD-003', 'Insulated Water Bottle',             34.50, 'outdoor'),
 (24, 'OD-004', 'Headlamp 500lm',                     42.00, 'outdoor'),
 (25, 'OD-005', 'Compact Camp Stove',                 68.00, 'outdoor')
ON CONFLICT (id) DO NOTHING;
