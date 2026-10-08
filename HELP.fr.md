# CNC G-Coder — Guide de l'utilisateur

*(Ce guide est aussi disponible dans l'application : ⌘? ou le bouton Aide de la barre d'outils.)*

## Vue d'ensemble du flux de travail

1. Exportez les fichiers Gerber + perçage depuis EasyEDA ou KiCad dans un dossier.
2. **Choose Folder** (barre d'outils) — les couches sont détectées automatiquement d'après le nom de fichier.
3. Réglez vos outils, profondeurs et avances (ou chargez un **Preset**). La barre latérale n'affiche que les réglages du programme sélectionné — le menu des couches en haut change à la fois l'aperçu et les réglages ; choisissez-y **Machine setup** pour les paramètres communs à tous les programmes.
4. Inspectez l'aperçu : sélectionnez chaque programme, lancez la lecture, vérifiez les profondeurs dans la vue latérale et l'estimation de durée totale.
5. **Generate** — choisissez (ou créez avec New Folder) le dossier de destination ; tous les programmes `.ngc` y sont écrits.
6. Usinez dans l'ordre : isolation du cuivre face avant → perçages (un programme par fichier de perçage ; changez de foret aux pauses M0) → retournez la carte → cuivre face arrière → découpe du contour (les ponts retiennent la carte) → cassez/limez les languettes.
7. Vernis épargne : peignez la carte usinée avec un vernis UV, faites-le durcir, puis exécutez `top-mask-etch.ngc` / `bottom-mask-etch.ngc` pour dégager les ouvertures des pastilles.

Avec un graveur laser à la place de la fraiseuse (ou en complément) : chaque programme peut aussi être exporté en dessin à l'échelle 1:1 (SVG, PDF ou PNG) — voir *Gravure laser et export de dessins*.

## Dossier du projet et détection

Les exports EasyEDA sont reconnus par leur extension : `Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, vernis épargne `.GTS`/`.GBS`, sérigraphies `.GTO`/`.GBO` et fichiers de perçage `.DRL`. EasyEDA sépare les perçages en fichiers PTH / PTH-via / NPTH ; chacun devient un programme distinct, car pcb2gcode n'accepte qu'un fichier de perçage par exécution.

Les exports KiCad sont reconnus par les noms de couches de KiCad : `board-F_Cu.gbr` / `board-B_Cu.gbr` (cuivre), `board-Edge_Cuts.gbr` (contour), `board-F_Mask.gbr` / `board-B_Mask.gbr`, `board-F_Silkscreen.gbr` / `board-B_Silkscreen.gbr`, et `board.drl` ou `board-PTH.drl` + `board-NPTH.drl`. Les fichiers de pâte, fab, courtyard, cuivre interne, plan de perçage et job sont ignorés. Dans le dialogue de perçage de KiCad, choisissez le format **Excellon** (pas Gerber X2) et utilisez le même réglage d'origine dans les dialogues de tracé et de perçage (les deux avec « drill/place file origin » ou aucun), sinon les perçages se retrouvent décalés par rapport au cuivre. Les exports faits avec « Use Protel filename extensions » fonctionnent aussi.

Generate demande où écrire les programmes (le bouton New Folder du dialogue crée une nouvelle destination) ; le choix est mémorisé jusqu'au changement de projet. L'aperçu en direct utilise un dossier temporaire et ne touche jamais à vos fichiers avant que vous n'appuyiez sur Generate.

## Outils et fraises en V — à lire d'abord

Chaque diamètre que vous saisissez doit être le **diamètre de coupe effectif à la profondeur de travail**, avec la fraise exacte que vous utilisez.

- **Fraises droites / deux tailles** : effectif = diamètre imprimé, saisissez-le tel quel.
- **Fraises en V** (le choix habituel pour l'isolation — les fraises droites de 0,1 mm cassent facilement) : le cône s'élargit avec la profondeur :
  `effectif ≈ pointe + 2 × |profondeur de coupe| × tan(demi-angle)`
  Pour une pointe de 0,1 mm à −0,06 mm : V 30° ≈ **0,13 mm** · V 60° ≈ **0,17 mm** · V 90° ≈ **0,22 mm**.
  Saisir la taille de la pointe à la place rend chaque piste plus fine que prévu et l'isolation plus étroite que demandé — silencieusement.
- **Vérification** : usinez une carte de test (File → Generate Test Board…) et mesurez la piste test de 0,2 mm. Si elle mesure ~0,13 mm avec une fraise V 60° saisie à 0,1, votre diamètre effectif est ~0,07 mm plus grand que saisi — corrigez le paramètre, pas le dessin.

- **Mode V-bit** : réglez **Bit → V-bit** pour l'isolation, le vernis ou la sérigraphie et saisissez pointe et angle à la place ; la largeur à la profondeur est calculée pour vous (et suit la profondeur de coupe).

## Cartes de test

**File → Generate Test Board…** (⇧⌘T) usine une petite carte qui répond à une question sur votre installation. Chaque test a sa propre fraise (**Bit**, depuis la Tool Library ; mémorisée par test — par défaut la fraise d'isolation du cuivre, pour le test de trous la fraise de fraisage de trous) et ses propres réglages ; le Z de sécurité, la garde de plongée et la largeur d'isolation viennent du projet. Le résultat est écrit en `.ngc` à côté d'une légende `.txt` et affiché dans l'aperçu comme n'importe quel programme, pour être lu et envoyé à la machine.

- **Parameter test board** — trouve la profondeur de coupe et l'avance pour l'isolation de production. Une grille de patchs : les lignes balaient la **profondeur de coupe** (de … à), les colonnes balaient l'**avance XY** ; chaque patch a des pistes de 0,2 / 0,3 / 0,4 mm. Chaque piste relie deux pastilles de sonde à l'intérieur d'un fossé d'isolation fermé : un multimètre en mode continuité dit si la piste a survécu (pastille à pastille bipe) et si l'isolation est complète (pastille vers le cuivre environnant reste muet). **Board size** et **Grid** (avances × profondeurs) définissent la disposition ; **Suggest** choisit une grille pour la taille de carte. La légende associe chaque patch à sa profondeur et son avance.
- **Backlash test** — mesure le jeu en X et Y sur une carte de 75 × 75 mm. Par axe, une ligne droite est coupée en deux moitiés atteintes depuis des directions opposées : une marche à la jonction des moitiés est le jeu de cet axe. Un carré de 50 mm et un cercle Ø30 le montrent aussi — côtés courts, ovale. Saisissez la marche dans Machine setup → Backlash compensation et recoupez le test jusqu'à ce que les deux lignes soient droites (voir *Compensation du jeu*).
- **Hole fit test** — trouve la taille de trou qui convient à une broche. Chaque **taille de trou** listée (lignes) est fraisée en plusieurs **variantes** (colonnes : la taille plus un jeu en mm), comme la production fraise les trous — une spirale descendante depuis la surface, puis un cercle de finition. Enfoncez la broche dans chaque trou de sa ligne et gardez la variante qui s'ajuste comme vous le souhaitez ; dessinez le trou à cette taille. Fraisez-le avec la même fraise que la vraie carte.

## Projets

Un projet (`.cncproj`) est un **paquet** autonome : le Finder l'affiche comme un seul fichier, mais clic droit → **Afficher le contenu du paquet** révèle

```
Board.cncproj/
  project.json   paramètres (outils, profondeurs, avances, origine…), rôles des couches, guides, provenance de chaque fichier
  Layers/        les fichiers Gerber et de perçage eux-mêmes, inchangés
```

Déplacez ou copiez le projet seul — il ne perd jamais ses couches. (Pour l'envoyer par e-mail, compressez-le d'abord ; Mail le fait automatiquement.) À l'ouverture d'un projet, ses fichiers sont copiés dans un dossier de travail privé : les originaux ne sont pas nécessaires et ne sont jamais modifiés.

- **File → New Project** (⌘N), **Open Project…** (⌘O), **Open Recent**, **Save Project** (⌘S), **Save Project As…** (⇧⌘S). Les mêmes actions sont dans le menu **Open** de la barre latérale. Le titre de la fenêtre affiche le projet et « Edited » s'il a des modifications non enregistrées ; New, Open et Quit demandent confirmation avant de les abandonner.
- **Open Gerber Folder…** (⇧⌘O) démarre un projet sans titre depuis un dossier d'export EasyEDA ou KiCad, en détectant les couches par nom de fichier, comme avant.
- Les copies empaquetées sont celles que le projet utilise. Si vous réexportez les Gerber depuis votre éditeur de PCB, importez-les avec **Import Layer…** ou **Replace…** (ou ouvrez le nouveau dossier d'export), puis enregistrez. **Show Original in Finder** sur une couche pointe vers le fichier d'origine, s'il existe encore.
- Les projets enregistrés par des versions antérieures (un fichier unique avec les couches incorporées, ou avec des liens vers elles) s'ouvrent toujours et deviennent un paquet à l'enregistrement suivant.
- Le Finder affiche le paquet comme un seul fichier une fois l'application lancée (cela enregistre le type de projet) ; avant, il apparaît comme un dossier nommé `….cncproj`.
- Ouvrir un projet remplace les paramètres courants par ceux du projet.

### Importer des couches individuelles

**File → Import Layer…** (⌘I), ou **Import Layer…** sous Layer files dans la barre latérale, ajoute des fichiers Gerber ou Excellon de n'importe où. Le rôle de chaque fichier est deviné d'après son nom (et les fichiers de perçage d'après leur en-tête M48, quel que soit leur nom) et peut être changé dans la feuille d'import avant l'importation : un fichier de perçage est ajouté comme programme de perçage supplémentaire ; tout autre rôle remplace le fichier de cet emplacement. Clic droit sur un fichier de couche dans la barre latérale pour **Replace…**, **Remove** ou **Show in Finder**.

## Exporter un seul programme

Avec une couche sélectionnée, **CNC export → Export <nom>.ngc…** dans la barre latérale enregistre uniquement ce programme — exactement le G-code prévisualisé, avec le même post-traitement et la même origine que Generate écrirait. Disponible une fois l'aperçu à jour. Le lien « X0 Y0 at » à côté mène au réglage de l'origine.

## Gravure laser et export de dessins

Chaque programme généré par l'application — isolation du cuivre, contour, perçages, ouvertures du vernis, sérigraphie, couches personnalisées — peut être exporté comme dessin à la taille physique réelle de la carte pour un graveur laser : en chemins vectoriels (SVG, PDF) qu'un laser peut suivre, ou en bitmap (PNG). Usages typiques : révéler une réserve de peinture ou de film sur le cuivre pour une gravure chimique, brûler les ouvertures du vernis une fois durci, et graver la légende de sérigraphie.

**Où.** Avec un programme sélectionné, la section **Laser export** en bas de la barre latérale exporte ce seul programme (**Export <nom>…**). Pour exporter tous les programmes d'un coup, utilisez **Generate → Produce: Laser artwork**, qui écrit un fichier par programme dans le dossier de destination au lieu du G-code. Les options sont les mêmes aux deux endroits et sont mémorisées.

- **Format** — SVG et PDF restent vectoriels : le parcours d'outil sous forme de chemins. PNG est un bitmap à la **Resolution** choisie (300, 600, 1000 ou 2400 dpi) ; le dpi est écrit dans le fichier pour que le logiciel laser le place à sa taille réelle. 1000 dpi résout une piste de 0,15 mm sur environ 6 pixels. Les trois sortent à la taille réelle de la carte.
- **Polarity** — *White on black* : la coupe est blanche sur fond noir. *Black on white* : l'inverse. Le fond est dessiné dans le fichier, la polarité survit donc à l'import dans n'importe quel logiciel laser.
- **Frame** — ce que couvre la page. *Board* : la carte finie — le chemin de découpe rentré d'un demi-diamètre de fraise, si bien qu'une carte de 70 × 30 mm donne une page de 70 × 30 mm à aligner sur le PCB physique. *Origin* : depuis X0/Y0 jusqu'au coin le plus éloigné de tous les programmes ; placer le fichier à 0,0 le met exactement là où la fraiseuse couperait. *Project* : cette même page partagée, recadrée sur les programmes. *Layer* : l'étendue de ce seul programme.
- **Largeur d'outil** — avec **Tool Width** activé dans View Options, le parcours est balayé au diamètre de la fraise, c'est-à-dire le cuivre que la fraiseuse enlèverait ; désactivé, il est exporté en simples lignes centrales. Les déplacements rapides ne sont jamais inclus.

**Ouvertures du vernis pour ablation.** Solder mask → **Output: Laser SVGs** saute les programmes de fraisage du vernis et exporte à la place les formes des ouvertures elles-mêmes (pastilles et vias) en SVG 1:1 via gerbv, prêtes à brûler le vernis durci là où les composants sont soudés.

**Sérigraphie.** Silkscreen → **Output: Engrave** fait de la légende un programme (donc exportable en dessin) ; avec Output désactivé, la couche est ignorée.

Ce que vous faites du dessin relève de votre propre procédé ; l'application ne génère pas de G-code laser et ne règle pas la puissance du laser. Alignez le fichier d'après le Frame choisi : *Board* sur le bord physique de la carte, *Origin* sur le même X0 Y0 où vous faites le zéro de la fraiseuse.

## Couches personnalisées — dessiner vos propres formes

**File → New Custom Layer** (⇧⌘N, aussi dans le menu des couches de la barre latérale) ajoute une couche sur laquelle dessiner : lignes et polygones, rectangles (avec rayon d'angle et rotation), cercles et texte — dans la police de gravure monotrait intégrée ou n'importe quelle police installée, gravée le long de ses contours. Chaque couche non vide devient un programme, écrit par Generate et par l'export CNC comme les autres, et affiché dans l'aperçu qui se régénère après chaque modification.

**Dessin.** Avec la couche sélectionnée, une barre apparaît au-dessus de l'aperçu avec les outils — Select (V), Line (L), Rectangle (R), Circle (C), Text (T). Cliquez ou glissez pour dessiner ; double-clic ou Retour termine une ligne, cliquer son premier point la ferme en polygone ; Maj contraint à 45° et fait des carrés. Les points s'accrochent à la grille (Snap to Grid), aux guides, et aux coins, sommets, centres et quadrants des autres formes (Snap to Objects) ; un anneau vert montre l'accrochage. Le glisser droit ou central déplace la vue (Option-glisser aussi), la molette zoome comme d'habitude. Les autres programmes n'apparaissent derrière le dessin qu'avec All Layers Overlay activé (View Options).

**Édition.** Cliquez pour sélectionner, Maj-clic pour ajouter, tracez un cadre (vers la droite : formes englobées, vers la gauche : formes touchées). Glissez les formes pour les déplacer — elles s'accrochent entre elles — ou glissez les poignées pour redimensionner rectangles et cercles et déplacer les sommets d'une ligne. Les flèches déplacent de 0,1 mm (Maj : 1 mm), ⌘D duplique, Supprimer efface, ⌘Z annule tout. La barre latérale liste les formes ; en sélectionner une ouvre un panneau Properties flottant à droite du dessin avec ses valeurs — position, taille, rayon d'angle, rotation, texte, police, largeur de trait — pour des valeurs exactes ; avec plusieurs sélectionnées, **Align** (bords et centres) et **Distribute** (espaces égaux) les alignent.

**Usinage.** Chaque couche a un outil (de la bibliothèque ou saisi), une profondeur, une profondeur par passe, des avances et une broche, et une opération. *Engrave* fait passer le centre de l'outil sur la ligne dessinée ; *Cut outside* / *Cut inside* décalent les formes fermées d'un demi-outil pour que ce que vous avez dessiné soit la taille obtenue (outside pour une pièce conservée, inside pour un trou). Une largeur de trait supérieure à l'outil est dégagée par passes qui se chevauchent ; *Filled* évide une forme fermée de l'intérieur vers l'extérieur. Les formes sont dessinées en coordonnées de conception sur la carte, elles gardent donc leur place quelle que soit l'origine choisie, et une couche Back est miroitée comme le cuivre arrière. Les couches personnalisées sont enregistrées dans le projet.

## Modifier des couches importées

Tout fichier Gerber ou de perçage importé peut être modifié sur place : sélectionnez un programme qui en est issu et cliquez **Edit** en haut de ses réglages, ou clic droit sur le fichier sous **Layer files** → **Edit…**. Le dessin du fichier (pastilles, pistes, zones remplies ou trous) est tracé par-dessus son programme dans la vue 2D.

- **Sélectionner** : cliquez, ⇧-clic pour ajouter, tracez un cadre (gauche à droite englobe, droite à gauche touche). ⌘A sélectionne tout ; **Select Similar** (la baguette) ajoute chaque piste de même largeur, pastille de même ouverture ou trou de même taille.
- **Changer les tailles de la sélection** dans le panneau Properties : largeur de piste, diamètre de pastille ou largeur × hauteur, diamètre de trou. Seuls les objets sélectionnés changent.
- **Changer une taille partout** : pendant l'édition, la barre latérale liste les ouvertures du fichier (Gerber) ou les outils de perçage (Excellon). Modifier une ligne redimensionne tout ce qui l'utilise, p. ex. toutes les pistes de 0,25 mm d'un coup. L'icône cible les sélectionne.
- **Déplacer** en glissant ou avec les flèches (0,1 mm, ⇧ 1 mm) ; **Supprimer** avec ⌫. Les valeurs sont validées par Retour.

Chaque modification écrit une copie modifiée du fichier ; l'original n'est jamais touché. Pendant l'édition, la barre latérale ne montre que les tailles du fichier et pcb2gcode ne tourne pas — les parcours tracés sous le dessin sont ceux d'avant l'édition. Appuyez sur **Done** (ou Échap sans sélection) et l'aperçu se régénère une fois depuis le fichier modifié. Les modifications sont dans l'historique d'annulation normal (⌘Z), les fichiers modifiés portent un crayon orange, et l'enregistrement du projet empaquette le fichier modifié. Les pastilles de forme spéciale (macros) et les zones remplies peuvent être déplacées ou supprimées mais pas redimensionnées.

## Bibliothèque d'outils

**File → Tool Library…** (⇧⌘L) contient chaque fraise que vous possédez avec ses données de coupe : forme (droite / hémisphérique / en V), usage, diamètre ou pointe + angle, profondeur, profondeur par passe (forets : profondeur de débourrage), avances, broche, recouvrement des passes, et pour les forets la plage de diamètres de trous qu'ils peuvent percer.

- **Import FlatCAM…** lit un export de la base d'outils FlatCAM (Tools Database → Export, le `.TXT` JSON). Tool Target correspond à *Used for* (Isolation, Drilling, Milling/Cutout → Cutout, autres → General) ; la forme V garde pointe et angle ; la tolérance de perçage de FlatCAM devient la plage de trous. Réimporter met à jour les outils de même nom au lieu de les dupliquer.
- Chaque outil est dessiné à ses vraies proportions : une icône de profil dans la liste, et un modèle 3D tournant lentement (glissez pour le tourner) avec ses dimensions clés en haut de l'éditeur — le même modèle que l'aperçu 3D.
- **Import…** / **Export…** transfèrent la bibliothèque entre ordinateurs : Export écrit toute la bibliothèque en `.json` ; Import lit un tel fichier ou une base d'outils FlatCAM. Les outils déjà présents (même outil ou même nom) sont mis à jour, les autres ajoutés — les « bits on hand » d'un projet correspondent donc encore sur l'autre machine.
- Chaque groupe de réglages a un menu **Tool** en haut. Choisir un outil **copie** ses valeurs dans le groupe — comme FlatCAM copie les données de la base dans un objet — vous pouvez donc encore ajuster la couche. **Edited** apparaît quand les champs ne correspondent plus à l'outil ; cliquez dessus pour restaurer les valeurs de l'outil. **Custom** signifie des valeurs saisies à la main.
- Des avances ou une broche à 0 (« non réglé » de FlatCAM) laissent la valeur propre de la couche inchangée.

## Moteurs de parcours d'outil

Machine setup → **Toolpath engine** choisit ce qui transforme les fichiers Gerber et de perçage en programmes :

- **pcb2gcode** — le générateur open source établi. Il est intégré à l'application (Contents/Helpers), rien à installer.
- **Native** — le moteur propre de l'application : il lit les fichiers lui-même et calcule l'isolation, le contour avec languettes, le perçage (avec les forets disponibles), le fraisage de trous, la gravure du vernis et la sérigraphie avec la bibliothèque de polygones Clipper2. Il tourne dans l'application, donc plus vite, et suit les mêmes règles que pcb2gcode — passes réparties uniformément sur la largeur d'isolation, ligne centrale du contour comme bord de carte, languettes sur les bords les plus longs.

Les deux écrivent leurs programmes de la même façon : chaque réglage (temporisations, débourrages, garde de plongée, surcoupe, hauteurs, origines) s'applique à l'un comme à l'autre. Différences possibles : le moteur natif divise les profondeurs exactement (1,8 mm en passes de 0,6 mm = 3 passes ; pcb2gcode en fait 4 de 0,45 mm) et ordonne les chemins par plus proche voisin.

## Générer les programmes

**Generate** (barre d'outils, ou le bouton Generate de la barre latérale) ouvre le dialogue Generate.

- **Produce** — *CNC G-code* génère les parcours avec les paramètres courants et écrit les programmes `.ngc`, exactement les fichiers que montre l'aperçu. *Laser artwork* génère les mêmes programmes puis écrit chacun en dessin 1:1 pour graveur laser au lieu du G-code (les `.ngc` ne sont pas conservés) ; ses options Format, Polarity, Resolution et Frame sont celles décrites sous *Gravure laser et export de dessins*.
- **Destination** — le dossier des fichiers ; **Choose…** ouvre le sélecteur de dossier (son bouton New Folder en crée un nouveau). Le dossier est créé s'il n'existe pas, et les fichiers existants de même nom sont remplacés. La suggestion est `Generated_GCode` à côté du projet ; le choix est mémorisé jusqu'au changement de projet.
- Pendant l'exécution, le dialogue liste les étapes (cuivre avant, cuivre arrière, contour, une par fichier de perçage, vernis, sérigraphie, couches personnalisées) avec leur état ; **Cancel Run** arrête après l'étape en cours. À la fin, **Open Folder** révèle la sortie dans le Finder, et l'onglet Log contient la sortie complète avec les durées par étape.

**Fichiers produits.** `front-copper.ngc`, `back-copper.ngc`, `outline.ngc`, un `<fichier de perçage>.ngc` par fichier de perçage (plus `<fichier de perçage>-milled.ngc` quand Mill large holes est activé), `top-mask-etch.ngc` / `bottom-mask-etch.ngc`, `top-silkscreen.ngc` / `bottom-silkscreen.ngc`, et un programme par couche personnalisée. Les programmes de la face arrière sont miroités et prêts à tourner après le retournement ; tous les programmes partagent l'origine choisie dans Machine setup. La compensation du jeu (Machine setup) est appliquée à ces fichiers lors de l'écriture.

**Le menu More** (… dans la barre d'outils) : **Open Output Folder** révèle la dernière destination ; **Copy pcb2gcode Command** place dans le presse-papiers la ligne de commande exacte exécutée par l'application, pour lancer pcb2gcode vous-même ou pour un rapport de bogue ; **New Custom Layer** et **Generate Test Board…** sont identiques au menu File.

## Paramètres

### Isolation du cuivre
- **Tool diameter** — le diamètre *effectif* à la profondeur de coupe (voir « Outils et fraises en V » ci-dessus), ou choisissez **V-bit** et saisissez pointe + angle.
- **Isolation width** — cuivre total dégagé autour de chaque piste ; le temps d'usinage croît presque linéairement avec. 2–3× le diamètre d'outil est un bon départ.
- **Cut depth** — la feuille de cuivre fait ~0,035 mm ; −0,05…−0,08 mm traverse avec marge. Plus profond élargit les coupes en V et amincit les pistes.
- **Depth per pass** — atteindre la profondeur de coupe en plusieurs passes égales d'au plus cette profondeur. 0 = une passe.
- **Pass overlap** — recouvrement entre passes d'isolation voisines (50 % par défaut).
- Les pistes ne sont jamais entamées : la première passe est décalée vers l'extérieur, l'isolation ne mange que le cuivre environnant à éliminer.

### Perçage et découpe
- **Chaque fichier de perçage a ses propres réglages.** Sélectionnez un programme de perçage (ou son programme `… milled`) et les groupes Drilling, Bits on hand, Hole milling et Heights & direction affichent les valeurs de ce fichier — l'en-tête nomme le fichier. Activer Mill large holes pour le fichier NPTH, ou donner une profondeur moindre au fichier de vias, ne change rien aux autres fichiers de perçage. Un fichier ajouté au projet part des valeurs par défaut de perçage (affichées quand aucun programme de perçage n'est sélectionné) et garde ensuite ses propres valeurs ; elles sont enregistrées dans le projet avec le fichier. Appliquer un preset met tous les fichiers de perçage aux valeurs du preset.
- Profondeurs = épaisseur de carte + ~0,2 mm dans le martyr (stock 1,6 mm → −1,8).
- **Peck depth** — percer par débourrages : après chacun, le foret remonte en rapide pour évacuer les copeaux, revient juste au-dessus du fond précédent et reprend en avance. 0 = une seule descente.
- **Bits on hand** — cochez les forets de la bibliothèque que vous possédez. Chaque trou dans la plage d'un foret coché est percé avec ce foret, le travail ne demande donc que ces forets (un trou de 0,915 mm va au foret de 1,0 mm). Les forets sans plage propre utilisent **Bit tolerance** (± autour du foret). Les trous qu'aucun foret ne couvre gardent leur taille de conception et le Log les nomme — les plages sont toujours transmises, car sans elles pcb2gcode arrondirait *chaque* trou au foret le plus proche (un trou de fixation de 3 mm percé en silence à 1 mm).
- **Hole milling** — pour les trous plus grands que tous vos forets (p. ex. trous de fixation 3–4 mm avec une fraise corn de 2 mm à 2 dents). Activez **Mill large holes** ; les trous à partir de **Mill holes from** ne sont pas percés mais découpés en cercles, en spirale descendante (mouvements hélicoïdaux G2), dans un programme `… milled` séparé exécuté juste après son programme de perçage. La fraise de fraisage de trous a son propre menu Tool (outils de découpe et généraux de la bibliothèque), diamètre, profondeur, profondeur par passe (par tour de spirale), avances, broche et temporisation. Le cercle est décalé vers l'intérieur d'un demi-diamètre, les trous sortent donc à leur taille de conception ; la fraise doit être plus petite que le plus petit trou fraisé.
- La découpe tourne par tours de **Pass depth** ; temps = tours × périmètre ÷ avance.
- **Bridges** : aux passes plus profondes que Bridge Z, la fraise se relève et laisse des languettes de maintien (blanches dans l'aperçu) pour que la carte ne se libère pas au dernier tour. Épaisseur de languette = dessous de carte − Bridge Z. Cassez et limez après usinage.

### Hauteurs de sécurité et garde de plongée
- **Safe Z** — hauteur de déplacement entre les coupes ; doit passer au-dessus des brides et du voilage de la carte.
- **Plunge clearance** — les mouvements verticaux sont rapides dans l'air et en avance seulement sous cette hauteur : les descentes vont en rapide jusqu'à elle puis plongent à l'avance Z ; les remontées vont en avance jusqu'à elle puis en rapide. Cela divise souvent la durée du programme par deux (pcb2gcode seul fait toute la descente en avance — et les remontées de perçage aussi). 0,2–0,5 mm typique ; doit dépasser le voilage de la carte ; 0 désactive. La fraise entre et sort toujours de la matière à l'avance programmée.
- **Milling direction** (Machine setup) — Any laisse pcb2gcode choisir le chemin le plus court ; Climb ou Conventional l'impose à chaque programme de fraisage (cela désactive le raccourcissement de chemin 2-opt, les programmes s'allongent donc un peu).
- **Rapid feed** (Machine setup) — la vitesse G0 de votre machine, utilisée uniquement pour les estimations de durée (FR Rapids de FlatCAM).
- **Heights & direction** (chaque couche ; aussi stocké par outil et importé de FlatCAM) — le **Travel Z** et le **Tool-change Z** propres à la couche (hauteur pour la pause de changement d'outil et la fin du programme ; Tool-change Z / End Z de FlatCAM), laissés vides pour utiliser les valeurs de Machine setup, affichées en gris dans le champ ; **Extra cut** (isolation, vernis, sérigraphie et couches personnalisées) — chaque contour fermé dépasse son départ de cette longueur pour ne laisser aucune bavure là où la boucle se ferme ; là où pcb2gcode enchaîne les passes en une seule coupe, l'outil revient ensuite dans la rainure, seul du cuivre déjà coupé est donc recoupé ; **Milling direction** — valeur machine par défaut ou propre à la couche ; **Spindle** — horaire (M3) ou antihoraire (M4). Le fraisage de trous utilise les hauteurs de perçage (il tourne dans la même passe).
- **Spindle dwell** (chaque couche, à côté de sa vitesse de broche ; aussi stocké par outil dans la bibliothèque et importé de la temporisation FlatCAM) — pause après le démarrage de la broche, pour qu'elle soit en vitesse avant de couper, et après son arrêt, avant un changement d'outil. 0 = pas de pause. pcb2gcode écrit les temporisations en millisecondes (`G04 P2000`), mais GRBL et LinuxCNC lisent des secondes, l'application écrit donc la temporisation de chaque programme en secondes (`G04 P2.000`). Les machines configurées en millisecondes (certaines configurations Mach3) ont besoin de la valeur ×1000.

### Gravure du vernis épargne
Les couches `.GTS`/`.GBS` décrivent les *ouvertures* (pastilles/vias qui restent exposés). Le mode gravure CNC inverse la couche et évide chaque ouverture par passes à 40 % de recouvrement → `top-mask-etch.ngc` / `bottom-mask-etch.ngc`.
- L'outil de vernis ne doit pas être plus grand que la plus petite ouverture (les plus petites sont ignorées — surveillez le Log).
- **Clear width** — jusqu'où chaque ouverture est évidée vers l'intérieur. Par défaut (**Clear width from the mask layers** activé), l'application mesure la plus large ouverture des fichiers de vernis et dégage la moitié plus un peu, chaque ouverture est donc dégagée jusqu'à son centre et pas plus ; le pied de section montre la plus large ouverture. Désactivé, saisissez-la vous-même : elle doit être ≥ la moitié de la plus large ouverture, sinon le milieu des grandes ouvertures reste couvert, et des valeurs plus grandes ralentissent énormément la génération.
- La profondeur de gravure n'a besoin d'enlever que la peinture durcie, pas le cuivre.

### Gravure de la sérigraphie
Les couches de sérigraphie sont désactivées par défaut (les graver coûte du temps de génération et d'usinage). **Output: Engrave** fraise les traits de la légende eux-mêmes — repères, contours et texte — qui finissent donc gravés dans la carte : `top-silkscreen.ngc` / `bottom-silkscreen.ngc`, à exécuter en dernier, après le vernis. La section a son propre outil (droit ou en V), sa profondeur, sa **Clear width** (les traits plus larges que l'outil sont dégagés par passes qui se chevauchent), son recouvrement, ses avances et sa broche. Dans tous les cas la couche peut être exportée vers un laser dès qu'un programme existe.

### Avances, broche et hauteurs par couche
Chaque groupe de réglages se termine par **Feeds & spindle** — avance XY, avance Z (plongée), vitesse de broche et temporisation — et **Heights & direction** (Travel Z, Tool-change Z, Extra cut, Milling direction, sens de broche), décrits sous *Hauteurs de sécurité et garde de plongée*. Choisir un outil dans le menu **Tool** copie les valeurs de la bibliothèque dans le groupe ; **Edited** apparaît quand les champs ne correspondent plus à l'outil.

## Aperçu

### Vue 3D

Le sélecteur **2D / 3D** au-dessus de l'aperçu montre les programmes en 3D : les coupes en lignes de la couleur de chaque couche, les déplacements de la tête en jaune pâle au-dessus de la carte, et une plaque FR4 translucide de 1,6 mm dimensionnée d'après la découpe. Glissez pour orbiter, glisser droit ou central (bouton molette) pour déplacer, molette (ou défilement à deux doigts) ou pincement pour zoomer.

- **Gizmo** (en haut à droite) : les boules X/Y/Z tournent avec la vue ; cliquez-en une pour regarder le long de cet axe — Z = dessus, −Z = dessous, −Y = avant, Y = arrière, X = droite, −X = gauche. Dessous : un menu de toutes les vues standard, **Iso**, **Fit**, perspective/orthographique, et déplacements visibles ou non.
- Avec **All Layers Overlay** activé, chaque programme est posé sur la carte physique : les programmes de la face arrière apparaissent non miroités sur le dessous, vous pouvez donc orbiter pour inspecter l'arrière. Un programme seul est montré tel qu'il est usiné.
- La lecture fonctionne comme en 2D : la partie terminée du programme est surlignée, et la **fraise qui coupe le programme** suit l'outil à taille réelle — le cône de la fraise en V à son angle et sa pointe, le diamètre de la fraise ou de la fraise à trous, un foret avec sa pointe à 118°, tous sur une queue de 1/8″ (3,175 mm) de 38 mm avec l'anneau de profondeur coloré des fraises PCB (V jaune, fraise bleue, foret rouge, hémisphérique violette). Elle tourne dans le sens horaire pendant la lecture.

- Un programme est montré à la fois (menu des couches en haut de la barre latérale). Tous les programmes partagent une origine par face, le « All Layers Overlay » superpose donc exactement cuivre, perçages et vernis ; activez « Un-mirror Back Side » pour superposer la face arrière miroitée alignée sur l'avant.
- **Couleurs** : couleurs par couche pour les coupes ; **jaune pointillé = déplacement de la tête** (sans coupe) ; **blanc = ponts de maintien** ; la bande translucide sous les coupes est la largeur réelle de la fraise (« Tool Width » dans le menu View Options).
- **Un-mirror Back Side** (menu View Options) dé-miroite les programmes de la face arrière pour des vérifications visuelles d'alignement — affichage seulement ; le G-code reste miroité et prêt pour la CNC. Désactivé, l'arrière est correctement miroité par rapport à l'avant.

### View Options
Le menu **View Options** au-dessus de l'aperçu active ce que les vues dessinent : **Tool Width** (la bande translucide au diamètre réel de la fraise ; décide aussi si un export laser est balayé ou en lignes centrales), **Rulers**, **Guides** et **Clear Guides**, **Snap to Grid** (⌘'), **All Layers Overlay**, **Un-mirror Back Side**, **Height Map** avec son **exagération** (×1 … ×50), **Toolpath Lines**, **Drill Holes** (les trous en cylindres en 3D), **Material Removal** (les rainures et le masque de cuivre en 3D), **Machine Travel** (la zone de course de la machine connectée, en pointillés) et **Fit Machine Travel**.

**Guides.** Avec Rulers et Guides activés, glissez depuis une règle vers la vue pour tirer une ligne guide ; glissez un guide pour le déplacer. Les guides accrochent le dessin, la mesure et le marqueur d'origine, et sont enregistrés avec le projet. Clear Guides les supprime tous.

**Boutons du canevas** (en haut à gauche de la vue 2D) : zoom avant, zoom arrière, ajuster (le double-clic fait de même), définir l'origine en cliquant, le mètre ruban, et centrer sur l'origine.

## Lecture et estimations

Simulation fidèle aux avances via la barre de lecture flottante : chaque mouvement dure `longueur ÷ avance programmée`. **1× réel = 100 % de la vitesse d'usinage** ; le marqueur d'outil glisse le long de chaque mouvement, rapides compris. L'onglet G-code surligne la ligne source courante. Les durées par programme sont dans le menu des couches de la barre latérale ; **Σ est.** en dessous est le total. Les rapides sont supposés à 2000 mm/min (le G-code ne porte pas d'avance rapide).

## Vue latérale

Projections X–Z / Y–Z ou **Profile** Z en fonction de la distance, avec des lignes de référence étiquetées (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z est exagéré (la note ×N indique de combien) ; les déplacements au-dessus de zsafe sont compressés dans une fine bande supérieure pour que les remontées restent visibles.

## Commandes de la vue

Molette / pincement = zoom (ancré au curseur) · glisser = déplacement · double-clic / bouton Fit = réinitialisation. Zoom et déplacement survivent aux changements de couche ; les positions des séparateurs de panneaux et tous les paramètres persistent entre les lancements.

## Mesure et annulation

**Mesure.** le bouton règle en haut à droite de la vue 2D (ou M quand la vue a le focus) active le mètre ruban, sur n'importe quelle couche. Cliquez deux points — ou glissez entre eux — pour lire la distance, ΔX, ΔY et l'angle. Il s'accroche aux coins des parcours, aux trous, aux formes dessinées, à l'origine, aux guides et (avec Snap to Grid) à la grille ; Maj garde la ligne horizontale, verticale ou à 45°. Échap efface la mesure, puis quitte l'outil.

**Annulation.** Edit → Undo / Redo (⌘Z / ⇧⌘Z) parcourent un seul historique pour toute l'application — modifications de paramètres, outils et presets appliqués, déplacement de l'origine, fichiers de couches importés, remplacés ou retirés, et chaque modification de dessin. Ouvrir un autre projet démarre un nouvel historique.

## Onglets G-code, Log et Console

Les onglets au-dessus de l'aperçu changent la zone principale :

- **Toolpath** — l'aperçu 2D/3D décrit plus haut.
- **G-code** — le texte du programme sélectionné (le menu **File** en haut choisit n'importe quel programme généré). Pendant la lecture et pendant l'envoi d'un programme, la ligne courante est surlignée et maintenue visible. Les fichiers de plus de 8 Mo montrent leurs 8 premiers Mo.
- **Log** — tout ce que pcb2gcode et le moteur natif ont imprimé, étape par étape avec les durées ; les avertissements commencent par `WARNING:`, les échecs par `ERROR:` et l'erreur est en bas. La version de pcb2gcode et les fichiers détectés sont consignés à l'ouverture d'un projet. Quand un aperçu échoue, le panneau d'aperçu propose **Show Log** et **Try Again**.
- **Console** — la console machine : chaque ligne envoyée au contrôleur et reçue de lui. **Show status reports** inclut les interrogations `?` et les rapports `<…>` (plusieurs par seconde — utile pour diagnostiquer, bruyant sinon) ; **Clear** vide la vue. Le champ de commande envoie une ligne telle quelle avec Retour (`$G`, `G0 X10`, `$/axes/x/max_travel_mm`…) ; un caractère seul comme `!`, `~` ou `?` est envoyé en octet temps réel ; ↑ et ↓ rappellent les commandes précédentes. Le champ est verrouillé pendant qu'un programme tourne.

## Presets et réglages

**Presets** (barre d'outils) enregistrent et rappellent des jeux complets de paramètres — outils, avances, profondeurs, hauteurs, origine — utiles par matériau ou par machine. **Save Current as Preset…** nomme les valeurs courantes ; choisir un preset l'applique (et met chaque fichier de perçage aux réglages de perçage du preset) ; **Delete Preset** en supprime un. Appliquer un preset est annulable.

**Settings (⌘,)** a deux volets :

### General
- **Language** — Système (suit macOS) ou anglais, français, espagnol, turc, pour l'interface et le guide intégré. Prend effet au prochain lancement. La fenêtre du guide a aussi son propre menu de langue.
- **Units** — Metric (millimètres) ou Imperial (pouces). Change les nombres que vous lisez et saisissez : champs de paramètres, règles, guides et affichage de lecture. Les programmes générés restent toujours métriques (`G21`).
- **Preview refresh** — *Automatic* régénère l'aperçu après les modifications de paramètres, une fois que vous arrêtez de taper pendant le **Delay after last edit** ; *Manual* seulement sur le bouton Refresh. Le badge « Out of date » signale un aperçu périmé dans les deux cas.

### Machine
- **Connection** — Transport (telnet Wi‑Fi pour FluidNC, série USB pour tout contrôleur de type Grbl, ou le Simulator intégré), Host et Port, port série et Baud (115200), intervalle d'interrogation d'état (200 ms = 5 rapports par seconde), reconnexion automatique si la liaison tombe, afficher les rapports d'état dans la console, afficher le Simulator dans le sélecteur de connexion.
- **Jog** — l'avance et le pas avec lesquels le panneau démarre, et la longueur de segment pour le jog continu sur les firmwares qui ne peuvent pas annuler un long jog.
- **Z probe** — avances rapide et lente, course maximale, retrait, épaisseur de plaque (les mêmes valeurs que sur l'onglet Probe).
- **Motion** — Z de travail sûr pour Go to Work Zero, Z sûr sous le haut de la course (aussi la hauteur de stationnement pour les changements d'outil), broche minimale et maximale pour le bouton Spindle du panneau, préchauffage de broche avant reprise.
- **Programs** — appliquer la compensation du jeu à l'envoi, confirmer avant de continuer après un changement d'outil, enregistrer le zéro pièce à l'envoi d'un programme (une entrée Work dans l'onglet Positions, nommée d'après le programme et l'heure ; les 20 entrées automatiques les plus récentes sont conservées), la fenêtre d'envoi (combien d'octets non acquittés restent en vol ; 0 = automatique : 128 en série USB, 512 en Wi‑Fi, ou le tampon de réception annoncé par le contrôleur — augmentez-la quand les arcs et les coins arrondis vont moins vite que l'avance en Wi‑Fi, gardez 128 pour une carte Grbl en USB), le Z sous lequel la carte de hauteur s'applique.
- **Axis calibration (steps/mm)** — voir *Étalonnage des axes* sous Panneau Machine.

## Zéro machine et travail double face

**Machine setup → Origin → « X0 Y0 at »** décide où se trouve l'origine machine sur la carte ; chaque programme la partage, une origine par face. La vue la marque d'un réticule cerclé et de flèches X rouge / Y verte (toujours cadrées par Fit).

- **Corners / Centre** — de tout le projet (l'étendue de tous les programmes) tel que la machine voit chaque face : après retournement vous faites le zéro au même coin du montage.
- **Custom point** — un point en coordonnées de conception (Gerber/EasyEDA), les tailles d'outil ne le déplacent donc jamais. C'est le même point physique sur les deux faces, p. ex. un trou de repérage. Saisissez Origin X / Y, ou définissez-le dans la vue (ci-dessous).
- **Le déplacer dans la vue** — glissez le marqueur d'origine là où X0 Y0 doit être, ou cliquez **Set Origin in View** (Machine setup) / le bouton viseur et cliquez l'endroit. Les deux s'accrochent aux coins et au centre du projet (ce qui sélectionne ce mode de coin) et aux trous (un point personnalisé). Avec **Snap to Grid** activé (View Options, ou View → Snap to Grid, ⌘'), tout autre dépôt tombe sur la grille affichée, l'origine se déplace donc par pas de grille entiers ; zoomez pour une grille plus fine.
- **Design origin** — pas de zéro ; coordonnées exactement telles qu'exportées.

Faites le zéro X/Y à l'origine pour les programmes de la face avant (cuivre, perçages, contour, vernis supérieur), puis une fois encore après retournement pour les programmes de la face arrière — tout reste aligné. Faites le zéro Z sur la surface de la carte. Choisissez la direction de retournement avec **Mirror around Y axis** et vérifiez avec Flip Back View. Le palpage et les cartes de hauteur se font en direct depuis le panneau Machine (ci-dessous) ; les programmes eux-mêmes restent du G-code simple.

## Compensation du jeu

GRBL et FluidNC n'ont pas de réglage de jeu, l'application peut donc compenser elle-même le jeu des axes X et Y. **Machine setup → Backlash compensation** contient le jeu par axe (mesurez-le avec la carte de test de jeu). Les valeurs appartiennent à la machine, pas au projet : elles sont globales à l'application et ne sont pas enregistrées dans les fichiers `.cncproj`.

- Avec une valeur définie, chaque programme écrit par l'application — Generate, l'export CNC, les cartes de test — est réécrit : les coordonnées atteintes en se déplaçant dans le sens négatif sont décalées du jeu, un court mouvement de rattrapage de cet axe seul est inséré à chaque inversion, les arcs sont scindés à leurs extrêmes X/Y, et le premier rapide reçoit une approche par le bas. L'aperçu et l'onglet G-code montrent toujours le programme non compensé.
- **Compensate a G-code File…** écrit une copie compensée d'un programme créé hors de cette application.
- À l'envoi depuis le panneau Machine, l'interrupteur **Backlash compensation** de l'onglet Program (valeur par défaut depuis Settings → Machine → *Apply backlash compensation when sending*) réécrit la copie diffusée ; les fichiers sur disque ne sont pas touchés.
- Les programmes avec G91 (mouvements relatifs), G20 (pouces), arcs au format R, G28/G53/G92 ou cycles fixes sont laissés non compensés, avec un WARNING dans le Log.
- Remettez les valeurs à 0 une fois la machine réparée — corriger le jeu mécaniquement est toujours préférable.

## Panneau Machine

Le bouton **Machine** de la barre d'outils (View → Machine Panel, ⇧⌘M) ouvre un panneau à droite de la fenêtre principale : un émetteur natif pour les contrôleurs GRBL 1.1 et FluidNC. La bande de connexion et l'affichage de position restent en haut ; les onglets dessous (Control, Positions, Program, Probe, Height Map, Macros) défilent séparément ; un **E-STOP** rouge sous l'affichage reste visible sur chaque onglet ; la console est l'onglet Console de la fenêtre principale, et « Open in a window » en haut du panneau donne aux mêmes commandes une fenêtre à part avec le texte du programme.

### Connexion
Choisissez **Wi‑Fi** (l'IP du contrôleur et le port telnet, 23 par défaut) ou **USB** (un port `/dev/cu.*` à 115200) et appuyez sur Connect. La pastille d'état montre Idle / Run / Jog / Hold / Alarm…, le badge le firmware identifié par l'application (`$I`), et les alarmes apparaissent décodées avec Unlock / Home / Reset. Les alarmes qui perdent la position (fins de course, reset en mouvement) marquent la position comme non fiable : faites Home, ou appuyez sur Unlock pour garder la position telle quelle. La connexion coexiste avec d'autres clients (un pendentif sur le même contrôleur continue de fonctionner).

### DRO, zéro, positions
Coordonnées pièce et machine, avance et broche en direct, tampon du planificateur et entrées déclenchées (P = entrée de palpeur fermée). Cliquez une valeur d'axe pour définir ou mettre à zéro cet axe ; la grille de boutons dessous a **Zero XY / Zero Z / Zero All** (`G10 L20 P0`, persistant) et **Probe Z** (le palpage en deux passes de l'onglet Probe) en première ligne, **Work Zero** (remonte d'abord au Z de travail sûr), **Safe Z** (juste sous le haut de la course Z), **Home** et **Unlock** en seconde. L'onglet **Positions** garde des positions machine nommées ; **Go to coordinates…** se déplace vers une cible machine saisie (Z d'abord en montant, en dernier en descendant). **Save work zero** mémorise où se trouve le X0 Y0 Z0 pièce en coordonnées machine, et **Use as zero** sur une entrée rétablit l'origine pièce à ce point (`G10 L2 P0`, sans mouvement) — pour restaurer un zéro après un reset ou un nouveau homing. Les **User buttons** de l'onglet Control exécutent les macros de l'onglet Macros (un bouton par macro, icône SF Symbol facultative ; « allow while running » garde un bouton actif pendant un travail, pour des commandes courtes comme l'arrosage). **E-STOP** (aussi en fin de barre de travail, et ⇧⌘.) envoie d'un coup annulation de jog, feed hold et soft reset sans rien attendre ; la position est marquée non fiable si la machine bougeait. ⌘. reste l'arrêt contrôlé.

### Jog et overrides
Tapez un bouton de jog pour un pas ; maintenez pour un mouvement continu qui s'arrête au relâchement (sur un FluidNC référencé avec limites logicielles, le jog court jusqu'à la limite et est annulé au relâchement ; sinon de courts segments sont diffusés). Les boutons diagonaux déplacent deux axes. **Jog clavier** : flèches = X/Y, Page haut/bas = Z, Maj = pas ×10, Échap ou ⌘. = stop. Les overrides ajustent l'avance (10–200 %, par pas de 1 et 10), les rapides (25/50/100 %) et la vitesse de broche en temps réel ; le contrôleur rapporte la valeur qu'il utilise.

**Commandes machine** (onglet Control) : **Reset** (soft reset Ctrl‑X — arrête tout ; la position est perdue si la machine bougeait), **Hold** / **Resume** (feed hold, cycle start), **Check** (`$C` — le G-code est analysé mais rien ne bouge), **Spindle** marche/arrêt à la vitesse indiquée à côté (bornée au minimum et maximum de Settings → Machine), **Coolant** (M8/M9), et sous More : **Sleep**, **Safety Door**, et les requêtes `$G` (état de l'analyseur), `$#` (décalages) et `$I` (infos de build), dont les réponses apparaissent dans la Console.

### Onglet Positions
Positions machine nommées, en deux listes choisies par le sélecteur **Machine / Work**. **Machine** contient les points où la broche retourne : **Save current…** mémorise les coordonnées machine où se trouve la broche, **Go to…** se déplace vers une coordonnée machine saisie, et chaque entrée a **Go** (Z d'abord en montant, en dernier en descendant, à l'avance de jog). **Work** contient les zéros pièce — où était le X0 Y0 Z0 pièce, en coordonnées machine : **Save work zero** mémorise le zéro actuel à la main, et avec *Save the work zero when a program is sent* (Réglages → Machine, activé par défaut) chaque envoi en enregistre un automatiquement, nommé d'après le programme et l'heure (« Front copper – 8 Oct 14:07 », icône horloge). **Use as zero** sur une entrée Work refait de ce point l'origine pièce avec `G10 L2` — la machine ne bouge pas — ainsi, après un crash, un reset ou un homing, le même zéro est de retour sans refaire le palpage. Clic droit sur une entrée pour **Rename…**, **Overwrite with Current Position** / **Current Work Zero**, **Go There…** / **Use as Work Zero…** de l'autre liste, et **Delete**. Les macros peuvent aller à une position enregistrée avec `@goto <nom>`.

### Onglet Program — envoi
Choisissez une couche générée (ou CNC export → **Send … to Machine…** dans la barre latérale), ou **Open .ngc file…** pour un programme externe (une carte de test, par exemple). **Backlash** et **Apply height map** transforment la copie envoyée, jamais les fichiers sur disque ; **Save sent program…** conserve cette copie. **Verify** diffuse le programme en mode check sans mouvement. Si la course de la machine ne peut contenir le programme, la barre de travail le dit en toutes lettres — par exemple que la ligne 12 monte à un Z au-dessus du haut de la course parce que le Z0 pièce est près du haut ; quand c'est le seul problème, **Clamp Z to top** reprépare le programme avec ces hauteurs de retrait abaissées juste sous le haut (les profondeurs de coupe sont intactes ; un badge orange « Z clamped » s'affiche tant que c'est actif) pour permettre un essai à vide. **Send** diffuse avec comptage de caractères ; les canevas de la fenêtre principale, la vue latérale, la vue 3D et l'onglet G-code suivent le travail, un réticule bleu marque la position réelle de la machine, et la barre de travail affiche la ligne, le temps écoulé et restant. Hold/Resume et les overrides restent actifs. **Stop** met en pause, réinitialise une fois la machine immobile, et coupe la broche.

Les changements d'outil (diamètres de forets supplémentaires) suspendent le travail avant le changement : broche coupée, Z stationné en haut, et une bannière nomme la fraise. Jog, Zero et **Probe Z** sont actifs pendant la suspension pour palper la nouvelle fraise, puis **Continue** reprend aussitôt — la bannière liste les lignes de préambule qu'il enverra (Settings → Machine → *Confirm before continuing after a tool change* ramène la feuille de confirmation). **Send from line…** reprend en cours de programme avec un préambule sûr (retrait, broche, rapide au-dessus du point, plongée), toujours affiché pour confirmation. L'application demande confirmation avant de changer de projet, de se déconnecter ou de quitter pendant un travail.

### Onglet Probe
Un palpage Z en deux passes : descente rapide pour trouver le contact, retrait de 1 mm, descente lente pour le point exact ; l'origine pièce active est alors fixée au point de contact (`G10 L20` ; la passe lente s'arrête à un micron du déclenchement) et relue depuis le contrôleur — le DRO affiche alors la hauteur de retrait, avec Z0 sur la surface. Épaisseur de plaque 0 = pince sur le cuivre et fraise comme palpeur ; saisissez l'épaisseur pour une plaque de contact. Settings → Machine contient les avances, la course maximale et le retrait.

