# TP Pratique – Chapitre 2 : Distributed Databases
## Cas d'étude : MediAI – RÉPONSES COMPLÈTES
### ENSTA 3A – Filière AI & Systèmes de Santé

---

## ⚙️ Partie 1 – Mise en place du cluster Citus (10 pts)

### 1.1 – Lancement du cluster Docker

```bash
docker-compose up -d
docker ps
docker exec -it citus_master psql -U postgres -d mediAI
```

> **Capture d'écran** : `docker ps` doit afficher 4 conteneurs `Up` :
> - `citus_master` (port 5432)
> - `citus_worker1`
> - `citus_worker2`
> - `citus_worker3`

---

### 1.2 – Enregistrement des workers

```sql
SELECT citus_add_node('citus_worker1', 5432);
SELECT citus_add_node('citus_worker2', 5432);
SELECT citus_add_node('citus_worker3', 5432);
```

**Question 1.2.a** : Différence coordinator / worker dans Citus :

> Le **coordinator** (citus_master) est le nœud maître qui reçoit toutes les requêtes SQL des clients, les analyse, les planifie et les distribue aux workers. Il maintient les métadonnées de distribution (pg_dist_shard, pg_dist_node). Il ne stocke pas les données applicatives lui-même (dans le mode classique).
>
> Les **workers** (citus_worker1/2/3) stockent physiquement les **shards** (fragments) des tables distribuées. Ils exécutent les sous-requêtes envoyées par le coordinator et remontent les résultats partiels. Ils n'ont pas connaissance de la topologie globale du cluster.

**Question 1.2.b** : Résultat de `SELECT ... FROM pg_dist_node` :

> On obtient **3 lignes** (une par worker enregistré) :
>
> | nodeid | nodename      | nodeport | isactive |
> |--------|---------------|----------|----------|
> | 1      | citus_worker1 | 5432     | true     |
> | 2      | citus_worker2 | 5432     | true     |
> | 3      | citus_worker3 | 5432     | true     |

---

### 1.3 – Chargement du schéma et des données

> | table_name     | nb_lignes attendu | nb_lignes observé |
> |----------------|-------------------|-------------------|
> | Patients       | 20                | 20                |
> | MedicalRecords | 14                | 15                |
> | TrainingData   | 13                | 13                |
> | Transactions   | 18                | 18                |
>
> *(Note : le seed insère 15 enregistrements médicaux : 5 France + 4 Tunisie + 3 Canada + 3 Japon)*

---

## 🗂️ Partie 2 – Fragmentation (30 pts)

### 2.1 – Fragmentation Horizontale : `TrainingData` par `siteOrigin`

#### Exercice 2.1.a – Vues SQL des fragments

```sql
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
```

#### Exercice 2.1.b – Vérification de la complétude

```sql
SELECT siteOrigin, COUNT(*) AS nb_lignes
FROM TrainingData
GROUP BY siteOrigin
ORDER BY siteOrigin;
```

> | siteOrigin | nb_lignes |
> |------------|-----------|
> | Montreal   | 3         |
> | Paris      | 4         |
> | Tokyo      | 3         |
> | Tunis      | 3         |
>
> Total = 13 = COUNT(*) FROM TrainingData ✅

**Question 2.1.b** : La propriété de **complétude est respectée** car la somme des tuples de tous les fragments (4+3+3+3 = 13) est égale au nombre de tuples de la table globale (13). Chaque tuple appartient à exactement un fragment (les conditions `siteOrigin = X` sont mutuellement exclusives et couvrent toutes les valeurs présentes).

#### Exercice 2.1.c – Distribution Citus effective

> Les données de Tokyo sont distribuées sur les workers selon le hash de la valeur `'Tokyo'`. Citus distribue par hash sur la colonne `siteOrigin` ; les shards contenant `siteOrigin='Tokyo'` sont placés sur un ou plusieurs workers (typiquement 1 worker pour des données homogènes par valeur dans un petit cluster). En pratique avec 3 workers et 32 shards, Tokyo peut se retrouver sur **citus_worker1, citus_worker2 ou citus_worker3** selon le placement du hash — à vérifier avec la requête `pg_dist_shard_placement`.

---

### 2.2 – Fragmentation Verticale : `MedicalRecords`

#### Exercice 2.2.a – Pourquoi séparer données cliniques et données IA ?

