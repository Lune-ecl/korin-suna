# Korin de Suna : contexte du projet

Site du **Korin de Suna**, tournoi de 2 contre 2 avec paris en ryos, pour une communauté de roleplay inspirée de Naruto. Organisé par la famille Chiiketsu. Tout est en français.

- En ligne : https://lune-ecl.github.io/korin-suna/ (GitHub Pages, branche `main`, racine)
- Base de données : Supabase, projet `korin-suna`, URL `https://jidpdwngoazxcdgpmwyc.supabase.co`

## Fichiers
- `index.html` : tout le site (HTML, CSS et JS dans un seul fichier, aucune étape de build). La librairie `@supabase/supabase-js` est chargée depuis jsDelivr.
- `schema.sql` : tables, sécurité (RLS) et temps réel. À coller dans Supabase → SQL Editor → Run. Le script peut être relancé sans risque.

## Fonctionnement
- `CONFIG` en haut du script : `SUPABASE_URL` et `SUPABASE_ANON_KEY`. Si la clé est vide, le site passe en **mode démo** (données d'exemple dans le navigateur).
- Pages (onglets) : Accueil, Tableau, Équipes, Paris, Classement, Historique, Orga, Compte (connexion / solde). **Le public et les joueurs ne voient que Tableau, Équipes, Paris, Classement et Compte** (demande de la propriétaire) ; Accueil, Historique et Orga sont réservés aux orgas (`ORGA_ONLY` dans `index.html`, simple masquage d'interface).
- Format : élimination directe, nombre d'équipes variable, exemptions réparties dans le tableau.
- Paris : cotes fixées par les orgas pour chaque combat, cote gelée au moment du pari, gain = mise × cote. Les paris sont réglés automatiquement quand un vainqueur est déclaré.
- **Porte-monnaie** : chaque compte a un solde en ryos (`profiles.balance`) et un registre (`ledger`). Le solde ne bouge que par les triggers de `bets` (mise prélevée à l'insertion, gain versé quand le statut passe à `gagne`, repris si le résultat est annulé, mise rendue si un pari en cours est supprimé) et par la fonction `adjust_ryos` (crédit/retrait par un orga). Un compte démarre à 0.
- **Confidentialité des paris** : RLS de `bets` = chacun ne lit que ses paris, la gérance lit tout. Le public n'a que des totaux via les fonctions `bet_totals()` (par combat/équipe) et `leaderboard()` (classement des parieurs). Le site rafraîchit ces totaux toutes les 30 s (le temps réel ne transmet pas les paris invisibles). Si ces fonctions manquent, le site recalcule à partir des paris visibles.
- **Blacklist** (table `blacklist`, gérée dans l'onglet Gérance) : comparaison par `name_key()` (sans accents ni majuscules, même règle que `nameKey` en JS). Un nom blacklisté ne peut ni s'inscrire (`handle_new_user`), ni parier (trigger `bets_before_insert`), ni être inscrit dans une équipe (trigger `teams_check_blacklist`). Lecture réservée à la gérance ; `is_blacklisted(nom)` est appelable par tous.
- « Orga » s'appelle **Gérance** dans l'interface (onglet, rôle « Gérant », bouton « Nommer gérant », sans confirmation). L'inscription des comptes est libre et immédiate.
- Les joueurs connectés parient eux-mêmes (un seul camp par combat) et peuvent annuler tant que les paris du combat sont ouverts. Les orgas gèrent équipes, cotes, résultats, et peuvent parier pour le compte d'un joueur. Le public lit tout sans compte.
- Connexion par **nom RP (prénom + nom, ex. « Ryuta Chiiketsu ») + mot de passe**, sans e-mail : le site fabrique un e-mail invisible à partir du nom sans accents ni majuscules (`ryuta.chiiketsu@korin-suna.app`), donc « Ryūta chiiketsu » ouvre le même compte. Le nom tel qu'écrit à l'inscription est affiché (`profiles.username`). Un trigger crée la ligne `profiles`. Les droits d'orga se donnent dans la table `admins` (section « Comptes et ryos » de l'onglet Orga).
- En mode démo, pas de comptes : l'orga saisit le nom du parieur à la main, sans solde.
- Thème : sombre noir et bordeaux, doré, kanjis rouges. La propriétaire a demandé de **ne pas** remettre l'affiche du Korin sur le site.

## Reste à faire
1. ~~Clé publique dans `CONFIG`~~ : fait (`sb_publishable_…`). Ne jamais utiliser la clé `service_role` ni la clé secrète.
2. ~~`schema.sql` lancé, « Confirm email » désactivé~~ : fait. À relancer après chaque modification de `schema.sql`.
3. La propriétaire crée son compte sur le site (Connexion → Créer un compte), puis lance dans le SQL Editor :
   `insert into public.admins (user_id) select user_id from public.profiles where lower(username) = lower('Son Nom');`