### Étalonnage des axes (pas/mm)

Si un jog de 10 mm déplace la broche de 9,85 mm, les pas/mm du contrôleur sont faux. Settings → Machine → **Axis calibration** (FluidNC, connecté) lit `axes/x|y/steps_per_mm` et le nom du fichier de configuration depuis le contrôleur. Mesurez avec un comparateur ou une règle : joggez d'abord un peu dans le sens de mesure (rattrape le jeu), mettez le comparateur à zéro, joggez une distance connue — la plus longue possible — et saisissez commandé et mesuré ; nouveaux pas/mm = actuel × commandé ÷ mesuré. **Apply** écrit la configuration en cours aussitôt (`$/axes/x/steps_per_mm=…`) et, avec l'interrupteur d'enregistrement activé, `$CD=<fichier de config>` réécrit ce fichier (p. ex. `raptorex.yaml`) depuis la configuration en cours pour que la valeur survive au redémarrage. Remesurez ensuite ; des mesures qui diffèrent de plus de quelques centièmes indiquent du jeu ou une poulie desserrée, pas les pas/mm.

### Onglet Macros
Vos propres séquences de commandes. **Add** crée une macro avec un nom, une icône SF Symbol facultative (`fan.fill`, `drop.fill`, `house`…) et les lignes G-code qu'elle envoie ; **Run** envoie les lignes l'une après l'autre en attendant chaque acquittement (la machine doit être connectée et au repos) ; **Edit**, et par clic droit **Duplicate** et **Delete** ; **Restore Defaults** remplace la liste par les exemples intégrés. Chaque macro est aussi un **user button** sur l'onglet Control ; *allow while running* garde un bouton actif pendant un travail, pour des commandes courtes comme l'arrosage. `@goto <position>` dans une ligne va à une position enregistrée de l'onglet Positions.

