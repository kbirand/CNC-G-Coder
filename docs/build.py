"""Build the user guide page (Apple-support layout) in four languages from
HELP.md / HELP.fr.md / HELP.es.md / HELP.tr.md, and regenerate the in-app
HelpView.swift (English) from HELP.md.

    cd docs && python3 build.py

Every translation must keep the English chapter/section structure: ids,
screenshots and the contents list are shared by position."""
import json, html, sys, re, os, importlib.util

DOCS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DOCS)
IMG_DIR = os.path.join(DOCS, "images")

spec = importlib.util.spec_from_file_location("conv", os.path.join(DOCS, "convert.py"))
conv = importlib.util.module_from_spec(spec); spec.loader.exec_module(conv)

LANGS = ["en", "fr", "es", "tr"]
LANG_NAMES = {"en": "English", "fr": "Français", "es": "Español", "tr": "Türkçe"}
SOURCES = {"en": "HELP.md", "fr": "HELP.fr.md", "es": "HELP.es.md", "tr": "HELP.tr.md"}

GUIDES = {}
for lang in LANGS:
    conv.SRC = os.path.join(ROOT, SOURCES[lang])
    GUIDES[lang] = conv.parse()

EN = GUIDES["en"]
ORDER_ALL = [c["id"] for c in EN["chapters"]]
# Translations take the English ids by position.
for lang in LANGS[1:]:
    g = GUIDES[lang]
    assert len(g["chapters"]) == len(EN["chapters"]), lang
    for c, ec in zip(g["chapters"], EN["chapters"]):
        assert len(c["sections"]) == len(ec["sections"]), (lang, ec["title"])
        c["id"] = ec["id"]
        for s, es in zip(c["sections"], ec["sections"]):
            s["id"] = es["id"]
CH = {lang: {c["id"]: c for c in GUIDES[lang]["chapters"]} for lang in LANGS}

# ---------------------------------------------------------------- per-language texts
GROUPS = [
    ("getting-started", ["workflow-overview", "project-folder-detection", "tools-v-bits-read-this-first", "test-boards"]),
    ("projects", ["projects", "custom-layers-drawing-your-own-shapes", "editing-imported-layers", "tool-library"]),
    ("output", ["toolpath-engines", "generating-programs", "exporting-one-program", "laser-engraving-artwork-export"]),
    ("parameters", ["parameters"]),
    ("preview", ["preview", "playback-estimates", "side-view", "view-controls", "measuring-undo", "g-code-log-and-console-tabs", "presets-settings"]),
    ("machine", ["machine-zeroing-double-sided-work", "backlash-compensation", "machine-panel"]),
    ("help", ["troubleshooting", "keyboard-shortcuts"]),
]
ORDER = [cid for _, ids in GROUPS for cid in ids]
assert set(ORDER) == set(ORDER_ALL), set(ORDER_ALL) ^ set(ORDER)

GROUP_NAMES = {
    "en": {"getting-started": "Getting started", "projects": "Projects & layers", "output": "Output", "parameters": "Parameters", "preview": "Preview", "machine": "Machine", "help": "Help"},
    "fr": {"getting-started": "Premiers pas", "projects": "Projets et couches", "output": "Sortie", "parameters": "Paramètres", "preview": "Aperçu", "machine": "Machine", "help": "Aide"},
    "es": {"getting-started": "Primeros pasos", "projects": "Proyectos y capas", "output": "Salida", "parameters": "Parámetros", "preview": "Vista previa", "machine": "Máquina", "help": "Ayuda"},
    "tr": {"getting-started": "Başlangıç", "projects": "Projeler ve katmanlar", "output": "Çıktı", "parameters": "Parametreler", "preview": "Önizleme", "machine": "Makine", "help": "Yardım"},
}

SHORT = {
    "en": {"workflow-overview": "Workflow overview", "project-folder-detection": "Project folder & detection", "tools-v-bits-read-this-first": "Tools & V-bits", "test-boards": "Test boards",
           "projects": "Projects", "custom-layers-drawing-your-own-shapes": "Custom layers", "editing-imported-layers": "Editing imported layers", "tool-library": "Tool library",
           "toolpath-engines": "Toolpath engines", "generating-programs": "Generating programs", "exporting-one-program": "Exporting one program", "laser-engraving-artwork-export": "Laser engraving & artwork",
           "parameters": "Parameters", "preview": "Preview", "playback-estimates": "Playback & estimates", "side-view": "Side view", "view-controls": "View controls", "measuring-undo": "Measuring & undo",
           "g-code-log-and-console-tabs": "G-code, Log & Console", "presets-settings": "Presets & settings", "machine-zeroing-double-sided-work": "Zeroing & double-sided work",
           "backlash-compensation": "Backlash compensation", "machine-panel": "Machine panel", "troubleshooting": "Troubleshooting", "keyboard-shortcuts": "Keyboard shortcuts"},
    "fr": {"workflow-overview": "Vue d'ensemble", "project-folder-detection": "Dossier et détection", "tools-v-bits-read-this-first": "Outils et fraises en V", "test-boards": "Cartes de test",
           "projects": "Projets", "custom-layers-drawing-your-own-shapes": "Couches personnalisées", "editing-imported-layers": "Modifier les couches importées", "tool-library": "Bibliothèque d'outils",
           "toolpath-engines": "Moteurs de parcours", "generating-programs": "Générer les programmes", "exporting-one-program": "Exporter un programme", "laser-engraving-artwork-export": "Gravure laser et dessins",
           "parameters": "Paramètres", "preview": "Aperçu", "playback-estimates": "Lecture et estimations", "side-view": "Vue latérale", "view-controls": "Commandes de la vue", "measuring-undo": "Mesure et annulation",
           "g-code-log-and-console-tabs": "G-code, Log et Console", "presets-settings": "Presets et réglages", "machine-zeroing-double-sided-work": "Zéro et double face",
           "backlash-compensation": "Compensation du jeu", "machine-panel": "Panneau Machine", "troubleshooting": "Dépannage", "keyboard-shortcuts": "Raccourcis clavier"},
    "es": {"workflow-overview": "Visión general", "project-folder-detection": "Carpeta y detección", "tools-v-bits-read-this-first": "Herramientas y fresas en V", "test-boards": "Placas de prueba",
           "projects": "Proyectos", "custom-layers-drawing-your-own-shapes": "Capas personalizadas", "editing-imported-layers": "Editar capas importadas", "tool-library": "Biblioteca de herramientas",
           "toolpath-engines": "Motores de trayectoria", "generating-programs": "Generar programas", "exporting-one-program": "Exportar un programa", "laser-engraving-artwork-export": "Grabado láser y arte",
           "parameters": "Parámetros", "preview": "Vista previa", "playback-estimates": "Reproducción y estimaciones", "side-view": "Vista lateral", "view-controls": "Controles de la vista", "measuring-undo": "Medición y deshacer",
           "g-code-log-and-console-tabs": "G-code, Log y Console", "presets-settings": "Presets y ajustes", "machine-zeroing-double-sided-work": "Cero y doble cara",
           "backlash-compensation": "Compensación de holgura", "machine-panel": "Panel de máquina", "troubleshooting": "Solución de problemas", "keyboard-shortcuts": "Atajos de teclado"},
    "tr": {"workflow-overview": "İş akışı", "project-folder-detection": "Proje klasörü ve algılama", "tools-v-bits-read-this-first": "Takımlar ve V uçlar", "test-boards": "Test kartları",
           "projects": "Projeler", "custom-layers-drawing-your-own-shapes": "Özel katmanlar", "editing-imported-layers": "İçe aktarılmış katmanları düzenleme", "tool-library": "Takım kitaplığı",
           "toolpath-engines": "Takım yolu motorları", "generating-programs": "Program üretme", "exporting-one-program": "Tek programı dışa aktarma", "laser-engraving-artwork-export": "Lazer kazıma ve çizim",
           "parameters": "Parametreler", "preview": "Önizleme", "playback-estimates": "Oynatma ve tahminler", "side-view": "Yan görünüm", "view-controls": "Görünüm denetimleri", "measuring-undo": "Ölçme ve geri alma",
           "g-code-log-and-console-tabs": "G-code, Log ve Console", "presets-settings": "Preset'ler ve ayarlar", "machine-zeroing-double-sided-work": "Sıfırlama ve çift taraf",
           "backlash-compensation": "Boşluk telafisi", "machine-panel": "Makine paneli", "troubleshooting": "Sorun giderme", "keyboard-shortcuts": "Klavye kısayolları"},
}