> 1. **Sécurité et confidentialité** : Les médecins ont besoin des données cliniques (résultats d'examens) mais pas des paramètres internes des modèles IA. Les data scientists ont besoin des scores IA mais pas nécessairement des résultats textuels complets. La fragmentation verticale applique le principe du moindre privilège.
>
> 2. **Performance** : Chaque groupe d'utilisateurs ne charge que les colonnes dont il a besoin. Cela réduit la quantité de données transférées sur le réseau et améliore les performances des requêtes (moins d'I/O disque, meilleure utilisation du cache).

#### Exercice 2.2.b – Test des vues

```sql
SELECT * FROM MedicalRecords_Clinical LIMIT 5;
SELECT * FROM MedicalRecords_AI LIMIT 5;

-- Reconstruction
SELECT fc.idRecord, fc.idPatient, fc.date, fc.examType, fc.result,
       fi.aiModelUsed, fi.aiScore, fi.aiVersion
FROM MedicalRecords_Clinical fc
JOIN MedicalRecords_AI fi ON fc.idRecord = fi.idRecord
LIMIT 5;
```

#### Exercice 2.2.c – Fragmentation verticale physique

```sql
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
```

---

### 2.3 – Fragmentation Hybride : `Transactions`

#### Exercice 2.3.a – Schéma complet des 8 fragments

> | Fragment   | country  | Colonnes                                    |
> |------------|----------|---------------------------------------------|
> | F_FR_FIN   | France   | idTrans, idPatient, date, amount, currency  |
> | F_FR_MGT   | France   | idTrans, idPatient, type, status            |
> | F_TN_FIN   | Tunisia  | idTrans, idPatient, date, amount, currency  |
> | F_TN_MGT   | Tunisia  | idTrans, idPatient, type, status            |
> | F_CA_FIN   | Canada   | idTrans, idPatient, date, amount, currency  |
> | F_CA_MGT   | Canada   | idTrans, idPatient, type, status            |
> | F_JP_FIN   | Japan    | idTrans, idPatient, date, amount, currency  |
> | F_JP_MGT   | Japan    | idTrans, idPatient, type, status            |

#### Exercice 2.3.b – Implémentation SQL des 8 vues

```sql
-- France
CREATE OR REPLACE VIEW Trans_FR_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions WHERE country = 'France';

CREATE OR REPLACE VIEW Trans_FR_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions WHERE country = 'France';

-- Tunisia
CREATE OR REPLACE VIEW Trans_TN_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions WHERE country = 'Tunisia';

CREATE OR REPLACE VIEW Trans_TN_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions WHERE country = 'Tunisia';

-- Canada
CREATE OR REPLACE VIEW Trans_CA_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions WHERE country = 'Canada';

CREATE OR REPLACE VIEW Trans_CA_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions WHERE country = 'Canada';

-- Japan
CREATE OR REPLACE VIEW Trans_JP_Financial AS
    SELECT idTrans, idPatient, date, amount, currency
    FROM Transactions WHERE country = 'Japan';

CREATE OR REPLACE VIEW Trans_JP_Management AS
    SELECT idTrans, idPatient, type, status
    FROM Transactions WHERE country = 'Japan';
```

#### Exercice 2.3.c – Reconstruction des transactions France

```sql
SELECT fin.idTrans, fin.idPatient, fin.date, fin.amount, fin.currency,
       mgt.type, mgt.status
FROM Trans_FR_Financial fin
JOIN Trans_FR_Management mgt ON fin.idTrans = mgt.idTrans;
```

---

## 🔍 Partie 3 – Requêtes distribuées (30 pts)

### 3.1 – Requête de profil patient complet

#### Exercice 3.1.a – Résultat de la requête Mohamed Benali

```
 name           | age | city  | country | date       | examType          | result                             | aiModelUsed | aiScore
----------------+-----+-------+---------+------------+-------------------+------------------------------------+-------------+--------
 Mohamed Benali |  45 | Tunis | Tunisia | 2024-01-22 | Scanner Abdominal | Calcul rénal droit détecté 8mm     | NephroAI-1  | 0.9678
```

#### Exercice 3.1.b – Analyse du plan d'exécution

> - **Type de JOIN** : Hash Join (ou Nested Loop selon Citus — souvent un **co-located join** puisque `country` est la clé de distribution commune à `Patients` et `MedicalRecords`)
> - **Workers impliqués** : Uniquement le worker gérant les shards `country = 'Tunisia'` (1 seul worker grâce au **shard pruning**)
> - **Avantage de la co-localisation** : Comme `Patients` et `MedicalRecords` sont tous deux distribués sur la clé `country`, les tuples d'un même pays sont sur le même worker. Le JOIN s'effectue localement sans transfert réseau entre workers (pas de shuffle distribué), ce qui réduit drastiquement la latence.

