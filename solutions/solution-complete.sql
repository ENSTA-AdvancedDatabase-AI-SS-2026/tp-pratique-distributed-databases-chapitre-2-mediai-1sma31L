-- ============================================================
-- MediAI – SOLUTION COMPLÈTE ÉTUDIANT
-- Chapitre 2 : Distributed Databases – ENSTA 3A
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- PARTIE 1 – MISE EN PLACE DU CLUSTER
-- ════════════════════════════════════════════════════════════

-- 1.1 : Lancer depuis le terminal (bash) :
--   docker-compose up -d
--   docker ps

-- 1.2 : Enregistrer les workers
SELECT citus_add_node('citus_worker1', 5432);
SELECT citus_add_node('citus_worker2', 5432);
SELECT citus_add_node('citus_worker3', 5432);

-- Vérification : doit retourner 3 lignes
SELECT nodeid, nodename, nodeport, isactive
FROM pg_dist_node
ORDER BY nodeid;

-- 1.3 : Charger les données (bash) :
--   docker exec -it citus_master psql -U postgres -d mediAI -f /data/schema-mediAI.sql
--   docker exec -it citus_master psql -U postgres -d mediAI -f /data/init-cluster.sql
--   docker exec -it citus_master psql -U postgres -d mediAI -f /data/seed-mediAI.sql

-- Vérification des lignes
SELECT 'Patients'       AS table_name, COUNT(*) AS nb_lignes FROM Patients
UNION ALL
SELECT 'MedicalRecords',               COUNT(*)              FROM MedicalRecords
UNION ALL
SELECT 'TrainingData',                 COUNT(*)              FROM TrainingData
UNION ALL
SELECT 'Transactions',                 COUNT(*)              FROM Transactions;
-- Résultats attendus : Patients=20, MedicalRecords=15, TrainingData=13, Transactions=18


-- ════════════════════════════════════════════════════════════
-- PARTIE 2 – FRAGMENTATION
-- ════════════════════════════════════════════════════════════

-- ── 2.1 : Fragmentation Horizontale – TrainingData par siteOrigin ──

-- Fragment Paris
CREATE OR REPLACE VIEW TrainingData_Paris AS
    SELECT * FROM TrainingData
    WHERE siteOrigin = 'Paris';

-- Fragment Tunis
CREATE OR REPLACE VIEW TrainingData_Tunis AS
    SELECT * FROM TrainingData
    WHERE siteOrigin = 'Tunis';

-- Fragment Montréal
CREATE OR REPLACE VIEW TrainingData_Montreal AS
    SELECT * FROM TrainingData
    WHERE siteOrigin = 'Montreal';

-- Fragment Tokyo
CREATE OR REPLACE VIEW TrainingData_Tokyo AS
    SELECT * FROM TrainingData
    WHERE siteOrigin = 'Tokyo';

-- 2.1.b – Vérification de la complétude
SELECT siteOrigin, COUNT(*) AS nb_lignes
FROM TrainingData
GROUP BY siteOrigin
ORDER BY siteOrigin;
-- Montreal=3, Paris=4, Tokyo=3, Tunis=3

SELECT COUNT(*) AS total_global FROM TrainingData;
-- total = 13  (4+3+3+3 = 13 → complétude vérifiée)

-- 2.1.c – Distribution Citus effective
SELECT s.shardid, p.nodename, p.nodeport,
       s.shardminvalue, s.shardmaxvalue
FROM pg_dist_shard s
JOIN pg_dist_shard_placement p ON s.shardid = p.shardid
WHERE s.logicalrelid = 'TrainingData'::regclass
ORDER BY s.shardid;


-- ── 2.2 : Fragmentation Verticale – MedicalRecords ──────────

-- 2.2.b – Les vues sont déjà créées dans le schéma, on les teste :
SELECT * FROM MedicalRecords_Clinical LIMIT 5;
SELECT * FROM MedicalRecords_AI LIMIT 5;

-- Reconstruction (JOIN sur idRecord)
SELECT fc.idRecord, fc.idPatient, fc.date, fc.examType, fc.result,
       fi.aiModelUsed, fi.aiScore, fi.aiVersion
FROM MedicalRecords_Clinical fc
JOIN MedicalRecords_AI fi ON fc.idRecord = fi.idRecord
LIMIT 5;

-- 2.2.c – Tables physiques (fragmentation verticale réelle)

-- Fragment A : Données cliniques
CREATE TABLE MedRec_Clinical (
    idRecord    INTEGER      NOT NULL,
    idPatient   INTEGER      NOT NULL,
    country     VARCHAR(100) NOT NULL,
    date        DATE,
    examType    VARCHAR(100),
    result      TEXT,
    PRIMARY KEY (idRecord)
);

-- Fragment B : Données IA
CREATE TABLE MedRec_AI (
    idRecord    INTEGER      NOT NULL,
    idPatient   INTEGER      NOT NULL,
    country     VARCHAR(100) NOT NULL,
    aiModelUsed VARCHAR(50),
    aiScore     DECIMAL(5,4),
    aiVersion   VARCHAR(20),
    PRIMARY KEY (idRecord)
);