SUMMARY = {
    "en": {"workflow-overview": "The seven steps from a Gerber export to a finished board.", "project-folder-detection": "How EasyEDA and KiCad exports are recognised, and what Generate writes where.",
           "tools-v-bits-read-this-first": "Why every diameter must be the effective cutting diameter at depth.", "test-boards": "Three small boards that measure your setup: parameters, backlash, hole fit.",
           "projects": "The .cncproj package, opening, saving and importing layers.", "custom-layers-drawing-your-own-shapes": "Draw lines, shapes and text and machine them like any other layer.",
           "editing-imported-layers": "Resize tracks, pads and holes in place without touching the originals.", "tool-library": "Every bit you own, with its cutting data, shared by all projects.",
           "toolpath-engines": "pcb2gcode or the native engine: what differs and what does not.", "generating-programs": "The Generate dialog, the destination folder and the files it writes.",
           "exporting-one-program": "Save a single program exactly as previewed.", "laser-engraving-artwork-export": "Export any program as 1:1 SVG, PDF or PNG artwork for a laser engraver.",
           "parameters": "Isolation, drilling, cutout, safety heights, solder-mask and silkscreen settings.", "preview": "The 2D and 3D views, the View Options and what their colours mean.",
           "playback-estimates": "Feed-rate-accurate simulation and the time estimates.", "side-view": "Depth checks in the X–Z, Y–Z and profile projections.", "view-controls": "Zoom, pan and fit.",
           "measuring-undo": "The tape measure and the app-wide undo history.", "g-code-log-and-console-tabs": "The program text, the generation log and the machine console.",
           "presets-settings": "Saved parameter sets and both Settings panes.", "machine-zeroing-double-sided-work": "Where X0 Y0 is on the board and how both sides stay registered.",
           "backlash-compensation": "Compensate axis play in every program the app writes.", "machine-panel": "The built-in GRBL / FluidNC sender: connect, jog, probe, send.",
           "troubleshooting": "What to do when a preview fails or a cut looks wrong.", "keyboard-shortcuts": "Every shortcut in one table."},
    "fr": {"workflow-overview": "Les sept étapes d'un export Gerber à une carte finie.", "project-folder-detection": "Comment les exports EasyEDA et KiCad sont reconnus, et ce que Generate écrit où.",
           "tools-v-bits-read-this-first": "Pourquoi chaque diamètre doit être le diamètre de coupe effectif en profondeur.", "test-boards": "Trois petites cartes qui mesurent votre installation : paramètres, jeu, ajustement des trous.",
           "projects": "Le paquet .cncproj, ouvrir, enregistrer et importer des couches.", "custom-layers-drawing-your-own-shapes": "Dessinez lignes, formes et texte et usinez-les comme toute autre couche.",
           "editing-imported-layers": "Redimensionnez pistes, pastilles et trous sur place sans toucher aux originaux.", "tool-library": "Chaque fraise que vous possédez, avec ses données de coupe, partagée par tous les projets.",
           "toolpath-engines": "pcb2gcode ou le moteur natif : ce qui diffère et ce qui ne diffère pas.", "generating-programs": "Le dialogue Generate, le dossier de destination et les fichiers écrits.",
           "exporting-one-program": "Enregistrer un seul programme exactement tel que prévisualisé.", "laser-engraving-artwork-export": "Exporter tout programme en dessin SVG, PDF ou PNG 1:1 pour un graveur laser.",
           "parameters": "Isolation, perçage, découpe, hauteurs de sécurité, vernis et sérigraphie.", "preview": "Les vues 2D et 3D, les View Options et la signification des couleurs.",
           "playback-estimates": "Simulation fidèle aux avances et estimations de durée.", "side-view": "Vérifier les profondeurs dans les projections X–Z, Y–Z et profil.", "view-controls": "Zoom, déplacement et ajustement.",
           "measuring-undo": "Le mètre ruban et l'historique d'annulation de toute l'application.", "g-code-log-and-console-tabs": "Le texte du programme, le journal de génération et la console machine.",
           "presets-settings": "Jeux de paramètres enregistrés et les deux volets des Réglages.", "machine-zeroing-double-sided-work": "Où se trouve X0 Y0 sur la carte et comment les deux faces restent alignées.",
           "backlash-compensation": "Compenser le jeu des axes dans chaque programme écrit par l'application.", "machine-panel": "L'émetteur GRBL / FluidNC intégré : connecter, jogger, palper, envoyer.",
           "troubleshooting": "Que faire quand un aperçu échoue ou qu'une coupe semble fausse.", "keyboard-shortcuts": "Tous les raccourcis dans un tableau."},
    "es": {"workflow-overview": "Los siete pasos desde una exportación Gerber hasta una placa terminada.", "project-folder-detection": "Cómo se reconocen las exportaciones de EasyEDA y KiCad, y qué escribe Generate y dónde.",
           "tools-v-bits-read-this-first": "Por qué cada diámetro debe ser el diámetro de corte efectivo a la profundidad.", "test-boards": "Tres placas pequeñas que miden su instalación: parámetros, holgura, ajuste de agujeros.",
           "projects": "El paquete .cncproj, abrir, guardar e importar capas.", "custom-layers-drawing-your-own-shapes": "Dibuje líneas, formas y texto y mecanícelos como cualquier otra capa.",
           "editing-imported-layers": "Redimensione pistas, pads y agujeros en el sitio sin tocar los originales.", "tool-library": "Cada fresa que posee, con sus datos de corte, compartida por todos los proyectos.",
           "toolpath-engines": "pcb2gcode o el motor nativo: qué cambia y qué no.", "generating-programs": "El diálogo Generate, la carpeta de destino y los archivos que escribe.",
           "exporting-one-program": "Guardar un solo programa exactamente como se previsualiza.", "laser-engraving-artwork-export": "Exportar cualquier programa como arte SVG, PDF o PNG 1:1 para un grabador láser.",
           "parameters": "Aislamiento, taladrado, corte, alturas de seguridad, máscara y serigrafía.", "preview": "Las vistas 2D y 3D, las View Options y qué significan sus colores.",
           "playback-estimates": "Simulación fiel a los avances y estimaciones de tiempo.", "side-view": "Comprobar profundidades en las proyecciones X–Z, Y–Z y perfil.", "view-controls": "Zoom, desplazamiento y ajuste.",
           "measuring-undo": "La cinta métrica y el historial de deshacer de toda la aplicación.", "g-code-log-and-console-tabs": "El texto del programa, el registro de generación y la consola de la máquina.",
           "presets-settings": "Conjuntos de parámetros guardados y los dos paneles de Ajustes.", "machine-zeroing-double-sided-work": "Dónde está X0 Y0 en la placa y cómo ambas caras siguen registradas.",
           "backlash-compensation": "Compensar la holgura de los ejes en cada programa que escribe la aplicación.", "machine-panel": "El emisor GRBL / FluidNC integrado: conectar, jog, palpar, enviar.",
           "troubleshooting": "Qué hacer cuando falla una vista previa o un corte parece mal.", "keyboard-shortcuts": "Todos los atajos en una tabla."},
    "tr": {"workflow-overview": "Gerber dışa aktarımından bitmiş karta yedi adım.", "project-folder-detection": "EasyEDA ve KiCad dışa aktarımları nasıl tanınır, Generate neyi nereye yazar.",
           "tools-v-bits-read-this-first": "Her çapın neden derinlikteki etkin kesme çapı olması gerektiği.", "test-boards": "Kurulumunuzu ölçen üç küçük kart: parametreler, boşluk, delik uyumu.",
           "projects": ".cncproj paketi; açma, kaydetme ve katman içe aktarma.", "custom-layers-drawing-your-own-shapes": "Çizgi, şekil ve metin çizin; diğer katmanlar gibi işleyin.",
           "editing-imported-layers": "İzleri, pad'leri ve delikleri asıllara dokunmadan yerinde boyutlandırın.", "tool-library": "Sahip olduğunuz her uç, kesme verileriyle, tüm projelerde ortak.",
           "toolpath-engines": "pcb2gcode ya da yerel motor: ne değişir, ne değişmez.", "generating-programs": "Generate iletişim kutusu, hedef klasör ve yazdığı dosyalar.",
           "exporting-one-program": "Tek bir programı tam önizlendiği gibi kaydedin.", "laser-engraving-artwork-export": "Herhangi bir programı lazer kazıyıcı için 1:1 SVG, PDF ya da PNG çizim olarak dışa aktarın.",
           "parameters": "İzolasyon, delme, kesim, güvenlik yükseklikleri, maske ve serigrafi ayarları.", "preview": "2D ve 3D görünümler, View Options ve renklerin anlamı.",
           "playback-estimates": "İlerleme hızına sadık simülasyon ve süre tahminleri.", "side-view": "X–Z, Y–Z ve profil izdüşümlerinde derinlik kontrolü.", "view-controls": "Yakınlaştırma, kaydırma ve sığdırma.",
           "measuring-undo": "Şerit metre ve uygulama geneli geri alma geçmişi.", "g-code-log-and-console-tabs": "Program metni, üretim günlüğü ve makine konsolu.",
           "presets-settings": "Kayıtlı parametre kümeleri ve iki Ayarlar bölmesi.", "machine-zeroing-double-sided-work": "X0 Y0 kart üzerinde nerede ve iki taraf nasıl çakışık kalır.",
           "backlash-compensation": "Uygulamanın yazdığı her programda eksen boşluğunu telafi edin.", "machine-panel": "Yerleşik GRBL / FluidNC gönderici: bağlan, jog, probla, gönder.",
           "troubleshooting": "Bir önizleme başarısız olduğunda ya da bir kesim yanlış göründüğünde ne yapmalı.", "keyboard-shortcuts": "Tüm kısayollar tek tabloda."},
}

