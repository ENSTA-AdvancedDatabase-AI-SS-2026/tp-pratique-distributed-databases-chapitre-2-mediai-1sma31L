[![Review Assignment Due Date](https://classroom.github.com/assets/deadline-readme-button-22041afd0340ce965d47ae6ef1cefeee28c7c493a6346c4f15d667ab976d596c.svg)](https://classroom.github.com/a/xhrImUUE)
# TP Pratique – Chapitre 2 : Distributed Databases
## ENSTA 3A – AI & Systèmes de Santé

> **Cas d'étude** : MediAI – Plateforme de santé intelligente distribuée sur 4 sites (Paris, Tunis, Montréal, Tokyo)

## Lien du site
[Voir le site TP](https://ensta-advanceddatabase-ai-ss-2026.github.io/ensta-advanceddatabase-ai-ss-2026-classroom-5e3d4d-tp-pratique-chapitre-2-mediai-tp-pratique-distrib/#setup)

## 🎯 Objectifs pédagogiques

| # | Objectif |
|---|----------|
| 1 | Mettre en place un cluster PostgreSQL + **Citus** (coordinator + 3 workers) |
| 2 | Implémenter les 3 types de **fragmentation** (horizontale, verticale, hybride) |
| 3 | Exécuter et analyser des **requêtes distribuées** (EXPLAIN, JOIN distribué) |
| 4 | Simuler une **transaction distribuée 2PC** (Two-Phase Commit) |
| 5 | Comprendre les stratégies d'**allocation et réplication** |

---

## 🗂️ Structure du repository

```
tp-pratique-distributed-databases-chapitre-2-mediAI/
├── README.md
├── docker-compose.yml
├── data/
│   ├── schema-mediAI.sql          # Création des tables
│   ├── seed-mediAI.sql            # Données de test réalistes
│   └── init-cluster.sql           # Enregistrement des workers Citus
├── exercises/
│   └── 01-TP-Pratique-Distributed-Databases-MediAI.md   # Sujet complet
└── solutions/
    └── solution-reference.sql     # Correction (réservée au prof)
```

---

## 🚀 Démarrage rapide

### Prérequis
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installé
- [DBeaver](https://dbeaver.io/) ou `psql` disponible

### Lancement du cluster

```bash
# 1. Cloner le repo
git clone https://github.com/votre-org/tp-pratique-distributed-databases-chapitre-2-mediAI.git
cd tp-pratique-distributed-databases-chapitre-2-mediAI

# 2. Démarrer les 4 nœuds (1 coordinator + 3 workers)
docker-compose up -d

# 3. Vérifier que tout tourne
docker ps

# 4. Se connecter au coordinator (nœud maître)
docker exec -it citus_master psql -U postgres -d mediAI
```

### Charger le schéma et les données

```bash
# Depuis l'intérieur du container coordinator
docker exec -it citus_master psql -U postgres -d mediAI -f /data/schema-mediAI.sql
docker exec -it citus_master psql -U postgres -d mediAI -f /data/init-cluster.sql
docker exec -it citus_master psql -U postgres -d mediAI -f /data/seed-mediAI.sql
```

---

## 📊 Architecture MediAI – 4 sites géographiques

```
        ┌─────────────────────────────────────┐
        │         COORDINATOR (Master)         │
        │    citus_master  :5432               │
        │    Paris HQ – nœud de coordination   │
        └──────────┬──────────────────────────┘
                   │ distribue les requêtes
         ┌─────────┼──────────────────────────┐
         ▼         ▼                          ▼
   ┌───────────┐ ┌───────────┐          ┌───────────┐
   │  Worker 1 │ │  Worker 2 │          │  Worker 3 │
   │  Tunis    │ │  Montréal │          │  Tokyo    │
   └───────────┘ └───────────┘          └───────────┘
```

### Répartition des données

| Table           | Site Paris | Site Tunis | Site Montréal | Site Tokyo |
|-----------------|-----------|------------|---------------|------------|
| Patients        | ✅ France  | ✅ Tunisia  | ✅ Canada      | ✅ Japan    |
| MedicalRecords  | ✅ Frag H  | ✅ Frag H   | ✅ Frag H      | ✅ Frag H   |
| TrainingData    | ✅         | ✅          | ✅             | ✅          |
| Transactions    | ✅ Hybride | ✅ Hybride  | ✅ Hybride     | ✅ Hybride  |

---

## 📝 Barème

| Partie | Sujet | Points |
|--------|-------|--------|
| Partie 1 | Mise en place du cluster | 10 pts |
| Partie 2 | Fragmentation (H, V, Hybride) | 30 pts |
| Partie 3 | Requêtes distribuées | 30 pts |
| Partie 4 | Transactions distribuées 2PC | 30 pts |
| **Total** | | **100 pts** |

---

## 🔗 Ressources utiles

- [Documentation officielle Citus](https://docs.citusdata.com/)
- [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html)
- [Two-Phase Commit – PostgreSQL](https://www.postgresql.org/docs/current/sql-prepare-transaction.html)
- [Cours Distributed Databases – Chapitre 2](#)

---

⭐ *Bon TP ! L'équipe pédagogique ENSTA*
