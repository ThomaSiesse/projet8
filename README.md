# Projet 8 : construire et tester une infrastructure de données (Forecast 2.0)

Pipeline ELT de données météo, de l'ingestion multi-sources jusqu'à un entrepôt de données testé, documenté et déployé sur AWS.

**Airbyte** → **PostgreSQL (RDS)** → **dbt (ECS Fargate)** → **SageMaker**

## Contexte

**GreenCoop** est un fournisseur coopératif d'électricité renouvelable dans les Hauts-de-France. Pour équilibrer production et consommation en temps réel, il veut enrichir ses modèles de prévision de la demande avec de nouvelles sources météo. C'est l'objet du projet **Forecast 2.0**, qui vise en particulier les zones mal couvertes par les stations officielles.

Contraintes du projet :

- **sources hétérogènes** : InfoClimat et Weather Underground, avec des formats, des unités et des fréquences différents ;
- **exhaustivité** : toutes les informations des sources doivent être conservées dans la base finale ;
- **hébergement imposé** : PostgreSQL sur AWS ;
- **outils recommandés** : Airbyte pour l'ingestion, dbt pour la transformation et les tests ;
- **exploitation** : les data scientists doivent accéder directement aux données depuis SageMaker.

## Sources de données

| Source           | Origine                                                        | Format brut | Unités natives   | Fréquence |
| ---------------- | -------------------------------------------------------------- | ----------- | ----------------- | ---------- |
| `hourly`       | Météo-France / InfoClimat (réseau officiel)                 | JSON (S3)   | °C, hPa, km/h, m | Horaire    |
| `ichtegem`     | Weather Underground, station personnelle (Belgique)            | Excel       | °F, inHg, mph    | 5 min      |
| `la_madeleine` | Weather Underground, station personnelle (France)              | Excel       | °F, inHg, mph    | 5 min      |
| `station`      | Référentiel des stations officielles (id, nom, GPS, licence) | JSON        |                   |            |
| `metadata`     | Dictionnaire des variables (description, unité)               | JSON        |                   |            |

Les stations personnelles ne figurent pas dans le référentiel officiel. Le seed dbt `dim_weather_stations_amateur.csv` les y ajoute.

## Architecture

```text
Sources (JSON, Excel→CSV)
   │  Airbyte (connecteur File, synchronisation horaire)
   ▼
PostgreSQL : tables brutes (schéma public)
   │  dbt
   ├─ staging       nettoyage, typage, harmonisation des unités
   ├─ intermediate  cumuls de pluie, unification des 3 sources
   └─ marts         schéma en étoile
   ▼
Exploitation : requêtes SQL, notebook SageMaker (lecture seule)
```

### Déploiement AWS

| Service           | Ressource                                                  | Rôle                                           |
| ----------------- | ---------------------------------------------------------- | ----------------------------------------------- |
| EC2               | `meteo-projet8-airbyte`                                  | Airbyte, installé avec `abctl` (chart 1.7.0) |
| RDS PostgreSQL 15 | `meteo-projet8-db`                                       | Entrepôt de données, seule source de vérité |
| ECR               | `meteo-projet8-dbt`                                      | Image Docker du projet dbt                      |
| ECS Fargate       | `meteo-projet8-dbt-task`                                 | Exécution de `dbt run`                       |
| EventBridge       | `meteo-projet8-dbt-daily`                                | Planification quotidienne de la tâche dbt      |
| SageMaker         | `meteo-projet8-notebook`                                 | Accès aux données pour les data scientists    |
| Parameter Store   | `/meteo-projet8/rds/*`                                   | Secrets RDS (SecureString)                      |
| CloudWatch / SNS  | `/ecs/meteo-projet8-dbt-task`, `meteo-projet8-alertes` | Logs, alarmes et notifications par e-mail       |

Tous les services sont dans le même VPC. Les accès entre services sont autorisés par référence de security group, pas par adresse IP fixe.

## Modèle de données

Le modèle est un schéma en étoile centré sur **`fact_weather_data`**. Sa clé primaire composite est `id_station` + `date` + `heure`.