# figure key → image name; captions per language
FIGURE_IMAGES = {
    "workflow-overview": "workflow-overview", "project-folder-detection": "project-folder-detection", "tools-v-bits-read-this-first": "tools-v-bits",
    "test-boards": "test-board-backlash", "projects": "projects-import", "custom-layers-drawing-your-own-shapes": "custom-layers",
    "editing-imported-layers": "editing-imported-layers", "tool-library": "tool-library", "toolpath-engines": "toolpath-engines",
    "generating-programs": "generate-dialog", "exporting-one-program": "exporting-one-program", "laser-engraving-artwork-export": "laser-export",
    "parameters-copper-isolation": "parameters-isolation", "parameters-drilling-cutout": "parameters-drilling", "parameters-solder-mask-etch": "parameters-mask",
    "parameters-silkscreen-engraving": "parameters-silkscreen", "preview": "preview-2d", "preview-3d-view": "preview-3d", "preview-view-options": "view-options",
    "playback-estimates": "playback", "side-view": "side-view", "measuring-undo": "measuring", "g-code-log-and-console-tabs": "gcode-tab",
    "presets-settings": "presets-settings", "presets-settings-machine": "machine-settings", "machine-zeroing-double-sided-work": "machine-zeroing",
    "backlash-compensation": "backlash-compensation", "machine-panel": "machine-panel-program", "machine-panel-jogging-and-overrides": "machine-panel-control",
    "machine-panel-positions-tab": "machine-panel-positions", "machine-panel-program-tab-sending": "machine-panel-program", "machine-panel-probe-tab": "machine-panel-probe",
    "machine-panel-axis-calibration-stepsmm": "machine-axis-calibration", "machine-panel-macros-tab": "machine-panel-macros", "machine-panel-height-map-tab": "machine-panel-heightmap",
    "troubleshooting": "troubleshooting",
}
CAPTIONS = {
    "en": {"workflow-overview": "The main window: layer files and settings on the left, the toolpath preview and the side view on the right.",
           "project-folder-detection": "A KiCad export opened: the Log tab lists which file was taken for each layer.",
           "tools-v-bits-read-this-first": "File → Generate Test Board… mills traces of known widths so the effective diameter can be measured.",
           "test-boards": "Generate Test Board with the backlash test selected.",
           "projects": "The Import Layers sheet: each file's role is guessed from its name and can be changed before importing.",
           "custom-layers-drawing-your-own-shapes": "A custom layer with every shape kind; the selected rectangle shows its handles and the Properties panel.",
           "editing-imported-layers": "Editing the top copper file: all tracks selected, the sidebar lists the file's apertures.",
           "tool-library": "The Tool Library window with a bit's cutting data and its 3D model.",
           "toolpath-engines": "Machine setup holds the engine choice and the parameters shared by every program.",
           "generating-programs": "The Generate dialog: what to produce, where to write it, and the stages as they run.",
           "exporting-one-program": "With the outline selected, CNC export in the sidebar saves just that program.",
           "laser-engraving-artwork-export": "The Laser export section at the bottom of the sidebar: format, polarity, frame.",
           "parameters-copper-isolation": "Copper isolation settings for the selected copper program.",
           "parameters-drilling-cutout": "A drill program selected: Drilling, Bits on hand and Hole milling show that file's own values.",
           "parameters-solder-mask-etch": "The mask etch program and its settings.", "parameters-silkscreen-engraving": "Silkscreen engraving settings.",
           "preview": "The 2D toolpath view: cuts in the layer's colour, rapids dashed in yellow, the origin marker at X0 Y0.",
           "preview-3d-view": "The 3D view: the board slab, the cut channels and the bit at the current playback position.",
           "preview-view-options": "The View Options menu.",
           "playback-estimates": "Playback at 60 %: the finished part of the program is highlighted and the current G-code line is shown.",
           "side-view": "The side view with its labelled reference lines.", "measuring-undo": "The tape measure between two points: distance, ΔX, ΔY and angle.",
           "g-code-log-and-console-tabs": "The G-code tab following playback: the current line is highlighted.",
           "presets-settings": "Settings → General: units and the preview refresh mode.", "presets-settings-machine": "Settings → Machine: connection, jog, probe, motion and program options.",
           "machine-zeroing-double-sided-work": "Machine setup → Origin decides where X0 Y0 is on the board.",
           "backlash-compensation": "Machine setup → Backlash compensation, with the test and the file compensator.",
           "machine-panel": "The Machine panel beside the preview; here the Program tab while a job streams.",
           "machine-panel-jogging-and-overrides": "Jog pad, overrides and machine controls on the Control tab.",
           "machine-panel-positions-tab": "The Positions tab: saved machine positions and work zeros.",
           "machine-panel-program-tab-sending": "A program streaming: the job bar shows the line, elapsed and remaining time while the views follow the machine.",
           "machine-panel-probe-tab": "The Probe tab: two-pass Z touch-off.",
           "machine-panel-axis-calibration-stepsmm": "Settings → Machine → Axis calibration reads and writes the controller's steps/mm.",
           "machine-panel-macros-tab": "The Macros tab: each macro becomes a user button on the Control tab.",
           "machine-panel-height-map-tab": "A 3 × 3 height map probed on the simulator, drawn over the toolpath.",
           "troubleshooting": "The Log tab: every step with its timing, warnings and errors."},
    "fr": {"workflow-overview": "La fenêtre principale : fichiers de couches et réglages à gauche, aperçu du parcours et vue latérale à droite.",
           "project-folder-detection": "Un export KiCad ouvert : l'onglet Log liste le fichier retenu pour chaque couche.",
           "tools-v-bits-read-this-first": "File → Generate Test Board… fraise des pistes de largeurs connues pour mesurer le diamètre effectif.",
           "test-boards": "Generate Test Board avec le test de jeu sélectionné.",
           "projects": "La feuille Import Layers : le rôle de chaque fichier est deviné d'après son nom et peut être changé avant l'import.",
           "custom-layers-drawing-your-own-shapes": "Une couche personnalisée avec chaque type de forme ; le rectangle sélectionné montre ses poignées et le panneau Properties.",
           "editing-imported-layers": "Édition du fichier de cuivre supérieur : toutes les pistes sélectionnées, la barre latérale liste les ouvertures du fichier.",
           "tool-library": "La fenêtre Tool Library avec les données de coupe d'une fraise et son modèle 3D.",
           "toolpath-engines": "Machine setup contient le choix du moteur et les paramètres partagés par tous les programmes.",
           "generating-programs": "Le dialogue Generate : quoi produire, où l'écrire, et les étapes pendant l'exécution.",
           "exporting-one-program": "Avec le contour sélectionné, CNC export dans la barre latérale enregistre uniquement ce programme.",
           "laser-engraving-artwork-export": "La section Laser export en bas de la barre latérale : format, polarité, cadre.",
           "parameters-copper-isolation": "Réglages d'isolation du cuivre pour le programme de cuivre sélectionné.",
           "parameters-drilling-cutout": "Un programme de perçage sélectionné : Drilling, Bits on hand et Hole milling montrent les valeurs propres à ce fichier.",
           "parameters-solder-mask-etch": "Le programme de gravure du vernis et ses réglages.", "parameters-silkscreen-engraving": "Réglages de gravure de la sérigraphie.",
           "preview": "La vue 2D du parcours : coupes dans la couleur de la couche, rapides en pointillés jaunes, marqueur d'origine à X0 Y0.",
           "preview-3d-view": "La vue 3D : la plaque, les rainures et la fraise à la position de lecture courante.",
           "preview-view-options": "Le menu View Options.",
           "playback-estimates": "Lecture à 60 % : la partie terminée du programme est surlignée et la ligne G-code courante est affichée.",
           "side-view": "La vue latérale avec ses lignes de référence étiquetées.", "measuring-undo": "Le mètre ruban entre deux points : distance, ΔX, ΔY et angle.",
           "g-code-log-and-console-tabs": "L'onglet G-code suivant la lecture : la ligne courante est surlignée.",
           "presets-settings": "Settings → General : unités et mode de rafraîchissement de l'aperçu.", "presets-settings-machine": "Settings → Machine : connexion, jog, palpage, mouvement et options de programme.",
           "machine-zeroing-double-sided-work": "Machine setup → Origin décide où se trouve X0 Y0 sur la carte.",
           "backlash-compensation": "Machine setup → Backlash compensation, avec le test et le compensateur de fichier.",
           "machine-panel": "Le panneau Machine à côté de l'aperçu ; ici l'onglet Program pendant l'envoi d'un travail.",
           "machine-panel-jogging-and-overrides": "Pavé de jog, overrides et commandes machine sur l'onglet Control.",
           "machine-panel-positions-tab": "L'onglet Positions : positions machine enregistrées et zéros pièce.",
           "machine-panel-program-tab-sending": "Un programme en cours d'envoi : la barre de travail montre la ligne, le temps écoulé et restant pendant que les vues suivent la machine.",
           "machine-panel-probe-tab": "L'onglet Probe : palpage Z en deux passes.",
           "machine-panel-axis-calibration-stepsmm": "Settings → Machine → Axis calibration lit et écrit les pas/mm du contrôleur.",
           "machine-panel-macros-tab": "L'onglet Macros : chaque macro devient un bouton utilisateur sur l'onglet Control.",
           "machine-panel-height-map-tab": "Une carte de hauteur 3 × 3 palpée sur le simulateur, dessinée sur le parcours.",
           "troubleshooting": "L'onglet Log : chaque étape avec sa durée, les avertissements et les erreurs."},
    "es": {"workflow-overview": "La ventana principal: archivos de capa y ajustes a la izquierda, vista previa de trayectoria y vista lateral a la derecha.",
           "project-folder-detection": "Una exportación de KiCad abierta: la pestaña Log lista qué archivo se tomó para cada capa.",
           "tools-v-bits-read-this-first": "File → Generate Test Board… fresa pistas de anchos conocidos para medir el diámetro efectivo.",
           "test-boards": "Generate Test Board con la prueba de holgura seleccionada.",
           "projects": "La hoja Import Layers: el rol de cada archivo se deduce de su nombre y puede cambiarse antes de importar.",
           "custom-layers-drawing-your-own-shapes": "Una capa personalizada con cada tipo de forma; el rectángulo seleccionado muestra sus tiradores y el panel Properties.",
           "editing-imported-layers": "Editando el archivo de cobre superior: todas las pistas seleccionadas, la barra lateral lista las aperturas del archivo.",
           "tool-library": "La ventana Tool Library con los datos de corte de una fresa y su modelo 3D.",
           "toolpath-engines": "Machine setup guarda la elección de motor y los parámetros compartidos por todos los programas.",
           "generating-programs": "El diálogo Generate: qué producir, dónde escribirlo y las etapas mientras se ejecutan.",
           "exporting-one-program": "Con el contorno seleccionado, CNC export en la barra lateral guarda solo ese programa.",
           "laser-engraving-artwork-export": "La sección Laser export al final de la barra lateral: formato, polaridad, marco.",
           "parameters-copper-isolation": "Ajustes de aislamiento del cobre para el programa de cobre seleccionado.",
           "parameters-drilling-cutout": "Un programa de taladrado seleccionado: Drilling, Bits on hand y Hole milling muestran los valores propios de ese archivo.",
           "parameters-solder-mask-etch": "El programa de grabado de máscara y sus ajustes.", "parameters-silkscreen-engraving": "Ajustes de grabado de serigrafía.",
           "preview": "La vista 2D de trayectoria: cortes en el color de la capa, rápidos en amarillo discontinuo, marcador de origen en X0 Y0.",
           "preview-3d-view": "La vista 3D: la placa, los canales de corte y la fresa en la posición de reproducción actual.",
           "preview-view-options": "El menú View Options.",
           "playback-estimates": "Reproducción al 60 %: la parte terminada del programa se resalta y se muestra la línea de G-code actual.",
           "side-view": "La vista lateral con sus líneas de referencia etiquetadas.", "measuring-undo": "La cinta métrica entre dos puntos: distancia, ΔX, ΔY y ángulo.",
           "g-code-log-and-console-tabs": "La pestaña G-code siguiendo la reproducción: la línea actual está resaltada.",
           "presets-settings": "Settings → General: unidades y modo de actualización de la vista previa.", "presets-settings-machine": "Settings → Machine: conexión, jog, palpado, movimiento y opciones de programa.",
           "machine-zeroing-double-sided-work": "Machine setup → Origin decide dónde está X0 Y0 en la placa.",
           "backlash-compensation": "Machine setup → Backlash compensation, con la prueba y el compensador de archivos.",
           "machine-panel": "El panel Machine junto a la vista previa; aquí la pestaña Program mientras se transmite un trabajo.",
           "machine-panel-jogging-and-overrides": "Botonera de jog, overrides y controles de máquina en la pestaña Control.",
           "machine-panel-positions-tab": "La pestaña Positions: posiciones de máquina guardadas y ceros de trabajo.",
           "machine-panel-program-tab-sending": "Un programa transmitiéndose: la barra de trabajo muestra la línea, el tiempo transcurrido y el restante mientras las vistas siguen a la máquina.",
           "machine-panel-probe-tab": "La pestaña Probe: palpado Z en dos pasadas.",
           "machine-panel-axis-calibration-stepsmm": "Settings → Machine → Axis calibration lee y escribe los pasos/mm del controlador.",
           "machine-panel-macros-tab": "La pestaña Macros: cada macro se convierte en un botón de usuario en la pestaña Control.",
           "machine-panel-height-map-tab": "Un mapa de altura 3 × 3 palpado en el simulador, dibujado sobre la trayectoria.",
           "troubleshooting": "La pestaña Log: cada paso con su tiempo, avisos y errores."},
    "tr": {"workflow-overview": "Ana pencere: solda katman dosyaları ve ayarlar, sağda takım yolu önizlemesi ve yan görünüm.",
           "project-folder-detection": "Açılmış bir KiCad dışa aktarımı: Log sekmesi her katman için hangi dosyanın alındığını listeler.",
           "tools-v-bits-read-this-first": "File → Generate Test Board…, etkin çapın ölçülebilmesi için bilinen genişlikte izler frezeler.",
           "test-boards": "Boşluk testi seçiliyken Generate Test Board.",
           "projects": "Import Layers sayfası: her dosyanın rolü adından tahmin edilir ve içe aktarmadan önce değiştirilebilir.",
           "custom-layers-drawing-your-own-shapes": "Her şekil türünü içeren özel bir katman; seçili dikdörtgen tutamaçlarını ve Properties panelini gösterir.",
           "editing-imported-layers": "Üst bakır dosyası düzenleniyor: tüm izler seçili, kenar çubuğu dosyanın apertürlerini listeler.",
           "tool-library": "Bir ucun kesme verileri ve 3D modeliyle Tool Library penceresi.",
           "toolpath-engines": "Machine setup motor seçimini ve tüm programların paylaştığı parametreleri tutar.",
           "generating-programs": "Generate iletişim kutusu: ne üretilecek, nereye yazılacak ve çalışırken aşamalar.",
           "exporting-one-program": "Dış hat seçiliyken kenar çubuğundaki CNC export yalnızca o programı kaydeder.",
           "laser-engraving-artwork-export": "Kenar çubuğunun altındaki Laser export bölümü: biçim, polarite, çerçeve.",
           "parameters-copper-isolation": "Seçili bakır programı için bakır izolasyon ayarları.",
           "parameters-drilling-cutout": "Seçili bir delme programı: Drilling, Bits on hand ve Hole milling o dosyanın kendi değerlerini gösterir.",
           "parameters-solder-mask-etch": "Maske aşındırma programı ve ayarları.", "parameters-silkscreen-engraving": "Serigrafi kazıma ayarları.",
           "preview": "2D takım yolu görünümü: katman renginde kesimler, sarı kesikli hızlılar, X0 Y0'daki başlangıç işareti.",
           "preview-3d-view": "3D görünüm: kart levhası, kesim kanalları ve geçerli oynatma konumundaki uç.",
           "preview-view-options": "View Options menüsü.",
           "playback-estimates": "%60'ta oynatma: programın biten kısmı vurgulanır ve geçerli G-code satırı gösterilir.",
           "side-view": "Etiketli referans çizgileriyle yan görünüm.", "measuring-undo": "İki nokta arasındaki şerit metre: mesafe, ΔX, ΔY ve açı.",
           "g-code-log-and-console-tabs": "Oynatmayı izleyen G-code sekmesi: geçerli satır vurgulu.",
           "presets-settings": "Settings → General: birimler ve önizleme yenileme modu.", "presets-settings-machine": "Settings → Machine: bağlantı, jog, prob, hareket ve program seçenekleri.",
           "machine-zeroing-double-sided-work": "Machine setup → Origin, X0 Y0'ın kart üzerinde nerede olduğuna karar verir.",
           "backlash-compensation": "Machine setup → Backlash compensation; testi ve dosya telafi aracıyla.",
           "machine-panel": "Önizlemenin yanındaki Machine paneli; burada bir iş akarken Program sekmesi.",
           "machine-panel-jogging-and-overrides": "Control sekmesinde jog tuşları, override'lar ve makine denetimleri.",
           "machine-panel-positions-tab": "Positions sekmesi: kayıtlı makine konumları ve iş sıfırları.",
           "machine-panel-program-tab-sending": "Akan bir program: görünümler makineyi izlerken iş çubuğu satırı, geçen ve kalan süreyi gösterir.",
           "machine-panel-probe-tab": "Probe sekmesi: iki geçişli Z dokunması.",
           "machine-panel-axis-calibration-stepsmm": "Settings → Machine → Axis calibration denetleyicinin adım/mm değerini okur ve yazar.",
           "machine-panel-macros-tab": "Macros sekmesi: her makro Control sekmesinde bir kullanıcı düğmesi olur.",
           "machine-panel-height-map-tab": "Simülatörde problanmış 3 × 3 yükseklik haritası, takım yolunun üzerine çizilmiş.",
           "troubleshooting": "Log sekmesi: her adım süresiyle, uyarılar ve hatalar."},
}