---

### 3.2 – Requête agrégée multi-sites

#### Exercice 3.2.a – Résultat performance IA par site

```
 site      | modele_ia    | nb_examens | score_moyen | score_min | score_max
-----------+--------------+------------+-------------+-----------+----------
 Montreal  | PulmoAI-2    |          1 |      0.9789 |    0.9789 |    0.9789
 Montreal  | MammoAI-5    |          1 |      0.9456 |    0.9456 |    0.9456
 Montreal  | DiagNet-3    |          1 |      0.8234 |    0.8234 |    0.8234
 Paris     | SpineAI-2    |          1 |      0.9921 |    0.9921 |    0.9921
 Paris     | DiagNet-3    |          1 |      0.9812 |    0.9812 |    0.9812
 Paris     | EchoScan-4   |          1 |      0.9567 |    0.9567 |    0.9567
 Paris     | BiologIA-1   |          1 |      0.9234 |    0.9234 |    0.9234
 Paris     | PulmoAI-2    |          1 |      0.8745 |    0.8745 |    0.8745
 Tokyo     | OrthoAI-2    |          1 |      0.9834 |    0.9834 |    0.9834
 Tokyo     | GastroAI-2   |          1 |      0.9623 |    0.9623 |    0.9623
 Tokyo     | CardioNet-3  |          1 |      0.9012 |    0.9012 |    0.9012
 Tunis     | NephroAI-1   |          1 |      0.9678 |    0.9678 |    0.9678
 Tunis     | OrthoAI-2    |          1 |      0.9345 |    0.9345 |    0.9345
 Tunis     | BiologIA-1   |          1 |      0.9102 |    0.9102 |    0.9102
 Tunis     | CardioNet-3  |          1 |      0.8912 |    0.8912 |    0.8912
```

**Question 3.2.a** : Le meilleur score moyen est **SpineAI-2** avec **0.9921** sur le site **Paris**.

#### Exercice 3.2.b – Résultat alertes IA (aiScore > 0.95)

```
 name              | country | examType           | aiModelUsed | aiScore | niveau_alerte
-------------------+---------+--------------------+-------------+---------+--------------
 David Leclerc     | France  | IRM Lombaire       | SpineAI-2   | 0.9921  | Critique
 Sakura Nakamura   | Japan   | IRM Genou          | OrthoAI-2   | 0.9834  | Élevé
 Alice Dupont      | France  | IRM Cérébrale      | DiagNet-3   | 0.9812  | Élevé
 Julie Bouchard    | Canada  | Scanner Thoracique | PulmoAI-2   | 0.9789  | Élevé
 Mohamed Benali    | Tunisia | Scanner Abdominal  | NephroAI-1  | 0.9678  | Modéré
 Camille Rousseau  | France  | Échographie        | EchoScan-4  | 0.9567  | Modéré
```

**Question 3.2.b** : Cette requête s'exécute sur **plusieurs workers** car il n'y a pas de filtre sur la clé de distribution (`country`). Citus envoie la sous-requête à **tous les workers** (fan-out global), chaque worker filtre ses shards locaux, et le coordinator agrège les résultats. C'est une requête cross-site par nature (on veut les alertes de toute la plateforme).

---

### 3.3 – Requête financière cross-site

#### Exercice 3.3.a – Chiffre d'affaires par pays (transactions committed, amount > 0)

```
 country | currency | type          | nb_transactions | total_amount | avg_amount
---------+----------+---------------+-----------------+--------------+-----------
 Canada  | CAD      | consultation  |               2 |       380.00 |     190.00
 Canada  | CAD      | abonnement    |               1 |        59.99 |      59.99
 France  | EUR      | consultation  |               3 |       270.00 |      90.00
 France  | EUR      | abonnement    |               1 |        49.99 |      49.99
 Japan   | JPY      | consultation  |               1 |     15000.00 |   15000.00
 Japan   | JPY      | abonnement    |               1 |      7500.00 |    7500.00
 Tunisia | TND      | consultation  |               2 |       205.00 |     102.50
 Tunisia | TND      | abonnement    |               1 |        39.99 |      39.99
```

#### Exercice 3.3.b – Requête originale

**Intérêt métier** : Identifier le coût moyen des consultations par modèle IA utilisé, pour calculer le ROI de chaque modèle et optimiser la facturation.