### Onglet Height Map
Définissez une grille sur la carte (**Auto** l'ajuste au programme sélectionné), **Probe** la palpe et lit l'écart. Les cartes sont par face et stockées relativement au Z palpé à l'origine pièce, repalper Z là après un changement d'outil les garde donc valides. Avec **Apply height map** activé, chaque coupe et plongée basse de la copie diffusée est déformée selon la surface mesurée (interpolation bilinéaire) ; les rapides à hauteur de sécurité sont intacts. Si l'origine pièce a bougé depuis le palpage, l'application avertit avant d'appliquer. Les cartes sont conservées par projet dans Application Support et peuvent être enregistrées/chargées en JSON ; View Options → Height Map montre les points sur le parcours.

### Essayer sans machine
Activez **Show the Simulator in the connection picker** dans Settings → Machine, choisissez **Simulator** dans la barre de connexion et appuyez sur Connect : l'application démarre un simulateur FluidNC intégré (`fake-grbl.py`, inclus ; nécessite python3 des outils en ligne de commande de Xcode) sur un port privé et lui parle comme à un vrai contrôleur — mouvement en temps réel, alarmes, suspensions de changement d'outil, palpage Z contre une surface synthétique 1 mm sous le zéro pièce, cartes de hauteur. Son zéro pièce est préréglé pour que les programmes d'exemple tiennent dans la course. La pastille d'état porte un tag **SIM** et le badge indique Simulator ; Disconnect ou quitter l'arrête. (Dév : `-debugMachineWindow 1 -debugMachineConnect sim`.)

## Dépannage

- **pcb2gcode manquant** → seulement dans les builds faits sans lui ; le moteur natif prend le relais (Machine setup → Toolpath engine). Les builds normaux embarquent pcb2gcode dans l'application — rien à installer.
- **Échec de l'aperçu** → l'onglet Log contient la sortie complète avec les durées par étape ; l'erreur est en bas.
- **Espaces non coupés entre pistes proches** → outil trop large pour passer ; pcb2gcode avertit dans le Log. Réduisez le diamètre effectif de l'outil ou augmentez l'écartement du dessin.
- **Ouverture de vernis non dégagée** → ouverture plus petite que l'outil de vernis, ou Clear width saisie < moitié de l'ouverture (réactivez « Clear width from the mask layers »).
- **Génération lente** → Clear width de vernis trop grande, ou largeur d'isolation très grande.

## Raccourcis clavier

| Action | Touches |
|---|---|
| New Project / Open Project… / Open Gerber Folder… | ⌘N / ⌘O / ⇧⌘O |
| Save Project / Save Project As… | ⌘S / ⇧⌘S |
| Import Layer… / New Custom Layer | ⌘I / ⇧⌘N |
| Generate Test Board… / Tool Library… | ⇧⌘T / ⇧⌘L |
| Annuler / Rétablir | ⌘Z / ⇧⌘Z |
| Sélectionner toutes les formes / Dupliquer les formes | ⇧⌘A / ⌘D |
| Snap to Grid | ⌘' |
| Panneau Machine / Arrêt d'urgence | ⇧⌘M / ⇧⌘. |
| Réglages / Aide | ⌘, / ⌘? |
| Outils de dessin (couche personnalisée, vue active) | V sélection · L ligne · R rectangle · C cercle · T texte |
| Mètre ruban / quitter l'outil | M / Échap |
| Déplacer les formes sélectionnées | Flèches 0,1 mm · ⇧Flèches 1 mm |
| Jog machine (Keyboard jog activé) | Flèches X/Y · Page haut/bas Z · ⇧ pas ×10 · Échap ou ⌘. stop |
| Historique de la console | ↑ / ↓ |