UI = {
    "en": dict(title="CNC G-Coder User Guide", subtitle="Everything from the first Gerber export to the finished, drilled and cut board, in the order you will do it.",
               contents="Contents", search="Search the guide", no_results="No matches.", results="results", in_="in", back_top="↑ Back to top",
               start_again="Start again", need_help="Need help?", view_larger="View larger", actual="Actual size", fit="Fit to screen", close="Close",
               prev="‹ Previous", next="Next ›", screenshot="Screenshot", language="Language", menu="Table of contents", important="Important", note="Note"),
    "fr": dict(title="CNC G-Coder — Guide de l'utilisateur", subtitle="Tout, du premier export Gerber à la carte finie, percée et découpée, dans l'ordre où vous le ferez.",
               contents="Sommaire", search="Rechercher dans le guide", no_results="Aucun résultat.", results="résultats", in_="dans", back_top="↑ Haut de page",
               start_again="Recommencer", need_help="Besoin d'aide ?", view_larger="Agrandir", actual="Taille réelle", fit="Ajuster à l'écran", close="Fermer",
               prev="‹ Précédent", next="Suivant ›", screenshot="Capture d'écran", language="Langue", menu="Sommaire", important="Important", note="Remarque"),
    "es": dict(title="CNC G-Coder — Guía del usuario", subtitle="Todo, desde la primera exportación Gerber hasta la placa terminada, taladrada y cortada, en el orden en que lo hará.",
               contents="Contenido", search="Buscar en la guía", no_results="Sin resultados.", results="resultados", in_="en", back_top="↑ Volver arriba",
               start_again="Empezar de nuevo", need_help="¿Necesita ayuda?", view_larger="Ver más grande", actual="Tamaño real", fit="Ajustar a la pantalla", close="Cerrar",
               prev="‹ Anterior", next="Siguiente ›", screenshot="Captura de pantalla", language="Idioma", menu="Índice", important="Importante", note="Nota"),
    "tr": dict(title="CNC G-Coder Kullanım Kılavuzu", subtitle="İlk Gerber dışa aktarımından delinmiş ve kesilmiş bitmiş karta kadar her şey, yapacağınız sırayla.",
               contents="İçindekiler", search="Kılavuzda ara", no_results="Sonuç yok.", results="sonuç", in_="içinde", back_top="↑ Başa dön",
               start_again="Baştan başla", need_help="Yardım mı gerekli?", view_larger="Büyük göster", actual="Gerçek boyut", fit="Ekrana sığdır", close="Kapat",
               prev="‹ Önceki", next="Sonraki ›", screenshot="Ekran görüntüsü", language="Dil", menu="İçindekiler", important="Önemli", note="Not"),
}

