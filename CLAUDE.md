# Korin de Suna : contexte du projet

Site du **Korin de Suna**, tournoi de 2 contre 2 avec paris en ryos, pour une communauté de roleplay inspirée de Naruto. Organisé par la famille Chiiketsu. Tout est en français.

- En ligne : https://lune-ecl.github.io/korin-suna/ (GitHub Pages, branche `main`, racine)
- Base de données : Supabase, projet `korin-suna`, URL `https://jidpdwngoazxcdgpmwyc.supabase.co`

## Fichiers
- `index.html` : tout le site (HTML, CSS et JS dans un seul fichier, aucune étape de build). La librairie `@supabase/supabase-js` est chargée depuis jsDelivr.
- `schema.sql` : tables, sécurité (RLS) et temps réel. À coller dans Supabase → SQL Editor → Run. Le script peut être relancé sans risque.

## Fonctionnement
- `CONFIG` en haut du script : `SUPABASE_URL` et `SUPABASE_ANON_KEY`. Si la clé est vide, le site passe en **mode démo** (données d'exemple dans le navigateur).
- Pages (onglets) : Accueil, Tableau, Équipes, Paris, Classement, Historique, Orga.
- Format : élimination directe, nombre d'équipes variable, exemptions réparties dans le tableau.
- Paris : cotes fixées par les orgas pour chaque combat, cote gelée au moment du pari, gain = mise × cote. Les paris sont réglés automatiquement quand un vainqueur est déclaré.
- Seuls les organisateurs écrivent : inscription des équipes, paris, cotes, résultats. Le public lit tout sans compte.
- Connexion par **nom d'utilisateur + mot de passe**, sans e-mail : le site fabrique un e-mail invisible `pseudo@korin-suna.app`. Un trigger crée la ligne `profiles`. Un nouveau compte n'a aucun droit tant qu'un orga ne l'a pas validé (table `admins`, section « Comptes organisateurs » de l'onglet Orga).
- Thème : sombre noir et bordeaux, doré, kanjis rouges. La propriétaire a demandé de **ne pas** remettre l'affiche du Korin sur le site.

## Reste à faire
1. Récupérer la clé **anon public** (ou `sb_publishable_…`) dans Supabase → Project Settings → API Keys, puis la mettre dans `CONFIG`. Ne jamais utiliser la clé `service_role` ni la clé secrète.
2. Lancer `schema.sql` dans le SQL Editor de Supabase.
3. Dans Supabase → Authentication → Sign In / Providers → Email, désactiver « Confirm email ».
4. La propriétaire crée son compte sur le site (Orga → Créer un compte), puis lance dans le SQL Editor :
   `insert into public.admins (user_id) select user_id from public.profiles where username = 'son_pseudo';`
