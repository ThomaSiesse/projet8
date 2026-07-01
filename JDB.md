# Journal de bord Projet 8

## 29/06/2026
### Fait
**Instalation** de  Airbyte + début de cours
**Instalation** de DBT + début de cours
### A faire demain
Finir les cours

## 30/06/2026
### Tâches 
    1. Cours Airbyte
    2. Création d'un docker-compose.yml dans Projet_8 
        - création du docker-compose.yml
        - lancement avec `docker compose up -d`
        - docker ps | grep postgres-projet8  --> pour vérifier que tout tourne bien (vérification du bon ports)
    3. vérifier l'accées à Airbyte: `abctl local credentials`
    4. connecter Airbyte aux données puis à postgreSQL
        - *Je ne parviens pas à connecter aux sources et à la destination airbyte*.
            Pour la connexion destination je dois utiliser docker network inspect bridge | grep Gateway pour obtenir la connexion host qui est: 172.17.0.1
            Destination connecté
        - connection à une première source: le lien URL
        -Connection source/destination
        -configuration de la connection: source: lien URL, Destination: Public.donnee_meteo_1, Fréquence: 1h 
        - création d'une doc via claude.ia
        - Connection d'un deuxième fichier via google sheet

### A faire demaine
    - connection airbyte - google sheet
    - connection des deux derniers fichier data
    - finir étapes 1 du projet