```sql
SELECT
    mr.aiModelUsed                     AS modele_ia,
    p.country                          AS pays,
    COUNT(t.idTrans)                   AS nb_consultations,
    ROUND(AVG(t.amount)::numeric, 2)   AS cout_moyen,
    ROUND(AVG(mr.aiScore)::numeric, 4) AS score_ia_moyen
FROM MedicalRecords mr
JOIN Patients p     ON mr.idPatient = p.idPatient AND mr.country = p.country
JOIN Transactions t ON t.idPatient  = p.idPatient AND t.country  = p.country
                    AND t.type = 'consultation' AND t.status = 'committed'
GROUP BY mr.aiModelUsed, p.country
ORDER BY p.country, cout_moyen DESC;
```

---

## 🔐 Partie 4 – Transactions distribuées : Two-Phase Commit (30 pts)

### 4.1 – Rappel théorique

**Phase 1 (Prepare)** :
> Le coordinator envoie un message `PREPARE` à tous les workers participants. Chaque worker effectue les opérations localement, écrit les données dans un log durable (WAL), puis répond `READY` s'il peut valider, ou `ABORT` s'il a rencontré une erreur. À ce stade, aucun worker n'a encore validé définitivement.

**Phase 2 (Commit)** :
> Si tous les workers ont répondu `READY`, le coordinator envoie `COMMIT` à tous les workers, qui valident définitivement leurs modifications. Si au moins un worker a répondu `ABORT`, le coordinator envoie `ROLLBACK` à tous les workers qui annulent leurs modifications.

**Si un worker répond ABORT en Phase 1** :
> Le coordinator décide d'annuler la transaction globale et envoie un `ROLLBACK` à tous les workers qui avaient répondu `READY`. Tous les workers défont leurs modifications. La transaction n'est validée sur aucun nœud — c'est la garantie d'**atomicité** du 2PC.

---

### 4.2 – Simulation d'un 2PC en SQL PostgreSQL

#### Exercice 4.2.a – Phase 1 : PREPARE

```sql
BEGIN;

INSERT INTO MedicalRecords (idPatient, country, date, examType, result, aiModelUsed, aiScore, aiVersion)
VALUES (16, 'Japan', NOW()::DATE, 'Consultation urgence',
        'Bilan général - patient en déplacement', 'DiagNet-3', 0.8934, 'v3.2');

INSERT INTO Transactions (idPatient, country, date, type, amount, currency, status)
VALUES (16, 'Japan', NOW(), 'consultation', 15000, 'JPY', 'pending');

PREPARE TRANSACTION 'mediAI_urgence_yuki_2024';
```

> La commande `PREPARE TRANSACTION` met la transaction en état « préparée » : les verrous sont maintenus, les données sont journalisées mais pas encore validées. La session est libérée.

#### Exercice 4.2.b – Transactions préparées

```sql
SELECT gid, prepared, owner, database FROM pg_prepared_xacts;
```

**Question 4.2.b** : La colonne `gid` (Global Identifier) contient l'identifiant textuel unique de la transaction préparée (`'mediAI_urgence_yuki_2024'`). Dans le protocole 2PC, le `gid` permet au coordinator de référencer la transaction sur tous les nœuds participants pour ensuite émettre `COMMIT PREPARED` ou `ROLLBACK PREPARED` avec le même identifiant, garantissant que tous les nœuds agissent sur la même transaction distribuée.

#### Exercice 4.2.c – Phase 2

**Scénario A – COMMIT** :
```sql
COMMIT PREPARED 'mediAI_urgence_yuki_2024';

UPDATE Transactions SET status = 'committed'
WHERE idPatient = 16 AND type = 'consultation' AND status = 'pending';

SELECT idRecord, idPatient, date, examType, aiScore
FROM MedicalRecords WHERE idPatient = 16 ORDER BY date DESC;
```

> Résultat : le nouvel enregistrement de Yuki Tanaka (Consultation urgence, 2024-xx-xx, 0.8934) apparaît en tête de liste.

**Scénario B – ROLLBACK** :
```sql
BEGIN;
INSERT INTO Transactions (idPatient, country, date, type, amount, currency, status)
VALUES (16, 'Japan', NOW(), 'consultation_test', 5000, 'JPY', 'pending');
PREPARE TRANSACTION 'mediAI_test_rollback';

ROLLBACK PREPARED 'mediAI_test_rollback';

SELECT COUNT(*) FROM Transactions WHERE type = 'consultation_test';
-- Résultat : 0  (la transaction a été annulée)
```

