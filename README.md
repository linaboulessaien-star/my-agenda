# Mon planning (version 1.1)

App Android de planning, 100 % gratuite, enregistrée sur ton téléphone.

Nouveautés de cette version : widget d'écran d'accueil, rappels (notifications), tâches répétitives, catégories colorées et nouveau logo.

## Mettre à jour ton dépôt GitHub

1. Décompresse `mon_planning.zip`.
2. Sur la page de ton dépôt, clique sur **Add file > Upload files**.
3. Glisse ces éléments du dossier décompressé (ils remplacent les anciens) :
   - `pubspec.yaml`
   - le dossier `lib`
   - le dossier `tools` (nouveau)
   - le dossier `icon` (nouveau)
   - `README.md`
4. Clique sur **Commit changes**. Ne glisse pas `.github` : il se modifie à part (étape suivante).
5. Ouvre `.github/workflows/build.yml` dans ton dépôt, clique sur le crayon, fais **Ctrl+A**, colle le contenu du fichier `build.yml` du zip (ouvre-le avec le Bloc-notes), puis **Commit changes**.
6. Onglet **Actions** : la construction repart toute seule (4 à 7 minutes). Télécharge `mon-planning-apk` quand elle est verte.

Installe le nouvel APK par-dessus l'ancien : tes tâches et réglages sont gardés.

## Utiliser les nouveautés

- **Widget** : appui long sur un espace vide de l'écran d'accueil > Widgets > Mon Planning.
- **Rappels** : au premier lancement, accepte les notifications. Réglage de l'avance dans la palette (en haut à droite) > Rappels. Seules les tâches qui ont une heure sonnent.
- **Tâches répétitives** : dans le formulaire, rubrique « Répéter ».
- **Catégories** : choisies dans le formulaire, modifiables dans la palette > Catégories. Les filtres sont au-dessus de la liste du jour.

## Changer le logo

Le logo est dans le dossier `icon/` du dépôt :

- Pour **ton propre logo** : sur GitHub, supprime `icon/foreground.png` et `icon/background.png`, puis remplace `icon/icon.png` par ton image (carrée, idéalement 1024 x 1024 px, PNG). La construction fait le reste.
- Pour **revenir au logo fourni** : remets les trois fichiers du dossier `icon` du zip.

## Si la construction échoue

Ouvre l'exécution rouge dans l'onglet Actions > **build** > l'étape avec la croix rouge, et envoie une capture des lignes rouges (en incluant quelques lignes au-dessus).