-- Peupler Fragment A
INSERT INTO MedRec_Clinical
    SELECT idRecord, idPatient, country, date, examType, result
    FROM MedicalRecords;

-- Peupler Fragment B
INSERT INTO MedRec_AI
    SELECT idRecord, idPatient, country, aiModelUsed, aiScore, aiVersion
    FROM MedicalRecords;

-- Test de reconstruction depuis les tables physiques
SELECT fc.idRecord, fc.idPatient, fc.date, fc.examType, fc.result,
       fi.aiModelUsed, fi.aiScore, fi.aiVersion
FROM MedRec_Clinical fc
JOIN MedRec_AI fi ON fc.idRecord = fi.idRecord
ORDER BY fc.idRecord;


-- ── 2.3 : Fragmentation Hybride – Transactions ───────────────

-- ── France ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW Trans_FR_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions
    WHERE country = 'France';

CREATE OR REPLACE VIEW Trans_FR_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions
    WHERE country = 'France';

-- ── Tunisia ─────────────────────────────────────────────────
CREATE OR REPLACE VIEW Trans_TN_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions
    WHERE country = 'Tunisia';

CREATE OR REPLACE VIEW Trans_TN_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions
    WHERE country = 'Tunisia';

-- ── Canada ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW Trans_CA_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions
    WHERE country = 'Canada';

CREATE OR REPLACE VIEW Trans_CA_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions
    WHERE country = 'Canada';

-- ── Japan ───────────────────────────────────────────────────
CREATE OR REPLACE VIEW Trans_JP_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions
    WHERE country = 'Japan';

CREATE OR REPLACE VIEW Trans_JP_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions
    WHERE country = 'Japan';

-- 2.3.c – Reconstruction des transactions France
SELECT fin.idTrans, fin.idPatient, fin.date, fin.amount, fin.currency,
       mgt.type, mgt.status
FROM Trans_FR_Financial fin
JOIN Trans_FR_Management mgt ON fin.idTrans = mgt.idTrans;


-- ════════════════════════════════════════════════════════════
-- PARTIE 3 – REQUÊTES DISTRIBUÉES
-- ════════════════════════════════════════════════════════════

-- 3.1.a – Q1 : Profil complet du patient Mohamed Benali
SELECT
    p.name,
    p.age,
    p.city,
    p.country,
    mr.date,
    mr.examType,
    mr.result,
    mr.aiModelUsed,
    mr.aiScore
FROM Patients p
JOIN MedicalRecords mr ON p.idPatient = mr.idPatient
                       AND p.country  = mr.country
WHERE p.name = 'Mohamed Benali'
ORDER BY mr.date DESC;
-- Résultat : 1 ligne – Scanner Abdominal, 2024-01-22, NephroAI-1, 0.9678

-- 3.1.b – Plan d'exécution distribué
EXPLAIN (VERBOSE, FORMAT TEXT)
SELECT p.name, p.age, mr.date, mr.examType, mr.aiScore
FROM Patients p
JOIN MedicalRecords mr ON p.idPatient = mr.idPatient AND p.country = mr.country
WHERE p.name = 'Mohamed Benali';


-- 3.2.a – Q2 : Performance moyenne des modèles IA par site
SELECT
    p.siteOrigin            AS site,
    mr.aiModelUsed          AS modele_ia,
    COUNT(mr.idRecord)      AS nb_examens,
    ROUND(AVG(mr.aiScore)::numeric, 4) AS score_moyen,
    ROUND(MIN(mr.aiScore)::numeric, 4) AS score_min,
    ROUND(MAX(mr.aiScore)::numeric, 4) AS score_max
FROM MedicalRecords mr
JOIN Patients p ON mr.idPatient = p.idPatient
               AND mr.country   = p.country
WHERE mr.aiScore IS NOT NULL
GROUP BY p.siteOrigin, mr.aiModelUsed
ORDER BY p.siteOrigin, score_moyen DESC;

-- 3.2.b – Q3 : Patients avec score IA > 0.95
SELECT
    p.name,
    p.country,
    mr.examType,
    mr.aiModelUsed,
    mr.aiScore,
    CASE
        WHEN mr.aiScore >= 0.99 THEN 'Critique'
        WHEN mr.aiScore >= 0.97 THEN 'Élevé'
        WHEN mr.aiScore >= 0.95 THEN 'Modéré'
        ELSE                        'Normal'
    END AS niveau_alerte
FROM MedicalRecords mr
JOIN Patients p ON mr.idPatient = p.idPatient
               AND mr.country   = p.country
WHERE mr.aiScore > 0.95
ORDER BY mr.aiScore DESC;


-- 3.3.a – Q4 : Chiffre d'affaires par pays et type
SELECT
    country,
    currency,
    type,
    COUNT(*)            AS nb_transactions,
    SUM(amount)         AS total_amount,
    AVG(amount)         AS avg_amount