| Table                    | Contenu                                                                                                                                                     |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fact_weather_data`    | Relevés : température, pression, humidité, vent (moyen, rafales, direction), pluie (1 h, 3 h, cumulée), nébulosité, temps OMM, indice UV, rayonnement |
| `dim_weather_stations` | Stations : id, nom, latitude, longitude, altitude, type                                                                                                     |
| `dim_time`             | Calendrier : date, jour de la semaine, semaine, mois, année, noms des jours et des mois                                                                    |
| `dim_weather_metadata` | Dictionnaire des variables : nom, description, unité (table de référence)                                                                                |

### Modèles dbt (15 au total)

| Couche       | Modèles                                                                                       |
| ------------ | ---------------------------------------------------------------------------------------------- |
| Staging      | `stg_hourly`, `stg_ichtegem`, `stg_la_madeleine`, `stg_stations`, `stg_metadata`     |
| Intermediate | `int_hourly_pluie`, `int_ichtegem_pluie`, `int_la_madeleine_pluie`, `int_unified_data` |
| Marts        | `fact_weather_data`, `dim_weather_stations`, `dim_weather_metadata`, `dim_time`        |

Principales transformations :

- conversion des unités : °F → °C, mph → km/h, inHg → hPa, direction du vent en texte → degrés ;
- nettoyage des valeurs texte qui contiennent leur unité (`regexp_replace` et `nullif`) ;
- suppression des lignes d'en-tête de date insérées chaque jour dans les fichiers Weather Underground ;
- calcul des cumuls de pluie avec `SUM() OVER`, partitionné par station et par jour.

## Qualité des données

Les **53 tests dbt** passent, sans aucun avertissement.

| Type de test                                                        | Nombre |
| ------------------------------------------------------------------- | ------ |
| `accepted_range` (plages physiques plausibles)                    | 35     |
| `not_null`                                                        | 14     |
| `unique`                                                          | 2      |
| `relationships`                                                   | 1      |
| Clé composite unique (`dbt_utils.unique_combination_of_columns`) | 1      |

Exemples de règles : humidité entre 0 et 100 %, pression entre 900 et 1 100 hPa, point de rosée inférieur ou égal à la température.

Résultats de l'exécution planifiée en production :

- run dbt complet (15 modèles) en **20,1 s** ;
- **4 941 lignes** dans `fact_weather_data`.

## Structure du dépôt

| Élément                                                                | Description                                                                      |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `meteo_projet8/`                                                       | Projet dbt : modèles, seeds, `Dockerfile` de l'image ECS                      |
| `script.ipynb`                                                         | Découpe le JSON source et les classeurs Excel en un CSV par feuille ou par clé |
| `hourly.csv`, `stations.csv`, `metadata.csv`                       | Extraits du JSON InfoClimat                                                      |
| `ichtegem_complet.csv`, `La_madeleine_complet.csv`, `data_source/` | Données Weather Underground converties en CSV                                   |
| `docker-compose.yml`                                                   | PostgreSQL 15 local pour le développement (port 5434)                           |
| `Documentation_Projet8.docx`                                           | Documentation de l'environnement Airbyte / PostgreSQL local                      |
| `JDB.md`                                                               | Journal de bord du projet                                                        |
| `Soutenance_forecast2.0/`                                              | Captures d'écran pour la soutenance                                             |
| `Construisez_et_testez_une_infracstructure_de_données_siesse_thomas/` | Support de présentation                                                         |

## Lancer le projet en local

Prérequis : Docker, `abctl` (Airbyte) et Python 3.11 ou plus récent.

```bash
# 1. PostgreSQL local (port 5434)
docker compose up -d

# 2. Airbyte (interface sur http://localhost:8000)
abctl local install
abctl local credentials
```

Dans Airbyte, créez une destination Postgres. Utilisez l'hôte `172.17.0.1` (passerelle Docker) et non `localhost`, puis une source « File » par fichier.

```bash
# 3. dbt
python -m venv dbt-env && source dbt-env/bin/activate
pip install dbt-postgres==1.10.2
cd meteo_projet8
dbt deps          # installe dbt_utils et codegen
dbt seed          # charge les stations personnelles
dbt run           # construit les 15 modèles
dbt test          # lance les 53 tests
dbt docs generate && dbt docs serve   # documentation et graphe de lineage
```

La connexion se configure dans `meteo_projet8/.dbt/profiles.yml`, avec `DBT_PROFILES_DIR` pointant vers ce dossier. Ce fichier contient des identifiants et ne doit pas être versionné.

## Déploiement de dbt sur ECS

```bash
cd meteo_projet8
docker build -t meteo-projet8-dbt .
# Tag et push vers ECR, puis exécution par la Task Definition ECS
# (par défaut : dbt run --target prod)
```

## Sécurité et supervision

- **Secrets** : aucun mot de passe en dur dans les images. Les identifiants RDS sont dans Parameter Store et injectés à l'exécution.
- **Base** : RDS chiffré au repos (KMS) et en transit (SSL/TLS), placé dans un VPC privé.
- **Sauvegardes** : sauvegardes automatiques RDS, protection contre la suppression accidentelle.
- **Supervision** : logs dans CloudWatch, alarmes en cas d'échec du run dbt ou de charge CPU élevée sur RDS, notification par e-mail via SNS.

## Difficultés rencontrées

| Problème                                              | Solution                                                             |
| ------------------------------------------------------ | -------------------------------------------------------------------- |
| Interface Airbyte inaccessible sur EC2                 | Version du chart figée à 1.7.0 et mode basse ressource             |
| Ressources CPU insuffisantes pour les synchronisations | Désactivation des composants inutiles, ajustement de l'instance EC2 |
| Connexions ECS → RDS en timeout                       | Security groups autorisés par référence de groupe                 |
| Accès refusé à Parameter Store depuis ECS           | Politique IAM ciblée sur le rôle d'exécution de la tâche         |
| Lignes dupliquées dans la table de faits              | Comptage couche par couche pour isoler la source                     |

## Auteur

Thomas SIESSE, juillet 2026.