# ---------------------------------------------------------------- content
def callouts(lang, cid, text):
    """Promote two paragraphs to callouts (same position in every language)."""
    u = UI[lang]
    if cid == "tools-v-bits-read-this-first":
        text = re.sub(r"^<p>", f"<div class='callout important'><p class='callout-title'>{u['important']}</p><p>", text, count=1)
        text = text.replace("</p>", "</p></div>", 1)
    if cid == "project-folder-detection":
        paras = text.split("\n")
        for i, p in enumerate(paras):
            if p.startswith("<p>") and i == 2:
                paras[i] = f"<div class='callout note'><p class='callout-title'>{u['note']}</p>" + p + "</div>"
        text = "\n".join(paras)
    return text

def figure(lang, key):
    name = FIGURE_IMAGES.get(key)
    if not name or not os.path.exists(os.path.join(IMG_DIR, name + ".png")): return ""
    cap = html.escape(CAPTIONS[lang].get(key, CAPTIONS["en"].get(key, "")))
    u = UI[lang]
    return (f"<figure class='shot'><div class='shot-frame'><img src='images/{name}.png' alt='{cap}' loading='lazy' tabindex='0'>"
            f"<button type='button' class='shot-zoom' aria-label='{u['view_larger']}'>"
            f"<svg viewBox='0 0 16 16' width='14' height='14' aria-hidden='true'><path d='M2 6V2h4M14 6V2h-4M2 10v4h4M14 10v4h-4' fill='none' stroke='currentColor' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/></svg>"
            f"<span>{u['view_larger']}</span></button></div><figcaption>{cap}</figcaption></figure>")

def group_of(cid):
    return next(g for g, ids in GROUPS if cid in ids)

def chapter_html(lang, cid, n):
    c = CH[lang][cid]
    g = GROUP_NAMES[lang][group_of(cid)]
    out = [f"<section class='chapter' data-id='{cid}'>",
           f"<header class='chapter-head' data-n='{n}'><p class='eyebrow'>{html.escape(g)}</p><h2>{html.escape(c['title'])}</h2>"
           f"<p class='lede'>{html.escape(SUMMARY[lang][cid])}</p></header>",
           figure(lang, cid), callouts(lang, cid, c["intro"])]
    for s in c["sections"]:
        out.append(f"<section class='sub' data-id='{s['id']}'><h3>{html.escape(s['title'])}</h3>{figure(lang, s['id'])}{s['html']}</section>")
    out.append("</section>")
    return "\n".join(out)

def nav_html(lang):
    out = []
    n = 0
    for g, ids in GROUPS:
        out.append(f"<li class='group' data-group='{g}'><button class='group-toggle' aria-expanded='true'><span>{html.escape(GROUP_NAMES[lang][g])}</span><svg class='chev' viewBox='0 0 16 16' width='12' height='12' aria-hidden='true'><path d='M5 3l5 5-5 5' fill='none' stroke='currentColor' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/></svg></button><ul class='group-items'>")
        for cid in ids:
            n += 1
            c = CH[lang][cid]
            out.append(f"<li><a href='#{cid}' data-target='{cid}'><span class='num'>{n}</span>{html.escape(SHORT[lang][cid])}</a>")
            if c["sections"]:
                out.append("<ul class='secs'>" + "".join(f"<li><a href='#{s['id']}' data-target='{s['id']}'>{html.escape(s['title'])}</a></li>" for s in c["sections"]) + "</ul>")
            out.append("</li>")
        out.append("</ul></li>")
    return "<ul class='nav'>" + "".join(out) + "</ul>"

def cards_html(lang):
    return "".join(f"<a class='card' href='#{cid}'><p class='card-group'>{html.escape(GROUP_NAMES[lang][group_of(cid)])}</p><h3>{html.escape(SHORT[lang][cid])}</h3><p>{html.escape(SUMMARY[lang][cid])}</p></a>" for cid in ORDER)

def strip_tags(h):
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", h))).strip()

def search_index(lang):
    entries = []
    for cid in ORDER:
        c = CH[lang][cid]
        entries.append({"id": cid, "t": c["title"], "c": GROUP_NAMES[lang][group_of(cid)], "x": strip_tags(c["intro"])})
        for s in c["sections"]:
            entries.append({"id": s["id"], "t": s["title"], "c": SHORT[lang][cid], "x": strip_tags(s["html"])})
    return entries

def lang_block(lang):
    u = UI[lang]
    sheets = "".join(f"<div class='sheet'>{chapter_html(lang, cid, n)}<a class='top-link' href='#top'>{u['back_top']}</a></div>" for n, cid in enumerate(ORDER, 1))
    return (f"<div class='lang' data-lang='{lang}' hidden>"
            f"<div class='cards'>{cards_html(lang)}</div>{GUIDES[lang]['preamble']}{sheets}"
            f"<nav class='pager' aria-label='Pagination'><a href='#workflow-overview'><small>{u['start_again']}</small><span>{html.escape(SHORT[lang]['workflow-overview'])}</span></a>"
            f"<a href='#troubleshooting'><small>{u['need_help']}</small><span>{html.escape(SHORT[lang]['troubleshooting'])}</span></a></nav></div>")