FROM Transactions
WHERE status = 'committed'
  AND amount > 0
GROUP BY country, currency, type
ORDER BY country, total_amount DESC;

-- 3.3.b – Requête originale : Coût moyen des consultations par modèle IA utilisé
-- Intérêt métier : aide à facturer les actes selon le modèle IA utilisé (ROI modèle)
SELECT
    mr.aiModelUsed                              AS modele_ia,
    p.country                                   AS pays,
    COUNT(t.idTrans)                            AS nb_consultations,
    ROUND(AVG(t.amount)::numeric, 2)            AS cout_moyen,
    ROUND(AVG(mr.aiScore)::numeric, 4)          AS score_ia_moyen
FROM MedicalRecords mr
JOIN Patients p      ON mr.idPatient = p.idPatient AND mr.country = p.country
JOIN Transactions t  ON t.idPatient  = p.idPatient AND t.country  = p.country
                     AND t.type = 'consultation'
                     AND t.status = 'committed'
GROUP BY mr.aiModelUsed, p.country
ORDER BY p.country, cout_moyen DESC;


-- ════════════════════════════════════════════════════════════
-- PARTIE 4 – TRANSACTIONS DISTRIBUÉES : TWO-PHASE COMMIT
-- ════════════════════════════════════════════════════════════

-- 4.2.a – Phase 1 : PREPARE
BEGIN;

-- Opération 1 : Nouveau dossier médical pour Yuki Tanaka (Japan)
INSERT INTO MedicalRecords (idPatient, country, date, examType, result, aiModelUsed, aiScore, aiVersion)
VALUES (16, 'Japan', NOW()::DATE, 'Consultation urgence',
        'Bilan général - patient en déplacement',
        'DiagNet-3', 0.8934, 'v3.2');

-- Opération 2 : Transaction financière associée
INSERT INTO Transactions (idPatient, country, date, type, amount, currency, status)
VALUES (16, 'Japan', NOW(), 'consultation', 15000, 'JPY', 'pending');

-- Phase 1 : PREPARE TRANSACTION
PREPARE TRANSACTION 'mediAI_urgence_yuki_2024';

-- 4.2.b – Vérifier les transactions préparées
SELECT gid, prepared, owner, database
FROM pg_prepared_xacts;

-- 4.2.c – Scénario A : COMMIT (tout s'est bien passé)
COMMIT PREPARED 'mediAI_urgence_yuki_2024';

-- Mettre à jour le statut après commit
UPDATE Transactions
SET status = 'committed'
WHERE idPatient = 16 AND type = 'consultation' AND status = 'pending';

-- Vérifier l'insertion
SELECT idRecord, idPatient, date, examType, aiScore
FROM MedicalRecords
WHERE idPatient = 16
ORDER BY date DESC;

-- 4.2.c – Scénario B : ROLLBACK (simulation d'un échec)
BEGIN;
INSERT INTO Transactions (idPatient, country, date, type, amount, currency, status)
VALUES (16, 'Japan', NOW(), 'consultation_test', 5000, 'JPY', 'pending');
PREPARE TRANSACTION 'mediAI_test_rollback';

-- Phase 2b : Annuler la transaction
ROLLBACK PREPARED 'mediAI_test_rollback';

-- Vérifier : doit retourner 0
SELECT COUNT(*) FROM Transactions WHERE type = 'consultation_test';


-- 4.3.a – Simulation d'une panne worker
BEGIN;
INSERT INTO TrainingData (idRecord, siteOrigin, featureVector, label, quality)
VALUES (1, 'Tokyo', '{"test": true}', 'test_failure', 'standard');
PREPARE TRANSACTION 'mediAI_failover_test';

-- Voir la transaction en attente
SELECT gid, prepared FROM pg_prepared_xacts;

-- (En bash) docker stop citus_worker3
-- Puis tenter le commit : COMMIT PREPARED 'mediAI_failover_test';
-- En cas de panne : ROLLBACK PREPARED 'mediAI_failover_test';

-- (En bash) docker start citus_worker3


-- ════════════════════════════════════════════════════════════
-- PARTIE 5 BONUS – Analyse de performance
-- ════════════════════════════════════════════════════════════

-- Sans clé de distribution (scan global sur tous les shards)
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM Patients WHERE name = 'Alice Dupont';

-- Avec clé de distribution (shard pruning)
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM Patients WHERE country = 'France' AND name = 'Alice Dupont';

-- Monitoring du cluster
SELECT nodeid, nodename, nodeport, isactive, noderole
FROM pg_dist_node;

SELECT p.nodename, COUNT(*) AS nb_shards
FROM pg_dist_shard_placement p
GROUP BY p.nodename
ORDER BY nb_shards DESC;

SELECT logicalrelid::text AS table_name,
       pg_size_pretty(citus_total_relation_size(logicalrelid)) AS taille_totale
FROM pg_dist_partition
ORDER BY citus_total_relation_size(logicalrelid) DESC;