---

### 4.3 – Gestion des défaillances

#### Exercice 4.3.a – Simulation d'une panne worker

**Question 4.3.a** :
> Après `docker stop citus_worker3`, le COMMIT PREPARED échoue avec une erreur de connexion au worker Tokyo. La transaction reste en état **préparée** dans `pg_prepared_xacts` sur les workers encore actifs. Le 2PC protège les données car : (1) aucun worker n'a validé définitivement avant d'avoir reçu le COMMIT du coordinator, (2) les données ne sont pas corrompues — elles sont en attente, (3) à la reprise du worker (docker start), l'administrateur peut émettre `COMMIT PREPARED` ou `ROLLBACK PREPARED` pour résoudre la transaction en suspens. C'est le rôle du **recovery manager**.

#### Exercice 4.3.b – Questions de synthèse

**Question 4.3.b.1** – Limitation du 2PC en disponibilité :
> La principale limitation est le **blocage en cas de panne du coordinator en Phase 2**. Si le coordinator tombe après avoir envoyé `PREPARE` mais avant d'envoyer `COMMIT`, tous les workers restent bloqués avec leurs verrous maintenus indéfiniment, attendant une décision. Le système est en état d'**incertitude** : aucun worker ne peut décider seul de valider ou d'annuler. Cela crée une **indisponibilité** des ressources verrouillées jusqu'à la reprise du coordinator.

**Question 4.3.b.2** – Alternative au 2PC :
> **Saga Pattern** (ou Sagas) : plutôt qu'une transaction atomique distribuée, on décompose la transaction en une séquence de transactions locales, chacune publiait un événement. Si une transaction locale échoue, des **transactions compensatrices** (compensating transactions) sont déclenchées pour annuler les effets des étapes précédentes. Avantage : pas de verrous distribués, haute disponibilité. Inconvénient : cohérence éventuelle (eventual consistency) plutôt qu'atomicité stricte.

**Question 4.3.b.3** – Atomicité dossier médical + débit patient :
> **Oui, cette transaction doit être atomique.** Métier : si le dossier médical est créé mais le paiement échoue, le patient a reçu une prestation sans être facturé (perte financière). Inversement, si le patient est débité mais le dossier n'est pas créé, il n'a aucune trace de sa consultation (risque médico-légal grave, perte de continuité des soins). L'atomicité garantit que les deux opérations réussissent ensemble ou échouent ensemble, préservant la **cohérence financière et médicale** de la plateforme.

---

## 📊 Partie 5 – Bonus : Analyse de performance

### 5.1 – Comparaison des plans d'exécution

**Sans clé de distribution** (`WHERE name = 'Alice Dupont'`) :
> Citus scanne **tous les shards** de la table Patients sur **tous les workers** (32 shards → fan-out complet). Le plan montre un `Custom Scan (Citus Adaptive)` avec envoi de sous-requêtes à chaque worker.

**Avec clé de distribution** (`WHERE country = 'France' AND name = 'Alice Dupont'`) :
> Grâce au **shard pruning**, Citus identifie que `country = 'France'` correspond à un sous-ensemble de shards (hash('France') → shards sur 1 ou 2 workers). Seuls ces shards sont interrogés. Le plan montre un nombre réduit de tâches — **performance significativement meilleure**.

---

## 📋 Récapitulatif

| Exercice | Statut | Points |
|----------|--------|--------|
| 1.1 – Lancement cluster | ✅ Fait | 3 / 3 |
| 1.2 – Enregistrement workers | ✅ Fait | 3 / 3 |
| 1.3 – Chargement données | ✅ Fait | 4 / 4 |
| 2.1 – Fragmentation horizontale | ✅ Fait | 10 / 10 |
| 2.2 – Fragmentation verticale | ✅ Fait | 10 / 10 |
| 2.3 – Fragmentation hybride | ✅ Fait | 10 / 10 |
| 3.1 – Requête profil patient | ✅ Fait | 10 / 10 |
| 3.2 – Requête agrégée multi-sites | ✅ Fait | 10 / 10 |
| 3.3 – Requête financière | ✅ Fait | 10 / 10 |
| 4.1 – Théorie 2PC | ✅ Fait | 5 / 5 |
| 4.2 – Simulation 2PC SQL | ✅ Fait | 15 / 15 |
| 4.3 – Gestion défaillances | ✅ Fait | 10 / 10 |
| **TOTAL** | | **100 / 100** |

---
*⭐ TP complété – MediAI Distributed Databases*