# ---------------------------------------------------------------- page
TOKENS_LIGHT = """
  --bg:#f5f5f7; --bg-side:#f5f5f7; --bg-code:#f0f0f3; --bg-elev:#ffffff;
  --fg:#1d1d1f; --fg-2:#6e6e73; --fg-3:#86868b; --line:#d2d2d7; --line-2:#e8e8ed;
  --accent:#0066cc; --accent-hover:#0077ed; --accent-soft:#e8f0fb; --warn:#b25000; --warn-soft:#fff4e5;
  --kbd-bg:#fff; --mark:#fff2a8; --shadow:0 1px 3px rgba(0,0,0,.08), 0 8px 24px rgba(0,0,0,.06);
"""
TOKENS_DARK = """
  --bg:#000000; --bg-side:#000; --bg-code:#2a2a2d; --bg-elev:#1d1d1f;
  --fg:#f5f5f7; --fg-2:#a1a1a6; --fg-3:#86868b; --line:#424245; --line-2:#2d2d30;
  --accent:#2997ff; --accent-hover:#5ab1ff; --accent-soft:#0d2a4a; --warn:#ffb340; --warn-soft:#2b1d08;
  --kbd-bg:#2d2d30; --mark:#5a4a00; --shadow:0 1px 3px rgba(0,0,0,.5), 0 8px 24px rgba(0,0,0,.4);
"""
CSS = f"""
/* Layout: light grey canvas, white sheet per chapter, numbered contents with search on the left, hero with language picker and chapter cards. Four languages embedded; one shown. */
:root {{ {TOKENS_LIGHT} }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ {TOKENS_DARK} color-scheme: dark; }} }}
:root[data-theme="dark"] {{ {TOKENS_DARK} color-scheme: dark; }}
*,*::before,*::after{{box-sizing:border-box}}
:root{{--side:320px;--gap:56px;--content:1040px;--page:1680px}}
body{{margin:0;background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;font-size:17px;line-height:1.52;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}}
a{{color:var(--accent);text-decoration:none}} a:hover{{text-decoration:underline}}
h1,h2,h3{{text-wrap:balance;letter-spacing:-.01em;margin:0}}
h2{{font-size:36px;line-height:1.12;font-weight:700;letter-spacing:-.02em}}
h3{{font-size:24px;line-height:1.2;font-weight:600;margin:2.2em 0 .6em}}
p{{margin:0 0 1em}}
.lede{{font-size:21px;line-height:1.45;color:var(--fg-2);margin:.5em 0 0}}
.eyebrow{{font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--fg-3);margin:0 0 .5em}}
ul,ol{{padding-left:1.4em;margin:0 0 1.1em}} li{{margin:.45em 0}}
code{{font-family:"SF Mono",SFMono-Regular,Menlo,Consolas,monospace;font-size:.86em;background:var(--bg-code);padding:.12em .4em;border-radius:5px;border:1px solid var(--line-2)}}
pre{{background:var(--bg-code);border:1px solid var(--line-2);border-radius:12px;padding:16px 18px;overflow-x:auto;margin:0 0 1.2em;font-size:14px;line-height:1.5}}
pre code{{background:none;border:0;padding:0;font-size:inherit}}
kbd{{font-family:inherit;font-size:.9em;background:var(--kbd-bg);border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;padding:0 .4em;white-space:nowrap}}
strong{{font-weight:600}} .note{{color:var(--fg-2);font-size:15px}} .dash{{color:var(--fg-3)}}
.callout{{border-left:4px solid var(--accent);background:var(--accent-soft);padding:14px 18px 2px;border-radius:0 12px 12px 0;margin:1.2em 0}}
.callout.important{{border-color:var(--warn);background:var(--warn-soft)}}
.callout-title{{font-weight:700;font-size:13px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:.3em;color:var(--accent)}}
.callout.important .callout-title{{color:var(--warn)}}
mark{{background:var(--mark);color:inherit;border-radius:3px;padding:0 1px}}
:focus-visible{{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}}
@media (prefers-reduced-motion: reduce){{*{{transition:none!important;animation:none!important;scroll-behavior:auto!important}}}}
.table-wrap{{overflow-x:auto;margin:0 0 1.2em}}
table{{border-collapse:collapse;width:100%;font-size:15px}}
th,td{{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line-2);vertical-align:top}}
th{{font-weight:600;color:var(--fg-2);font-size:13px;letter-spacing:.03em;text-transform:uppercase}}
td:last-child{{white-space:nowrap}}
.shot{{margin:1.4em 0 1.6em}}
.shot-frame{{position:relative;border-radius:12px;overflow:hidden;border:1px solid var(--line-2);box-shadow:0 1px 2px rgba(0,0,0,.06),0 12px 32px rgba(0,0,0,.10);background:#1e1e1e}}
.shot img{{display:block;width:100%;height:auto;cursor:zoom-in}}
.shot-zoom{{position:absolute;right:10px;bottom:10px;display:inline-flex;align-items:center;gap:6px;font:inherit;font-size:12px;font-weight:600;color:#fff;background:rgba(0,0,0,.55);border:1px solid rgba(255,255,255,.22);border-radius:999px;padding:6px 11px;cursor:pointer;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);opacity:.85;transition:opacity .15s,background .15s}}
.shot-frame:hover .shot-zoom,.shot-zoom:focus-visible{{opacity:1;background:rgba(0,0,0,.75)}}
.shot figcaption{{font-size:14px;color:var(--fg-3);margin:.7em 0 0;line-height:1.4}}
/* hero */
.hero{{background:var(--bg-elev);border-bottom:1px solid var(--line-2);padding:44px 32px 40px}}
.hero-in{{max-width:var(--page);margin:0 auto;padding-left:calc(var(--side) + var(--gap));display:flex;gap:32px;align-items:center;flex-wrap:wrap}}
.appicon{{width:96px;height:96px;flex:none;filter:drop-shadow(0 6px 14px rgba(0,0,0,.18))}} .appicon img{{display:block;width:100%;height:100%}}
.hero h1{{font-size:48px;font-weight:700;letter-spacing:-.03em;line-height:1.05}}
.hero p{{font-size:21px;color:var(--fg-2);margin:.4em 0 0;max-width:36em}}
.hero-text{{min-width:0;flex:1 1 320px}}
.langbar{{display:flex;gap:4px;background:var(--bg);border:1px solid var(--line-2);border-radius:999px;padding:4px;flex:none;align-self:flex-start;margin-left:auto}}
.langbar button{{font:inherit;font-size:15px;font-weight:600;color:var(--fg-2);background:none;border:0;border-radius:999px;padding:8px 16px;cursor:pointer}}
.langbar button[aria-pressed="true"]{{background:var(--bg-elev);color:var(--fg);box-shadow:0 1px 2px rgba(0,0,0,.12)}}
.langbar button:hover{{color:var(--fg)}}
/* shell */
.menu-btn{{display:none;background:var(--bg-elev);border:1px solid var(--line);color:var(--fg);padding:8px 12px;border-radius:999px;cursor:pointer;font:inherit;font-size:14px;align-items:center;gap:8px;position:sticky;top:calc(12px + env(safe-area-inset-top,0px));z-index:30;margin:12px 16px 0}}
.wrap{{max-width:var(--page);margin:0 auto;padding:36px 32px 120px;display:grid;grid-template-columns:var(--side) minmax(0,1fr);gap:var(--gap)}}
main{{max-width:var(--content);min-width:0}}
#sidebar{{position:sticky;top:calc(16px + env(safe-area-inset-top,0px));align-self:start;max-height:calc(100vh - 32px);overflow-y:auto;font-size:15px;padding-right:20px;border-right:1px solid var(--line-2)}}
.side-title{{font-size:13px;letter-spacing:.06em;text-transform:uppercase;font-weight:600;color:var(--fg-3);margin:0 0 10px 12px}}
.search{{display:flex;align-items:center;gap:8px;background:var(--bg-elev);border:1px solid var(--line);border-radius:10px;padding:9px 12px;color:var(--fg-3);margin:0 0 14px}}
.search input{{border:0;background:none;color:var(--fg);font:inherit;width:100%;outline:0;min-width:0}}
.search input::-webkit-search-cancel-button{{-webkit-appearance:none;appearance:none}}
.search .clear{{display:none;border:0;background:none;color:var(--fg-3);cursor:pointer;font-size:16px;line-height:1;padding:0 2px}}
.search.has-query .clear{{display:block}}
.nav,.nav ul{{list-style:none;margin:0;padding:0}}
.group-toggle{{display:flex;width:100%;align-items:center;justify-content:space-between;background:none;border:0;color:var(--fg);font:inherit;font-weight:600;font-size:16px;padding:9px 12px;border-radius:8px;cursor:pointer;text-align:left}}
.group-toggle .chev{{transition:transform .18s;color:var(--fg-3)}}
.group-toggle[aria-expanded="true"] .chev{{transform:rotate(90deg)}}
.group-toggle[aria-expanded="false"]+.group-items{{display:none}}
.group{{margin-bottom:8px}}
.group-items>li>a{{display:flex;gap:10px;align-items:baseline;padding:7px 12px;border-radius:8px;color:var(--fg-2)}}
.num{{font-variant-numeric:tabular-nums;color:var(--fg-3);font-size:13px;min-width:1.4em;text-align:right}}
.secs{{margin:2px 0 4px}}
.secs a{{display:block;padding:5px 12px 5px 48px;border-radius:8px;color:var(--fg-3);font-size:14px;line-height:1.3}}
.nav a:hover{{text-decoration:none;color:var(--fg);background:color-mix(in srgb,var(--fg) 5%,transparent)}}
.nav a.active{{color:var(--accent);font-weight:600;background:var(--accent-soft)}}
.nav a.active .num{{color:var(--accent)}}
.results{{list-style:none;margin:0;padding:0}}
.results li{{margin:0}}
.results a{{display:block;padding:8px 12px;border-radius:8px;color:var(--fg)}}
.results a:hover,.results a:focus-visible{{text-decoration:none;background:color-mix(in srgb,var(--fg) 5%,transparent)}}
.results .r-title{{font-weight:600;font-size:15px}}
.results .r-crumb{{color:var(--fg-3);font-size:12px;margin-left:6px;font-weight:400}}
.results .r-snip{{color:var(--fg-2);font-size:14px;line-height:1.35;margin-top:2px}}
.results-head{{font-size:12px;color:var(--fg-3);margin:0 0 8px 12px}}
/* main */
.cards{{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:18px;margin:0 0 44px}}
.card{{display:block;background:var(--bg-elev);border:1px solid var(--line-2);border-radius:18px;padding:24px 24px 22px;color:var(--fg);box-shadow:0 1px 2px rgba(0,0,0,.04);transition:transform .15s,box-shadow .15s;min-width:0}}
.card:hover{{text-decoration:none;transform:translateY(-2px);box-shadow:var(--shadow)}}
.card-group{{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--accent);font-weight:600;margin-bottom:6px}}
.card h3{{font-size:20px;margin:0 0 6px;font-weight:600}}
.card p{{font-size:15px;color:var(--fg-2);margin:0;line-height:1.45}}
.sheet{{background:var(--bg-elev);border:1px solid var(--line-2);border-radius:20px;padding:44px 48px;margin:0 0 20px;box-shadow:0 1px 2px rgba(0,0,0,.04)}}
.chapter-head{{display:grid;grid-template-columns:auto minmax(0,1fr);gap:0 18px;align-items:start;margin:0 0 1.4em}}
.chapter-head .eyebrow,.chapter-head h2,.chapter-head .lede{{grid-column:2}}
.chapter-head::before{{content:attr(data-n);grid-row:1/span 3;width:44px;height:44px;border-radius:50%;background:var(--accent-soft);color:var(--accent);display:grid;place-items:center;font-weight:700;font-size:17px;font-variant-numeric:tabular-nums;margin-top:4px}}
.top-link{{display:inline-flex;gap:6px;align-items:center;font-size:13px;color:var(--fg-3);margin-top:1.2em}}
.pager{{display:flex;justify-content:space-between;gap:16px;margin:28px 0 0}}
.pager a{{flex:1;background:var(--bg-elev);border:1px solid var(--line-2);border-radius:14px;padding:14px 18px;display:flex;flex-direction:column;gap:2px;color:var(--fg)}}
.pager a:hover{{text-decoration:none;border-color:var(--accent)}} .pager a:last-child{{text-align:right}} .pager small{{color:var(--fg-3);font-size:13px}}
#backdrop{{display:none}}
/* lightbox */
.lightbox{{position:fixed;inset:0;z-index:100;display:none;background:rgba(0,0,0,.86);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}}
.lightbox.open{{display:grid;grid-template-rows:auto minmax(0,1fr) auto;padding:calc(12px + env(safe-area-inset-top,0px)) 16px calc(12px + env(safe-area-inset-bottom,0px))}}
.lightbox-bar{{display:flex;align-items:center;justify-content:space-between;gap:12px;color:#f5f5f7;font-size:14px}}
.lightbox-bar .count{{color:rgba(255,255,255,.6);font-variant-numeric:tabular-nums}}
.lightbox-actions{{display:flex;gap:8px}}
.lightbox-actions button,.lightbox-nav button{{font:inherit;font-size:13px;font-weight:600;color:#fff;background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18);border-radius:999px;padding:7px 13px;cursor:pointer}}
.lightbox-actions button:hover,.lightbox-nav button:hover{{background:rgba(255,255,255,.24)}}
.lightbox-stage{{position:relative;overflow:auto;display:grid;place-items:center;min-height:0;-webkit-overflow-scrolling:touch}}
.lightbox-stage img{{max-width:100%;max-height:100%;object-fit:contain;border-radius:8px;box-shadow:0 20px 60px rgba(0,0,0,.6);cursor:zoom-in}}
.lightbox.actual .lightbox-stage{{place-items:start}}
.lightbox.actual .lightbox-stage img{{max-width:none;max-height:none;width:auto;height:auto;cursor:zoom-out;border-radius:0}}
.lightbox-foot{{display:flex;align-items:center;justify-content:space-between;gap:16px;color:rgba(255,255,255,.8);font-size:14px;line-height:1.4;padding-top:10px}}
.lightbox-foot .cap{{min-width:0;flex:1}} .lightbox-nav{{display:flex;gap:8px;flex:none}} .lightbox-nav button:disabled{{opacity:.35;cursor:default}}
@media (max-width:900px){{
  .wrap{{grid-template-columns:minmax(0,1fr);padding:24px 16px 80px;gap:0}} main{{max-width:none}} .hero-in{{padding-left:0}}
  #sidebar{{border-right:0;padding-right:12px}}
  .menu-btn{{display:inline-flex}}
  #sidebar{{position:fixed;left:0;top:0;bottom:0;width:min(320px,86vw);max-height:none;z-index:50;background:var(--bg-elev);transform:translateX(-100%);transition:transform .22s;padding:calc(20px + env(safe-area-inset-top,0px)) 12px 40px;box-shadow:var(--shadow)}}
  body.menu-open #sidebar{{transform:none}}
  body.menu-open #backdrop{{display:block;position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:40}}
  .sheet{{padding:24px 18px;border-radius:16px}}
  .hero{{padding:28px 16px 24px}} .hero h1{{font-size:30px}} .hero p{{font-size:17px}} .appicon{{width:72px;height:72px}}
  h2{{font-size:26px}} body{{font-size:16px}}
  .chapter-head::before{{width:34px;height:34px;font-size:14px}}
  .lightbox-foot{{flex-direction:column;align-items:stretch}} .lightbox-nav{{justify-content:space-between}}
}}
@media (max-width:600px){{.langbar{{align-self:stretch;justify-content:space-between;margin-left:0}}}}
"""

JS = r"""
(function(){
  var LANGS=__LANGS__, UI=__UI__, INDEX=__INDEX__;
  var body=document.body, root=document.documentElement;
  var current='en';
  function pick(){
    try{var s=localStorage.getItem('cncg-lang');if(s&&LANGS.indexOf(s)>=0)return s}catch(e){}
    var n=(navigator.language||'en').slice(0,2).toLowerCase();return LANGS.indexOf(n)>=0?n:'en';
  }
  function applyIds(lang){
    document.querySelectorAll('.lang[data-lang], .nav-lang[data-lang]').forEach(function(block){
      var on=block.dataset.lang===lang;
      block.hidden=!on;
      block.querySelectorAll('[data-id]').forEach(function(el){ if(on)el.id=el.dataset.id; else el.removeAttribute('id'); });
    });
  }
  var targets=[],links={};
  function collect(){
    targets=Array.prototype.slice.call(document.querySelectorAll('.lang:not([hidden]) section.chapter, .lang:not([hidden]) section.sub'));
    links={};document.querySelectorAll('.nav-lang:not([hidden]) .nav a[data-target]').forEach(function(a){links[a.dataset.target]=a});
  }
  function setLang(lang,keepHash){
    current=lang; root.lang=lang;
    applyIds(lang);
    document.querySelectorAll('.nav-lang').forEach(function(n){n.hidden=n.dataset.lang!==lang});
    document.querySelectorAll('.langbar button').forEach(function(b){b.setAttribute('aria-pressed',b.dataset.lang===lang?'true':'false')});
    var u=UI[lang];
    document.title=u.title;
    document.querySelectorAll('[data-ui]').forEach(function(el){var k=el.dataset.ui;if(u[k]!=null){if(el.tagName==='INPUT')el.placeholder=u[k];else el.textContent=u[k];}});
    var search=document.getElementById('nav-search');if(search)search.setAttribute('aria-label',u.search);
    try{localStorage.setItem('cncg-lang',lang)}catch(e){}
    collect(); runSearch(); update();
    if(keepHash&&location.hash){var el=document.getElementById(location.hash.slice(1));if(el)el.scrollIntoView();}
  }
  document.querySelectorAll('.langbar button').forEach(function(b){b.addEventListener('click',function(){setLang(b.dataset.lang,true)})});

  // drawer + groups
  var toggle=document.getElementById('menu-toggle'),backdrop=document.getElementById('backdrop');
  function closeMenu(){body.classList.remove('menu-open');if(toggle)toggle.setAttribute('aria-expanded','false')}
  if(toggle)toggle.addEventListener('click',function(){var open=body.classList.toggle('menu-open');toggle.setAttribute('aria-expanded',open?'true':'false')});
  if(backdrop)backdrop.addEventListener('click',closeMenu);
  document.querySelectorAll('.group-toggle').forEach(function(b){
    var key='cncg-nav-'+b.closest('.group').dataset.group;
    try{if(localStorage.getItem(key)==='closed')b.setAttribute('aria-expanded','false')}catch(e){}
    b.addEventListener('click',function(){var o=b.getAttribute('aria-expanded')!=='true';b.setAttribute('aria-expanded',o?'true':'false');try{localStorage.setItem(key,o?'open':'closed')}catch(e){}
      document.querySelectorAll('.group[data-group="'+b.closest('.group').dataset.group+'"] .group-toggle').forEach(function(x){x.setAttribute('aria-expanded',o?'true':'false')});});
  });
  document.addEventListener('click',function(e){var a=e.target.closest('.nav a, .results a');if(a&&window.innerWidth<900)closeMenu()});

  // scroll spy
  var active=null;
  function update(){
    var y=window.scrollY+120,best=null;
    for(var i=0;i<targets.length;i++){if(targets[i].offsetTop<=y)best=targets[i];else break}
    var id=best?best.dataset.id:null;
    if(id===active)return;active=id;
    Object.keys(links).forEach(function(k){links[k].classList.toggle('active',k===id)});
    var a=links[id];if(a){var g=a.closest('.group');if(g)g.querySelector('.group-toggle').setAttribute('aria-expanded','true');
      var side=document.getElementById('sidebar');if(side&&!body.classList.contains('menu-open')){var r=a.getBoundingClientRect(),s=side.getBoundingClientRect();if(r.top<s.top+40||r.bottom>s.bottom-40)a.scrollIntoView({block:'center'})}}
  }
  window.addEventListener('scroll',update,{passive:true});window.addEventListener('resize',update);

  // search
  var input=document.getElementById('nav-search'),results=document.getElementById('search-results'),clearBtn=document.getElementById('search-clear'),searchBox=input.closest('.search');
  function norm(s){return s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/ı/g,'i')}
  function esc(s){return s.replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
  function snippet(text,terms){
    var n=norm(text),pos=-1;
    for(var i=0;i<terms.length;i++){var p=n.indexOf(terms[i]);if(p>=0&&(pos<0||p<pos))pos=p}
    var start=Math.max(0,pos-60),end=Math.min(text.length,(pos<0?0:pos)+120);
    var s=(start>0?'…':'')+text.slice(start,end)+(end<text.length?'…':'');
    return mark(esc(s),terms);
  }
  function mark(escaped,terms){
    return terms.reduce(function(acc,t){
      if(t.length<2)return acc;
      var re=new RegExp('('+t.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+')','ig');
      return acc.replace(re,'<mark>$1</mark>');
    },escaped);
  }
  function runSearch(){
    var q=norm(input.value.trim());
    var terms=q.split(/\s+/).filter(function(t){return t.length>=2});
    searchBox.classList.toggle('has-query',q.length>0);
    var navEl=document.querySelector('.nav-lang[data-lang="'+current+'"]');
    if(!terms.length){results.hidden=true;results.innerHTML='';if(navEl)navEl.hidden=false;return}
    if(navEl)navEl.hidden=true;results.hidden=false;
    var hits=[];
    INDEX[current].forEach(function(e){
      var t=norm(e.t),x=norm(e.x),score=0;
      for(var i=0;i<terms.length;i++){
        var inT=t.indexOf(terms[i])>=0,inX=x.indexOf(terms[i])>=0;
        if(!inT&&!inX){score=0;break}
        score+=inT?10:1;
        var c=x.split(terms[i]).length-1;score+=Math.min(c,5);
      }
      if(score>0)hits.push({e:e,s:score});
    });
    hits.sort(function(a,b){return b.s-a.s});
    hits=hits.slice(0,30);
    var u=UI[current];
    if(!hits.length){results.innerHTML='<li class="results-head">'+esc(u.no_results)+'</li>';return}
    var htmlOut='<li class="results-head">'+hits.length+' '+esc(u.results)+'</li>';
    hits.forEach(function(h){
      htmlOut+='<li><a href="#'+h.e.id+'"><span class="r-title">'+mark(esc(h.e.t),terms)+'<span class="r-crumb">'+esc(h.e.c)+'</span></span><div class="r-snip">'+snippet(h.e.x,terms)+'</div></a></li>';
    });
    results.innerHTML=htmlOut;
  }
  input.addEventListener('input',runSearch);
  input.addEventListener('keydown',function(e){
    if(e.key==='Escape'){input.value='';runSearch();input.blur()}
    if(e.key==='Enter'){var first=results.querySelector('a');if(first){first.click();}}
  });
  clearBtn.addEventListener('click',function(){input.value='';runSearch();input.focus()});
  document.addEventListener('keydown',function(e){if((e.metaKey||e.ctrlKey)&&e.key==='k'){e.preventDefault();input.focus();input.select()}});

  // lightbox
  var box=document.createElement('div');box.className='lightbox';box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');
  box.innerHTML='<div class="lightbox-bar"><span class="count"></span><div class="lightbox-actions"><button type="button" data-act="actual"></button><button type="button" data-act="close"></button></div></div><div class="lightbox-stage"><img alt=""></div><div class="lightbox-foot"><div class="cap"></div><div class="lightbox-nav"><button type="button" data-act="prev"></button><button type="button" data-act="next"></button></div></div>';
  document.body.appendChild(box);
  var img=box.querySelector('.lightbox-stage img'),cap=box.querySelector('.cap'),count=box.querySelector('.count'),stage=box.querySelector('.lightbox-stage');
  var prevBtn=box.querySelector('[data-act=prev]'),nextBtn=box.querySelector('[data-act=next]'),actualBtn=box.querySelector('[data-act=actual]'),closeBtn=box.querySelector('[data-act=close]');
  var shots=[],index=-1,lastFocus=null;
  function labels(){var u=UI[current];box.setAttribute('aria-label',u.screenshot);closeBtn.textContent=u.close;prevBtn.textContent=u.prev;nextBtn.textContent=u.next;actualBtn.textContent=box.classList.contains('actual')?u.fit:u.actual}
  function show(i){
    index=Math.max(0,Math.min(shots.length-1,i));
    var src=shots[index].querySelector('img'),text=shots[index].querySelector('figcaption');
    img.src=src.getAttribute('src');img.alt=src.alt;cap.textContent=text?text.textContent:'';
    count.textContent=(index+1)+' / '+shots.length;
    prevBtn.disabled=index===0;nextBtn.disabled=index===shots.length-1;
    box.classList.remove('actual');stage.scrollTo(0,0);labels();
  }
  function open(fig){shots=Array.prototype.slice.call(document.querySelectorAll('.lang:not([hidden]) .shot'));lastFocus=document.activeElement;show(shots.indexOf(fig));box.classList.add('open');body.style.overflow='hidden';closeBtn.focus()}
  function close(){box.classList.remove('open');body.style.overflow='';if(lastFocus&&lastFocus.focus)lastFocus.focus()}
  function toggleActual(){box.classList.toggle('actual');labels()}
  document.addEventListener('click',function(e){
    var z=e.target.closest('.shot-zoom');if(z){e.stopPropagation();open(z.closest('.shot'));return}
    var pic=e.target.closest('.shot img');if(pic){open(pic.closest('.shot'))}
  });
  document.addEventListener('keydown',function(e){
    if(e.target.matches('.shot img')&&(e.key==='Enter'||e.key===' ')){e.preventDefault();open(e.target.closest('.shot'));return}
    if(!box.classList.contains('open'))return;
    if(e.key==='Escape')close();else if(e.key==='ArrowLeft')show(index-1);else if(e.key==='ArrowRight')show(index+1);else if(e.key==='0')toggleActual();
  });
  box.addEventListener('click',function(e){
    var act=e.target.closest('[data-act]');
    if(act){var a=act.dataset.act;if(a==='close')close();else if(a==='prev')show(index-1);else if(a==='next')show(index+1);else if(a==='actual')toggleActual();return}
    if(e.target===img){toggleActual();return}
    if(!e.target.closest('.lightbox-foot, .lightbox-bar'))close();
  });

  setLang(pick(),true);
})();
"""

u0 = UI["en"]
LANGBAR = "<div class='langbar' role='group' aria-label='Language'>" + "".join(f"<button type='button' data-lang='{l}' aria-pressed='false' lang='{l}'>{LANG_NAMES[l]}</button>" for l in LANGS) + "</div>"
NAVS = "".join(f"<div class='nav-lang' data-lang='{l}' hidden>{nav_html(l)}</div>" for l in LANGS)
SEARCH = ("<div class='search'><svg viewBox='0 0 16 16' width='14' height='14' aria-hidden='true'><circle cx='7' cy='7' r='5' fill='none' stroke='currentColor' stroke-width='1.6'/><path d='M11 11l3.5 3.5' stroke='currentColor' stroke-width='1.6' stroke-linecap='round'/></svg>"
          f"<input id='nav-search' type='search' placeholder='{u0['search']}' aria-label='{u0['search']}' data-ui='search' autocomplete='off'>"
          "<button type='button' id='search-clear' class='clear' aria-label='Clear'>×</button></div>")
MENU_BTN = f"<button id='menu-toggle' class='menu-btn' aria-label='{u0['menu']}' aria-expanded='false'><svg viewBox='0 0 18 14' width='18' height='14' aria-hidden='true'><path d='M1 1h16M1 7h16M1 13h16' stroke='currentColor' stroke-width='1.8' stroke-linecap='round'/></svg><span data-ui='contents'>{u0['contents']}</span></button>"

PAGE = (f"<title>{u0['title']}</title>\n<style>{CSS}</style>\n"
        f"<header class='hero' id='top'><div class='hero-in'>"
        f"<div class='appicon'><img src='images/app-icon.png' alt='CNC G-Coder app icon' width='96' height='96'></div>"
        f"<div class='hero-text'><h1 data-ui='title'>{u0['title']}</h1><p data-ui='subtitle'>{u0['subtitle']}</p></div>{LANGBAR}</div></header>\n"
        f"{MENU_BTN}\n<div class='wrap'>\n"
        f"<aside id='sidebar' aria-label='{u0['contents']}'><p class='side-title' data-ui='contents'>{u0['contents']}</p>{SEARCH}<ul id='search-results' class='results' hidden></ul>{NAVS}</aside>\n"
        f"<div id='backdrop'></div>\n<main>{''.join(lang_block(l) for l in LANGS)}</main>\n</div>\n"
        "<script>" + JS.replace("__LANGS__", json.dumps(LANGS)).replace("__UI__", json.dumps(UI, ensure_ascii=False)).replace("__INDEX__", json.dumps({l: search_index(l) for l in LANGS}, ensure_ascii=False)) + "</script>\n")

SKELETON_HEAD = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n<link rel="icon" type="image/png" href="images/app-icon.png">\n'
def standalone(page):
    title, rest = page.split("\n", 1)
    return SKELETON_HEAD + title + "\n</head>\n<body>\n" + rest + "\n</body>\n</html>\n"

open(os.path.join(DOCS, "index.html"), "w", encoding="utf-8").write(standalone(PAGE))
open(os.path.join(DOCS, "artifact.html"), "w", encoding="utf-8").write(PAGE)   # no skeleton: for publishing as an artifact

# ---------------------------------------------------------------- in-app Help view (English)
def plain(md):
    t = re.sub(r"```\n?", "", md)
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", t)
    t = t.replace("`", "")
    lines = []
    for line in t.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if all(re.fullmatch(r":?-+:?", c) for c in cells): continue
            line = " — ".join(cells)
        elif line.startswith("- "):
            line = "• " + line[2:]
        elif line.startswith("  ") and line.strip():
            line = "   " + line.strip()
        lines.append(line)
    out = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return out.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')

def swift_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

def helpview_swift():
    """The in-app guide in all four languages. The language follows the app's
    localization (Bundle.main.preferredLocalizations) unless the picker at the
    top overrides it (UserDefaults `help.language`)."""
    parts = ['import SwiftUI', '',
             '/// The in-app user guide (⌘?, the Help menu, or the ? button), in every',
             '/// language the guide exists in. GENERATED from HELP*.md by docs/build.py —',
             '/// edit the Markdown, then run `cd docs && python3 build.py`.',
             'struct HelpView: View {',
             '    /// "" follows the app language; otherwise a code from `HelpGuide.languages`.',
             '    @AppStorage("help.language") private var language = ""',
             '',
             '    private var resolved: String {',
             '        if !language.isEmpty, HelpGuide.languages.contains(language) { return language }',
             '        let preferred = Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"',
             '        return HelpGuide.languages.contains(preferred) ? preferred : "en"',
             '    }',
             '',
             '    var body: some View {',
             '        let guide = HelpGuide.guides[resolved] ?? HelpGuide.guides["en"]!',
             '        ScrollView {',
             '            VStack(alignment: .leading, spacing: 18) {',
             '                HStack(alignment: .firstTextBaseline) {',
             '                    Text(guide.title)',
             '                        .font(.title.bold())',
             '                    Spacer()',
             '                    Picker("", selection: $language) {',
             '                        Text("System").tag("")',
             '                        ForEach(HelpGuide.languages, id: \\.self) { code in',
             '                            Text(HelpGuide.names[code] ?? code).tag(code)',
             '                        }',
             '                    }',
             '                    .labelsHidden()',
             '                    .frame(width: 140)',
             '                    .help("Language of this guide — System follows the app language")',
             '                }',
             '                ForEach(Array(guide.sections.enumerated()), id: \\.offset) { _, section in',
             '                    VStack(alignment: .leading, spacing: 6) {',
             '                        Text(section.title)',
             '                            .font(.headline)',
             '                        Text(section.body)',
             '                            .font(.callout)',
             '                            .foregroundStyle(.secondary)',
             '                            .fixedSize(horizontal: false, vertical: true)',
             '                    }',
             '                }',
             '            }',
             '            .padding(24)',
             '            .frame(maxWidth: 760, alignment: .leading)',
             '        }',
             '        .frame(minWidth: 560, minHeight: 480)',
             '    }',
             '}',
             '',
             'nonisolated struct HelpSection: Sendable {',
             '    let title: String',
             '    let body: String',
             '}',
             '',
             'nonisolated struct HelpGuideText: Sendable {',
             '    let title: String',
             '    let sections: [HelpSection]',
             '}',
             '',
             'nonisolated enum HelpGuide {',
             f'    static let languages = {json.dumps(LANGS)}',
             '    static let names: [String: String] = ' + "[" + ", ".join(f'"{l}": "{LANG_NAMES[l]}"' for l in LANGS) + "]",
             '    static let guides: [String: HelpGuideText] = [' + ", ".join(f'"{l}": {l}' for l in LANGS) + ']',
             '']
    for lang in LANGS:
        g = GUIDES[lang]
        parts.append(f'    static let {lang} = HelpGuideText(title: "{swift_str(g["title"])}", sections: [')
        for cid in ORDER:
            c = CH[lang][cid]
            if c["md"].strip():
                parts.append(f'        HelpSection(title: "{swift_str(c["title"])}", body: """')
                for line in plain(c["md"]).splitlines(): parts.append("        " + line if line else "")
                parts.append('        """),')
            for sec in c["sections"]:
                parts.append(f'        HelpSection(title: "{swift_str(SHORT[lang][cid] + " — " + sec["title"])}", body: """')
                for line in plain(sec["md"]).splitlines(): parts.append("        " + line if line else "")
                parts.append('        """),')
        parts.append('    ])')
    parts += ['}', '']
    return "\n".join(parts)

HELPVIEW = os.path.join(ROOT, "CNC G-Coder", "Views", "HelpView.swift")
if os.path.exists(HELPVIEW):
    open(HELPVIEW, "w", encoding="utf-8").write(helpview_swift())
    print("HelpView.swift regenerated")
print("ok:", ", ".join(f"{l} {len(search_index(l))} entries" for l in LANGS))
