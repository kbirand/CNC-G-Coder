# CNC G-Coder — Guía del usuario

*(Esta guía también está disponible dentro de la aplicación: ⌘? o el botón Help de la barra de herramientas.)*

## Visión general del flujo de trabajo

1. Exporte los archivos Gerber + taladrado desde EasyEDA o KiCad a una carpeta.
2. **Choose Folder** (barra de herramientas): las capas se detectan automáticamente por el nombre de archivo.
3. Ajuste sus herramientas, profundidades y avances (o cargue un **Preset**). La barra lateral muestra solo los ajustes del programa seleccionado; el menú de capas de su parte superior cambia a la vez la vista previa y los ajustes; elija allí **Machine setup** para los parámetros compartidos por todos los programas.
4. Inspeccione la vista previa: seleccione cada programa, reprodúzcalo, compruebe las profundidades en la vista lateral y la estimación de tiempo total.
5. **Generate**: elija (o cree con New Folder) la carpeta de destino; todos los programas `.ngc` se escriben allí.
6. Mecanice en orden: aislamiento del cobre frontal → taladros (un programa por archivo de taladrado; cambie de broca en las pausas M0) → voltee la placa → cobre posterior → corte del contorno (los puentes sujetan la placa) → rompa/lime las pestañas.
7. Máscara de soldadura: pinte la placa mecanizada con máscara UV, cúrela y ejecute `top-mask-etch.ngc` / `bottom-mask-etch.ngc` para despejar las aberturas de los pads.

Con un grabador láser en lugar de (o junto a) la fresadora: cada programa también puede exportarse como arte 1:1 (SVG, PDF o PNG); vea *Grabado láser y exportación de arte*.

## Carpeta del proyecto y detección

Las exportaciones de EasyEDA se reconocen por la extensión: `Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, máscaras `.GTS`/`.GBS`, serigrafías `.GTO`/`.GBO` y archivos de taladrado `.DRL`. EasyEDA divide los taladros en archivos PTH / PTH-via / NPTH; cada uno se convierte en un programa aparte, porque pcb2gcode acepta un archivo de taladrado por ejecución.

Las exportaciones de KiCad se reconocen por los nombres de capa de KiCad: `board-F_Cu.gbr` / `board-B_Cu.gbr` (cobre), `board-Edge_Cuts.gbr` (contorno), `board-F_Mask.gbr` / `board-B_Mask.gbr`, `board-F_Silkscreen.gbr` / `board-B_Silkscreen.gbr`, y `board.drl` o `board-PTH.drl` + `board-NPTH.drl`. Los archivos de pasta, fab, courtyard, cobre interno, mapa de taladros y job se ignoran. En el diálogo de taladrado de KiCad elija el formato **Excellon** (no Gerber X2) y use el mismo ajuste de origen en los diálogos de trazado y de taladrado (ambos con «drill/place file origin» o ninguno); de lo contrario los taladros quedan desplazados respecto al cobre. Las exportaciones hechas con «Use Protel filename extensions» también funcionan.

Generate pregunta dónde escribir los programas (el botón New Folder del diálogo crea un destino nuevo); la elección se recuerda hasta que cambie de proyecto. La vista previa en vivo usa una carpeta temporal y nunca toca sus archivos hasta que pulse Generate.

## Herramientas y fresas en V: lea esto primero

Cada diámetro que introduzca debe ser el **diámetro de corte efectivo a la profundidad de trabajo**, con la fresa exacta con la que mecaniza.

- **Fresas rectas / de extremo plano**: efectivo = diámetro impreso; introdúzcalo tal cual.
- **Fresas en V** (la elección habitual para aislamiento; las fresas rectas de 0,1 mm se parten con facilidad): el cono se ensancha con la profundidad:
  `efectivo ≈ punta + 2 × |profundidad de corte| × tan(semiángulo)`
  Para una punta de 0,1 mm a −0,06 mm: V 30° ≈ **0,13 mm** · V 60° ≈ **0,17 mm** · V 90° ≈ **0,22 mm**.
  Introducir el tamaño de la punta hace que cada pista sea más fina de lo diseñado y el aislamiento más estrecho de lo pedido, sin aviso alguno.
- **Verificación**: mecanice una placa de prueba (File → Generate Test Board…) y mida la pista de prueba de 0,2 mm. Si mide ~0,13 mm con una fresa V 60° introducida como 0,1, su diámetro efectivo es ~0,07 mm mayor que el introducido: corrija el parámetro, no el diseño.

- **Modo V-bit**: ponga **Bit → V-bit** en aislamiento, máscara o serigrafía e introduzca punta y ángulo; el ancho a la profundidad se calcula por usted (y sigue a la profundidad de corte).

## Placas de prueba

**File → Generate Test Board…** (⇧⌘T) corta una placa pequeña que responde a una pregunta sobre su instalación. Cada prueba tiene su propia fresa (**Bit**, de la Tool Library; se recuerda por prueba; por defecto la fresa de aislamiento del cobre, para la prueba de agujeros la de fresado de agujeros) y sus propios ajustes; la Z segura, la holgura de inmersión y el ancho de aislamiento vienen del proyecto. El resultado se escribe como `.ngc` junto a una leyenda `.txt` y se muestra en la vista previa como cualquier programa, de modo que puede reproducirse y enviarse a la máquina.

- **Parameter test board**: encuentra la profundidad de corte y el avance para el aislamiento de producción. Una cuadrícula de parches: las filas barren la **profundidad de corte** (de … a), las columnas barren el **avance XY**; cada parche tiene pistas de 0,2 / 0,3 / 0,4 mm. Cada pista va entre dos pads de prueba dentro de un foso de aislamiento cerrado, así que un multímetro en modo continuidad dice si la pista sobrevivió (pad a pad pita) y si el aislamiento está completo (pad al cobre circundante queda mudo). **Board size** y **Grid** (avances × profundidades) fijan la disposición; **Suggest** elige una cuadrícula para el tamaño de placa. La leyenda asocia cada parche con su profundidad y avance.
- **Backlash test**: mide la holgura en X e Y en una placa de 75 × 75 mm. Por eje, una línea recta se corta en dos mitades alcanzadas desde direcciones opuestas: un escalón donde se encuentran las mitades es la holgura de ese eje. Un cuadrado de 50 mm y un círculo Ø30 también la muestran: lados cortos, un óvalo. Introduzca el escalón en Machine setup → Backlash compensation y vuelva a cortar la prueba hasta que ambas líneas salgan rectas (vea *Compensación de holgura*).
- **Hole fit test**: encuentra el tamaño de agujero que ajusta a un pin. Cada **tamaño de agujero** que liste (filas) se fresa en varias **variantes** (columnas: el tamaño más una holgura en mm), como la producción fresa los agujeros: una espiral descendente desde la superficie y después un círculo de acabado. Empuje el pin en cada agujero de su fila y quédese con la variante que ajusta como desea; diseñe el agujero a ese tamaño. Fréselo con la misma fresa que la placa real.

## Proyectos

Un proyecto (`.cncproj`) es un **paquete** autónomo: el Finder lo muestra como un solo archivo, pero clic derecho → **Mostrar contenido del paquete** revela

```
Board.cncproj/
  project.json   parámetros (herramientas, profundidades, avances, origen…), roles de capa, guías, origen de cada archivo
  Layers/        los archivos Gerber y de taladrado en sí, sin cambios
```

Mueva o copie el proyecto por sí solo: nunca pierde sus capas. (Para enviarlo por correo, comprímalo antes; Mail lo hace automáticamente.) Al abrir un proyecto sus archivos se copian a una carpeta de trabajo privada, así que los originales no hacen falta y nunca se modifican.

- **File → New Project** (⌘N), **Open Project…** (⌘O), **Open Recent**, **Save Project** (⌘S), **Save Project As…** (⇧⌘S). Las mismas acciones están en el menú **Open** de la barra lateral. El título de la ventana muestra el proyecto y «Edited» cuando tiene cambios sin guardar; New, Open y Quit preguntan antes de descartarlos.
- **Open Gerber Folder…** (⇧⌘O) inicia un proyecto sin título desde una carpeta de exportación de EasyEDA o KiCad, detectando las capas por nombre de archivo, como antes.
- Las copias empaquetadas son las que usa el proyecto. Si vuelve a exportar los Gerber desde su editor de PCB, tráigalos con **Import Layer…** o **Replace…** (o abra la nueva carpeta de exportación) y guarde. **Show Original in Finder** en una capa señala el archivo del que se empaquetó, si aún existe.
- Los proyectos guardados por versiones anteriores (un solo archivo con las capas incrustadas, o con enlaces a ellas) siguen abriéndose y se convierten en paquete en el siguiente guardado.
- El Finder muestra el paquete como un archivo una vez ejecutada la aplicación (eso registra el tipo de proyecto); antes aparece como una carpeta llamada `….cncproj`.
- Abrir un proyecto sustituye los parámetros actuales por los del proyecto.

### Importar capas sueltas

**File → Import Layer…** (⌘I), o **Import Layer…** bajo Layer files en la barra lateral, añade archivos Gerber o Excellon desde cualquier sitio. El rol de cada archivo se deduce de su nombre (y el de los archivos de taladrado de su cabecera M48, se llamen como se llamen) y puede cambiarse en la hoja de importación antes de importar: un archivo de taladrado se añade como otro programa de taladrado; cualquier otro rol sustituye al archivo de ese hueco. Clic derecho en un archivo de capa de la barra lateral para **Replace…**, **Remove** o **Show in Finder**.

## Exportar un solo programa

Con una capa seleccionada, **CNC export → Export <nombre>.ngc…** en la barra lateral guarda solo ese programa: exactamente el G-code previsualizado, con el mismo posprocesado y origen que escribiría Generate. Está disponible en cuanto la vista previa está al día. El enlace «X0 Y0 at» junto a él salta al ajuste del origen.

## Grabado láser y exportación de arte

Cada programa que genera la aplicación —aislamiento del cobre, contorno, taladros, aberturas de máscara, serigrafía, capas personalizadas— puede exportarse como arte al tamaño físico real de la placa para un grabador láser: como trazados vectoriales (SVG, PDF) que un láser puede seguir, o como mapa de bits (PNG). Usos típicos: revelar una reserva de pintura o película sobre el cobre para el grabado químico, quemar las aberturas de la máscara una vez curada, y grabar la leyenda de serigrafía.

**Dónde.** Con un programa seleccionado, la sección **Laser export** al final de la barra lateral exporta ese programa (**Export <nombre>…**). Para exportar todos los programas de una vez, use **Generate → Produce: Laser artwork**, que escribe un archivo por programa en la carpeta de destino en lugar de G-code. Las opciones son las mismas en ambos sitios y se recuerdan.

- **Format**: SVG y PDF siguen siendo vectoriales: la trayectoria como trazados. PNG es un mapa de bits a la **Resolution** elegida (300, 600, 1000 o 2400 dpi); el dpi se escribe en el archivo para que el software láser lo coloque a su tamaño real. 1000 dpi resuelve una pista de 0,15 mm en unos 6 píxeles. Los tres salen al tamaño real de la placa.
- **Polarity**: *White on black*: el corte es blanco sobre fondo negro. *Black on white*: lo inverso. El fondo se dibuja en el archivo, así que la polaridad sobrevive a la importación en cualquier programa láser.
- **Frame**: lo que abarca la página. *Board*: la placa terminada, con el trazado de corte metido medio diámetro de fresa, de modo que una placa de 70 × 30 mm da una página de 70 × 30 mm alineable con el PCB físico. *Origin*: desde X0/Y0 hasta la esquina más lejana de todos los programas, así que colocar el archivo en 0,0 lo deja exactamente donde cortaría la fresadora. *Project*: esa misma página compartida, recortada a los programas. *Layer*: solo la extensión de este programa.
- **Ancho de herramienta**: con **Tool Width** activado en View Options, la trayectoria se barre al diámetro de la fresa, es decir, el cobre que la fresadora retiraría; desactivado, se exporta como simples líneas centrales. Los rápidos nunca se incluyen.

**Aberturas de máscara para ablación.** Solder mask → **Output: Laser SVGs** omite los programas de fresado de máscara y exporta en su lugar las formas de las propias aberturas (pads y vías) como SVG 1:1 mediante gerbv, listas para quemar la máscara curada donde se sueldan los componentes.

**Serigrafía.** Silkscreen → **Output: Engrave** convierte la leyenda en un programa (y por tanto exportable como arte); con Output desactivado la capa se ignora.

Lo que haga con el arte es su propio proceso; la aplicación no genera G-code láser ni ajusta la potencia del láser. Alinee el archivo según el Frame elegido: *Board* con el borde físico de la placa, *Origin* con el mismo X0 Y0 donde pone a cero la fresadora.

## Capas personalizadas: dibujar sus propias formas

**File → New Custom Layer** (⇧⌘N, también en el menú de capas de la barra lateral) añade una capa sobre la que dibujar: líneas y polígonos, rectángulos (con radio de esquina y rotación), círculos y texto, con la fuente de grabado de un solo trazo integrada o cualquier fuente instalada, grabado a lo largo de sus contornos. Cada capa no vacía se convierte en un programa, escrito por Generate y por la exportación CNC como cualquier otro, y mostrado en la vista previa, que se regenera tras cada edición.

**Dibujo.** Con la capa seleccionada, aparece una barra sobre la vista previa con las herramientas: Select (V), Line (L), Rectangle (R), Circle (C), Text (T). Haga clic o arrastre para dibujar; doble clic o Retorno termina una línea, hacer clic en su primer punto la cierra en un polígono; Mayús restringe a 45° y hace cuadrados. Los puntos se ajustan a la cuadrícula (Snap to Grid), a las guías y a esquinas, vértices, centros y cuadrantes de otras formas (Snap to Objects); un anillo verde muestra el ajuste. Arrastrar con el botón derecho o central desplaza la vista (también Opción-arrastrar), la rueda hace zoom como siempre. Los demás programas solo se ven tras el dibujo con All Layers Overlay activado (View Options).

**Edición.** Clic para seleccionar, Mayús-clic para añadir, arrastre un recuadro (hacia la derecha: formas contenidas; hacia la izquierda: formas tocadas). Arrastre las formas para moverlas —se ajustan entre sí— o arrastre los tiradores para redimensionar rectángulos y círculos y mover los vértices de una línea. Las flechas desplazan 0,1 mm (Mayús: 1 mm), ⌘D duplica, Suprimir borra, ⌘Z deshace todo. La barra lateral lista las formas; seleccionar una abre un panel Properties flotante a la derecha del dibujo con sus números —posición, tamaño, radio de esquina, rotación, texto, fuente, ancho de trazo— para valores exactos; con varias seleccionadas, **Align** (bordes y centros) y **Distribute** (huecos iguales) las alinean.

**Mecanizado.** Cada capa tiene una herramienta (de la biblioteca o tecleada), una profundidad, profundidad por pasada, avances y husillo, y una operación. *Engrave* lleva el centro de la herramienta por la línea dibujada; *Cut outside* / *Cut inside* desplazan las formas cerradas media herramienta para que lo dibujado sea el tamaño resultante (outside para una pieza que se conserva, inside para un agujero). Un ancho de trazo mayor que la herramienta se despeja con pasadas solapadas; *Filled* vacía una forma cerrada de dentro hacia fuera. Las formas se dibujan en coordenadas de diseño sobre la placa, así que mantienen su sitio sea cual sea el origen elegido, y una capa Back se refleja como el cobre posterior. Las capas personalizadas se guardan en el proyecto.

## Editar capas importadas

Cualquier archivo Gerber o de taladrado importado puede editarse en el sitio: seleccione un programa hecho a partir de él y pulse **Edit** en la parte superior de sus ajustes, o clic derecho en el archivo bajo **Layer files** → **Edit…**. El arte del archivo (pads, pistas, áreas rellenas o agujeros) se dibuja sobre su programa en la vista 2D.

- **Seleccionar**: clic, ⇧-clic para añadir, arrastre un recuadro (de izquierda a derecha contiene, de derecha a izquierda toca). ⌘A selecciona todo; **Select Similar** (la varita) añade cada pista del mismo ancho, pad de la misma apertura o agujero del mismo tamaño.
- **Cambiar tamaños de la selección** en el panel Properties: ancho de pista, diámetro de pad o ancho × alto, diámetro de agujero. Solo cambian los objetos seleccionados.
- **Cambiar un tamaño en todas partes**: mientras edita, la barra lateral lista las aperturas del archivo (Gerber) o las herramientas de taladrado (Excellon). Editar una fila redimensiona todo lo que la usa, p. ej. todas las pistas de 0,25 mm a la vez. El icono de diana las selecciona.
- **Mover** arrastrando o con las flechas (0,1 mm, ⇧ 1 mm); **Borrar** con ⌫. Los valores se confirman con Retorno.

Cada edición escribe una copia editada del archivo; el original nunca se modifica. Mientras edita, la barra lateral muestra solo los tamaños del archivo y pcb2gcode no se ejecuta: las trayectorias dibujadas bajo el arte son las de antes de editar. Pulse **Done** (o Esc sin nada seleccionado) y la vista previa se regenera una vez desde el archivo editado. Las ediciones están en el historial normal de deshacer (⌘Z), los archivos editados llevan un lápiz naranja, y guardar el proyecto empaqueta el archivo editado. Los pads de forma especial (macro) y las áreas rellenas pueden moverse o borrarse pero no redimensionarse.

## Biblioteca de herramientas

**File → Tool Library…** (⇧⌘L) guarda cada fresa que posee con sus datos de corte: forma (recta / esférica / en V), para qué se usa, diámetro o punta + ángulo, profundidad, profundidad por pasada (brocas: profundidad de picoteo), avances, husillo, solape de pasadas y, para brocas, el rango de tamaños de agujero que pueden taladrar.

- **Import FlatCAM…** lee una exportación de la base de herramientas de FlatCAM (Tools Database → Export, el `.TXT` JSON). Tool Target se corresponde con *Used for* (Isolation, Drilling, Milling/Cutout → Cutout, otros → General); la forma V conserva punta y ángulo; la tolerancia de taladrado de FlatCAM se convierte en el rango de agujeros. Reimportar actualiza las herramientas con el mismo nombre en vez de duplicarlas.
- Cada herramienta se dibuja a sus proporciones reales: un icono de perfil en la lista y un modelo 3D que gira despacio (arrástrelo para girarlo) con sus dimensiones clave en la parte superior del editor, el mismo modelo que usa la vista 3D.
- **Import…** / **Export…** mueven la biblioteca entre ordenadores: Export escribe toda la biblioteca como `.json`; Import lee ese archivo o una base de herramientas de FlatCAM. Las herramientas ya presentes (la misma herramienta o el mismo nombre) se actualizan, el resto se añade, así que los «bits on hand» de un proyecto siguen coincidiendo en la otra máquina.
- Cada grupo de ajustes tiene un menú **Tool** en su parte superior. Elegir una herramienta **copia** sus valores al grupo —como FlatCAM copia los datos de la base a un objeto—, así que aún puede afinar la capa. **Edited** aparece cuando los campos ya no coinciden con la herramienta; púlselo para restaurar los valores de la herramienta. **Custom** significa valores introducidos a mano.
- Avances o husillo a 0 («sin ajustar» en FlatCAM) dejan el valor propio de la capa sin cambios.

## Motores de trayectoria

Machine setup → **Toolpath engine** elige qué convierte los archivos Gerber y de taladrado en programas:

- **pcb2gcode**: el generador de código abierto consolidado. Está integrado en la aplicación (Contents/Helpers), así que no hay que instalar nada.
- **Native**: el motor propio de la aplicación: lee los archivos por sí mismo y calcula aislamiento, contorno con pestañas, taladrado (con las brocas disponibles), fresado de agujeros, grabado de máscara y serigrafía con la biblioteca de polígonos Clipper2. Se ejecuta dentro de la aplicación, lo que lo hace más rápido, y sigue las mismas reglas que pcb2gcode: pasadas repartidas uniformemente por el ancho de aislamiento, la línea central del contorno como borde de placa, pestañas en los bordes más largos.

Ambos escriben sus programas igual, así que cada ajuste (pausas, picoteos, holgura de inmersión, corte extra, alturas, orígenes) vale para cualquiera. Diferencias que puede notar: el motor nativo divide las profundidades exactamente (1,8 mm en pasadas de 0,6 mm son 3 pasadas; pcb2gcode hace 4 de 0,45 mm) y ordena los trazados por vecino más cercano.

## Generar programas

**Generate** (barra de herramientas, o el botón Generate de la barra lateral) abre el diálogo Generate.

- **Produce**: *CNC G-code* genera las trayectorias con los parámetros actuales y escribe los programas `.ngc`, exactamente los archivos que muestra la vista previa. *Laser artwork* genera los mismos programas y escribe cada uno como arte 1:1 para un grabador láser en lugar de G-code (los `.ngc` no se conservan); sus opciones Format, Polarity, Resolution y Frame son las descritas en *Grabado láser y exportación de arte*.
- **Destination**: la carpeta a la que van los archivos; **Choose…** abre el selector de carpeta (su botón New Folder crea una nueva). La carpeta se crea si no existe, y los archivos existentes con el mismo nombre se sustituyen. La sugerencia es `Generated_GCode` junto al proyecto; la elección se recuerda hasta cambiar de proyecto.
- Mientras se ejecuta, el diálogo lista las etapas (cobre frontal, cobre posterior, contorno, una por archivo de taladrado, máscaras, serigrafía, capas personalizadas) con su estado; **Cancel Run** se detiene tras la etapa en curso. Al terminar, **Open Folder** muestra la salida en el Finder, y la pestaña Log tiene la salida completa con los tiempos por etapa.

**Archivos de salida.** `front-copper.ngc`, `back-copper.ngc`, `outline.ngc`, un `<archivo de taladrado>.ngc` por archivo de taladrado (más `<archivo de taladrado>-milled.ngc` cuando Mill large holes está activado), `top-mask-etch.ngc` / `bottom-mask-etch.ngc`, `top-silkscreen.ngc` / `bottom-silkscreen.ngc`, y un programa por capa personalizada. Los programas de la cara posterior están reflejados y listos para ejecutarse tras el volteo; todos los programas comparten el origen elegido en Machine setup. La compensación de holgura (Machine setup) se aplica a estos archivos al escribirlos.

**El menú More** (… en la barra de herramientas): **Open Output Folder** muestra el último destino; **Copy pcb2gcode Command** copia al portapapeles la línea de comando exacta que ejecutó la aplicación, para ejecutar pcb2gcode usted mismo o para un informe de error; **New Custom Layer** y **Generate Test Board…** son los mismos que en el menú File.

## Parámetros

### Aislamiento del cobre
- **Tool diameter**: el diámetro *efectivo* a la profundidad de corte (vea «Herramientas y fresas en V» arriba), o elija **V-bit** e introduzca punta + ángulo.
- **Isolation width**: cobre total despejado alrededor de cada pista; el tiempo de mecanizado crece casi linealmente con él. 2–3× el diámetro de herramienta es un buen comienzo.
- **Cut depth**: la lámina de cobre tiene ~0,035 mm; −0,05…−0,08 mm atraviesa con margen. Más profundo ensancha los cortes en V y adelgaza las pistas.
- **Depth per pass**: alcanzar la profundidad de corte en varias pasadas iguales de como mucho esta profundidad. 0 = una pasada.
- **Pass overlap**: solape entre pasadas de aislamiento vecinas (50 % por defecto).
- Las pistas nunca se cortan: la primera pasada se desplaza hacia fuera; el aislamiento solo come el cobre sobrante circundante.

### Taladrado y corte
- **Cada archivo de taladrado tiene sus propios ajustes.** Seleccione un programa de taladrado (o su programa `… milled`) y los grupos Drilling, Bits on hand, Hole milling y Heights & direction muestran los valores de ese archivo; la cabecera nombra el archivo. Activar Mill large holes para el archivo NPTH, o dar al archivo de vías una profundidad menor, no cambia nada en los demás archivos de taladrado. Un archivo añadido al proyecto parte de los valores por defecto de taladrado (mostrados cuando no hay ningún programa de taladrado seleccionado) y conserva sus propios valores desde entonces; se guardan en el proyecto con el archivo. Aplicar un preset pone todos los archivos de taladrado en los valores del preset.
- Profundidades = grosor de placa + ~0,2 mm en la tabla de sacrificio (material de 1,6 mm → −1,8).
- **Peck depth**: taladrar por picoteos: tras cada uno la broca sale en rápido para evacuar virutas, vuelve justo por encima del fondo anterior y sigue en avance. 0 = una sola carrera.
- **Bits on hand**: marque las brocas de la biblioteca que posee. Cada agujero dentro del rango de una broca marcada se taladra con esa broca, así que un trabajo solo necesita esas brocas (un agujero de 0,915 mm va a la broca de 1,0 mm). Las brocas sin rango propio usan **Bit tolerance** (± alrededor de la broca). Los agujeros que ninguna broca cubre conservan su tamaño de diseño y el Log los nombra; los rangos siempre se pasan, porque sin ellos pcb2gcode redondearía *cada* agujero a la broca más cercana (un agujero de montaje de 3 mm taladrado en silencio a 1 mm).
- **Hole milling**: para agujeros mayores que cualquier broca que posea (p. ej. agujeros de montaje de 3–4 mm con una fresa corn de 2 mm y 2 filos). Active **Mill large holes**; los agujeros desde **Mill holes from** en adelante no se taladran sino que se cortan en círculos, en espiral descendente (movimientos helicoidales G2), en un programa `… milled` aparte que se ejecuta justo después de su programa de taladrado. La fresa de agujeros tiene su propio menú Tool (herramientas de corte y generales de la biblioteca), diámetro, profundidad, profundidad por pasada (por vuelta de la espiral), avances, husillo y pausa. El círculo se desplaza hacia dentro media fresa, así que los agujeros salen a su tamaño de diseño; la fresa debe ser menor que el agujero fresado más pequeño.
- El corte da vueltas de **Pass depth**; tiempo = vueltas × perímetro ÷ avance.
- **Bridges**: en las pasadas más profundas que Bridge Z la fresa se levanta y deja pestañas de sujeción (blancas en la vista previa) para que la placa no se suelte en la última vuelta. Grosor de pestaña = fondo de placa − Bridge Z. Rompa y lime tras mecanizar.

### Alturas de seguridad y holgura de inmersión
- **Safe Z**: altura de desplazamiento entre cortes; debe salvar las mordazas y el alabeo de la placa.
- **Plunge clearance**: los movimientos verticales son rápidos en el aire y en avance solo por debajo de esta altura: los descensos bajan en rápido hasta ella y luego se sumergen al avance Z; las retiradas suben en avance hasta ella y luego en rápido. Esto suele reducir el tiempo del programa a la mitad (pcb2gcode por sí solo hace todo el descenso en avance, y también las retiradas de taladrado). 0,2–0,5 mm es lo típico; debe superar el alabeo de la placa; 0 lo desactiva. La fresa siempre entra y sale del material al avance programado.
- **Milling direction** (Machine setup): Any deja que pcb2gcode elija el camino más corto; Climb o Conventional lo fija para cada programa de fresado (esto desactiva el acortamiento de caminos 2-opt, así que los programas se alargan un poco).
- **Rapid feed** (Machine setup): la velocidad G0 de su máquina, usada solo para las estimaciones de tiempo (FR Rapids de FlatCAM).
- **Heights & direction** (cada capa; también guardado por herramienta e importado de FlatCAM): el **Travel Z** y el **Tool-change Z** propios de la capa (la altura para la pausa de cambio de herramienta y el final del programa; Tool-change Z / End Z de FlatCAM), dejados vacíos para usar los valores de Machine setup, que aparecen en gris en el campo; **Extra cut** (aislamiento, máscara, serigrafía y capas personalizadas): cada contorno cerrado sigue más allá de su inicio esta longitud para que no quede ninguna rebaba donde se cierra el bucle; donde pcb2gcode encadena pasadas en un solo corte, la herramienta vuelve luego por la ranura, así que solo se recorta cobre ya cortado; **Milling direction**: valor por defecto de la máquina o propio de la capa; **Spindle**: horario (M3) o antihorario (M4). El fresado de agujeros usa las alturas de taladrado (se ejecuta en la misma pasada).
- **Spindle dwell** (cada capa, junto a su velocidad de husillo; también guardado por herramienta en la biblioteca e importado de la pausa de FlatCAM): pausa tras arrancar el husillo, para que esté a velocidad antes de cortar, y tras pararlo, antes de un cambio de herramienta. 0 = sin pausa. pcb2gcode escribe las pausas en milisegundos (`G04 P2000`), pero GRBL y LinuxCNC leen segundos, así que la aplicación escribe la pausa de cada programa en segundos (`G04 P2.000`). Las máquinas configuradas para pausas en milisegundos (algunas instalaciones Mach3) necesitan el valor ×1000.

### Grabado de la máscara de soldadura
Las capas `.GTS`/`.GBS` describen las *aberturas* (pads/vías que quedan expuestos). El modo de grabado CNC invierte la capa y vacía cada abertura con pasadas solapadas al 40 % → `top-mask-etch.ngc` / `bottom-mask-etch.ngc`.
- La herramienta de máscara no debe ser mayor que la abertura más pequeña (las menores se omiten; vigile el Log).
- **Clear width**: hasta dónde se vacía cada abertura hacia dentro. Por defecto (**Clear width from the mask layers** activado) la aplicación mide la abertura más ancha de los archivos de máscara y despeja la mitad y un poco más, de modo que cada abertura se despeja hasta su centro y no más; el pie muestra la abertura más ancha. Desactivado, introdúzcalo usted: debe ser ≥ la mitad de la abertura más ancha o el centro de las aberturas grandes queda cubierto, y los valores mayores ralentizan enormemente la generación.
- La profundidad de grabado solo necesita quitar la pintura curada, no el cobre.

### Grabado de la serigrafía
Las capas de serigrafía están desactivadas por defecto (grabarlas cuesta tiempo de generación y de mecanizado). **Output: Engrave** fresa los propios trazos de la leyenda —designadores, contornos y texto— que así quedan grabados en la placa: `top-silkscreen.ngc` / `bottom-silkscreen.ngc`, para ejecutar al final, después de la máscara. La sección tiene su propia herramienta (recta o en V), profundidad, **Clear width** (los trazos más anchos que la herramienta se despejan con pasadas solapadas), solape, avances y husillo. En cualquier caso la capa puede exportarse a un láser en cuanto exista un programa.

### Avances, husillo y alturas por capa
Cada grupo de ajustes termina con **Feeds & spindle** —avance XY, avance Z (inmersión), velocidad de husillo y pausa de husillo— y **Heights & direction** (Travel Z, Tool-change Z, Extra cut, Milling direction, sentido del husillo), descritos en *Alturas de seguridad y holgura de inmersión*. Elegir una herramienta del menú **Tool** copia los valores de la biblioteca al grupo; **Edited** aparece cuando los campos ya no coinciden con la herramienta.

## Vista previa

### Vista 3D

El selector **2D / 3D** sobre la vista previa muestra los programas en 3D: los cortes como líneas del color de cada capa, el desplazamiento del cabezal en amarillo tenue sobre la placa, y una placa FR4 translúcida de 1,6 mm dimensionada según el corte. Arrastre para orbitar, arrastre con el botón derecho o central (rueda) para desplazar, y rueda (o desplazamiento con dos dedos) o pellizco para hacer zoom.

- **Gizmo** (arriba a la derecha): las bolas X/Y/Z giran con la vista; pulse una para mirar a lo largo de ese eje: Z = arriba, −Z = abajo, −Y = frente, Y = atrás, X = derecha, −X = izquierda. Debajo: un menú con todas las vistas estándar, **Iso**, **Fit**, perspectiva/ortográfica y desplazamientos visibles o no.
- Con **All Layers Overlay** activado, cada programa se asienta sobre la placa física: los programas de la cara posterior aparecen sin reflejar en la parte inferior, así que puede orbitar para inspeccionar el reverso. Un programa solo se muestra tal como se mecaniza.
- La reproducción funciona como en 2D: la parte terminada del programa se resalta, y la **fresa que corta el programa** sigue a la herramienta a tamaño real: el cono de la fresa en V con su ángulo y punta, el diámetro de la fresa plana o de agujeros, una broca con su punta de 118°, todas sobre un vástago de 1/8″ (3,175 mm) de 38 mm con el anillo de profundidad coloreado de las fresas de PCB (V amarillo, fresa plana azul, broca roja, esférica morada). Gira en sentido horario mientras el programa se reproduce.

- Se muestra un programa a la vez (menú de capas en la parte superior de la barra lateral). Todos los programas comparten un origen por cara, así que el «All Layers Overlay» registra exactamente cobre, taladros y máscaras; active «Un-mirror Back Side» para superponer la cara posterior reflejada alineada con la frontal.
- **Colores**: colores por capa para los cortes; **amarillo discontinuo = desplazamiento del cabezal** (sin corte); **blanco = puentes de sujeción**; la banda translúcida bajo los cortes es el ancho real de la fresa («Tool Width» en el menú View Options).
- **Un-mirror Back Side** (menú View Options) deshace el reflejo de los programas posteriores para comprobaciones visuales de alineación; solo visualización; el G-code sigue reflejado y listo para la CNC. Desactivado, el reverso queda correctamente reflejado frente al anverso.

### View Options
El menú **View Options** sobre la vista previa activa lo que dibujan las vistas: **Tool Width** (la banda translúcida al diámetro real de la fresa; también decide si una exportación láser va barrida o en líneas centrales), **Rulers**, **Guides** y **Clear Guides**, **Snap to Grid** (⌘'), **All Layers Overlay**, **Un-mirror Back Side**, **Height Map** con su **exageración** (×1 … ×50), **Toolpath Lines**, **Drill Holes** (los agujeros como cilindros en 3D), **Material Removal** (los canales de corte y la máscara de cobre en 3D), **Machine Travel** (el área de recorrido de la máquina conectada, discontinua) y **Fit Machine Travel**.

**Guías.** Con Rulers y Guides activados, arrastre desde una regla hacia la vista para sacar una línea guía; arrastre una guía para moverla. Las guías ajustan el dibujo, la medición y el marcador de origen, y se guardan con el proyecto. Clear Guides las elimina todas.

**Botones del lienzo** (arriba a la izquierda de la vista 2D): acercar, alejar, ajustar (el doble clic hace lo mismo), fijar el origen con un clic, la cinta métrica y centrar en el origen.

## Reproducción y estimaciones

Simulación fiel a los avances mediante la barra de reproducción flotante: cada movimiento dura `longitud ÷ avance programado`. **1× real = 100 % de la velocidad de mecanizado**; el marcador de herramienta se desliza por cada movimiento, rápidos incluidos. La pestaña G-code resalta la línea fuente actual. Los tiempos por programa están en el menú de capas de la barra lateral; **Σ est.** debajo es el total. Los rápidos se suponen a 2000 mm/min (el G-code no lleva avance rápido).

## Vista lateral

Proyecciones X–Z / Y–Z o un **Profile** de Z frente a distancia, con líneas de referencia etiquetadas (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z está exagerada (la nota ×N indica cuánto); el desplazamiento por encima de zsafe se comprime en una banda superior fina para que las retiradas sigan visibles.

## Controles de la vista

Rueda / pellizco = zoom (anclado al cursor) · arrastrar = desplazar · doble clic / botón Fit = restablecer. El zoom y el desplazamiento sobreviven a los cambios de capa; las posiciones de los divisores de panel y todos los parámetros persisten entre arranques.

## Medición y deshacer

**Medir.** el botón de regla arriba a la derecha de la vista 2D (o M con la vista enfocada) activa la cinta métrica, en cualquier capa. Pulse dos puntos —o arrastre entre ellos— para leer la distancia, ΔX, ΔY y el ángulo. Se ajusta a esquinas de trayectoria, agujeros, formas dibujadas, el origen, guías y (con Snap to Grid) la cuadrícula; Mayús mantiene la línea horizontal, vertical o a 45°. Esc borra la medición y luego sale de la herramienta.

**Deshacer.** Edit → Undo / Redo (⌘Z / ⇧⌘Z) recorren un único historial para toda la aplicación: ediciones de parámetros, herramientas y presets aplicados, movimiento del origen, archivos de capa importados, sustituidos o eliminados, y cada edición de dibujo. Abrir otro proyecto inicia un historial nuevo.

## Pestañas G-code, Log y Console

Las pestañas sobre la vista previa cambian el área principal:

- **Toolpath**: la vista previa 2D/3D descrita arriba.
- **G-code**: el texto del programa seleccionado (el menú **File** de arriba elige cualquier programa generado). Durante la reproducción y mientras se transmite un programa, la línea actual se resalta y se mantiene a la vista. Los archivos de más de 8 MB muestran sus primeros 8 MB.
- **Log**: todo lo que pcb2gcode y el motor nativo imprimieron, paso a paso con tiempos; los avisos empiezan por `WARNING:`, los fallos por `ERROR:` y el error está al final. La versión de pcb2gcode y los archivos detectados se registran al abrir un proyecto. Cuando falla una vista previa, el panel ofrece **Show Log** y **Try Again**.
- **Console**: la consola de la máquina: cada línea enviada al controlador y recibida de él. **Show status reports** incluye los sondeos `?` y los informes `<…>` (varios por segundo; útil para diagnosticar, ruidoso en otro caso); **Clear** vacía la vista. El campo de comando envía una línea tal cual con Retorno (`$G`, `G0 X10`, `$/axes/x/max_travel_mm`…); un solo carácter como `!`, `~` o `?` se envía como byte en tiempo real; ↑ y ↓ recuperan comandos anteriores. El campo se bloquea mientras se ejecuta un programa.

## Presets y ajustes

**Presets** (barra de herramientas) guardan y recuperan conjuntos completos de parámetros —herramientas, avances, profundidades, alturas, origen—, útiles por material o por máquina. **Save Current as Preset…** da nombre a los valores actuales; elegir un preset lo aplica (y pone cada archivo de taladrado en los ajustes de taladrado del preset); **Delete Preset** elimina uno. Aplicar un preset se puede deshacer.

**Settings (⌘,)** tiene dos paneles:

### General
- **Language**: Sistema (sigue a macOS) o inglés, francés, español, turco, para la interfaz y la guía integrada. Surte efecto en el siguiente arranque. La ventana de la guía tiene además su propio menú de idioma.
- **Units**: Metric (milímetros) o Imperial (pulgadas). Cambia los números que lee y teclea: campos de parámetros, reglas, guías y la lectura de reproducción. Los programas generados siempre quedan en métrico (`G21`).
- **Preview refresh**: *Automatic* regenera la vista previa tras editar parámetros, cuando deja de teclear durante el **Delay after last edit**; *Manual* solo con el botón Refresh. La insignia «Out of date» marca una vista previa caducada en ambos casos.

### Machine
- **Connection**: Transport (telnet por Wi‑Fi para FluidNC, serie USB para cualquier controlador tipo Grbl, o el Simulator integrado), Host y Port, puerto serie y Baud (115200), intervalo de sondeo de estado (200 ms = 5 informes por segundo), reconectar automáticamente si cae el enlace, mostrar informes de estado en la consola, mostrar el Simulator en el selector de conexión.
- **Jog**: el avance y el paso con que arranca el panel, y la longitud de segmento para el jog continuo en firmware que no puede cancelar un jog largo.
- **Z probe**: avances rápido y lento, recorrido máximo, retirada, grosor de placa (los mismos valores que en la pestaña Probe).
- **Motion**: Z de trabajo segura para Go to Work Zero, Z segura bajo el tope del recorrido (también la altura de aparcado para cambios de herramienta), husillo mínimo y máximo para el botón Spindle del panel, calentamiento del husillo antes de reanudar.
- **Programs**: aplicar compensación de holgura al enviar, confirmar antes de continuar tras un cambio de herramienta, guardar el cero de trabajo al enviar un programa (una entrada Work en la pestaña Positions, con el nombre del programa y la hora; se conservan las 20 entradas automáticas más recientes), la ventana de envío (cuántos bytes sin confirmar permanecen en vuelo; 0 = automática: 128 por serie USB, 512 por Wi‑Fi, o el búfer de recepción que informa el controlador; súbala cuando los arcos y las esquinas redondeadas vayan más lentos que el avance por Wi‑Fi, deje una placa Grbl por USB en 128), la Z por debajo de la cual se aplica el mapa de altura.
- **Axis calibration (steps/mm)**: vea *Calibración de ejes* en Panel de máquina.

## Cero de máquina y trabajo a doble cara

**Machine setup → Origin → «X0 Y0 at»** decide dónde está el origen de máquina sobre la placa; cada programa lo comparte, un origen por cara. La vista lo marca con una cruz con anillo y flechas X roja / Y verde (siempre encuadradas por Fit).

- **Corners / Centre**: de todo el proyecto (la extensión de todos los programas) tal como la máquina ve cada cara: tras voltear, toca cero en la misma esquina del utillaje.
- **Custom point**: un punto en coordenadas de diseño (Gerber/EasyEDA), así que los tamaños de herramienta nunca lo mueven. Es el mismo punto físico en ambas caras, p. ej. un agujero de registro. Teclee Origin X / Y, o fíjelo en la vista (abajo).
- **Moverlo en la vista**: arrastre el marcador de origen a donde deba estar X0 Y0, o pulse **Set Origin in View** (Machine setup) / el botón de mira y pulse el punto. Ambos se ajustan a las esquinas y al centro del proyecto (lo que fija ese modo de esquina) y a los agujeros (un punto personalizado). Con **Snap to Grid** activado (View Options, o View → Snap to Grid, ⌘'), cualquier otro punto cae en la cuadrícula mostrada, así que el origen se mueve en pasos enteros de cuadrícula; acerque para una cuadrícula más fina.
- **Design origin**: sin cero; coordenadas exactamente como se exportaron.

Ponga a cero X/Y en el origen para los programas de la cara frontal (cobre, taladros, contorno, máscara superior), y una vez más tras voltear para los programas de la cara posterior: todo sigue registrado. Ponga a cero Z en la superficie de la placa. Elija la dirección de volteo con **Mirror around Y axis** y verifíquela con Flip Back View. El palpado y los mapas de altura se hacen en vivo desde el panel Machine (abajo); los programas en sí siguen siendo G-code simple.

## Compensación de holgura

GRBL y FluidNC no tienen ajuste de holgura, así que la aplicación puede compensar por sí misma el juego de los ejes X e Y. **Machine setup → Backlash compensation** guarda el juego por eje (mídalo con la placa de prueba de holgura). Los valores pertenecen a la máquina, no al proyecto: son globales de la aplicación y no se guardan en los archivos `.cncproj`.

- Con un valor fijado, cada programa que escribe la aplicación —Generate, la exportación CNC, placas de prueba— se reescribe: las coordenadas alcanzadas moviéndose en sentido negativo se desplazan el juego, se inserta un corto movimiento de recuperación de ese eje solo donde el eje invierte, los arcos se dividen en sus extremos X/Y, y el primer rápido recibe una entrada desde abajo. La vista previa y la pestaña G-code muestran siempre el programa sin compensar.
- **Compensate a G-code File…** escribe una copia compensada de un programa hecho fuera de esta aplicación.
- Al enviar desde el panel Machine, el conmutador **Backlash compensation** de la pestaña Program (por defecto según Settings → Machine → *Apply backlash compensation when sending*) reescribe la copia que se transmite; los archivos en disco no se tocan.
- Los programas con G91 (movimientos relativos), G20 (pulgadas), arcos en formato R, G28/G53/G92 o ciclos fijos se dejan sin compensar, con un WARNING en el Log.
- Vuelva a poner los valores a 0 cuando repare la máquina: corregir el juego mecánicamente siempre es mejor.

## Panel de máquina

El botón **Machine** de la barra de herramientas (View → Machine Panel, ⇧⌘M) abre un panel a la derecha de la ventana principal: un emisor nativo para controladores GRBL 1.1 y FluidNC. La franja de conexión y la lectura de posición se quedan arriba; las pestañas de debajo (Control, Positions, Program, Probe, Height Map, Macros) se desplazan por su cuenta; un **E-STOP** rojo bajo la lectura permanece visible en todas las pestañas; la consola es la pestaña Console de la ventana principal, y «Open in a window» en la parte superior del panel da a los mismos controles una ventana propia con el texto del programa.

### Conexión
Elija **Wi‑Fi** (la IP del controlador y el puerto telnet, 23 por defecto) o **USB** (un puerto `/dev/cu.*` a 115200) y pulse Connect. La píldora de estado muestra Idle / Run / Jog / Hold / Alarm…, la insignia el firmware que identificó la aplicación (`$I`), y las alarmas aparecen descodificadas con Unlock / Home / Reset. Las alarmas que pierden la posición (finales de carrera, un reset en movimiento) marcan la posición como no fiable: haga Home, o pulse Unlock para conservar la posición tal cual. La conexión convive con otros clientes (un mando en el mismo controlador sigue funcionando).

### DRO, cero, posiciones
Coordenadas de trabajo y de máquina, avance y husillo en vivo, el búfer del planificador y las entradas activadas (P = entrada de palpador cerrada). Pulse un valor de eje para fijar o poner a cero ese eje; la rejilla de botones de debajo tiene **Zero XY / Zero Z / Zero All** (`G10 L20 P0`, persistente) y **Probe Z** (el palpado en dos pasadas de la pestaña Probe) en la primera fila, **Work Zero** (sube primero a la Z de trabajo segura), **Safe Z** (justo bajo el tope del recorrido Z), **Home** y **Unlock** en la segunda. La pestaña **Positions** guarda posiciones de máquina con nombre; **Go to coordinates…** se mueve a un destino de máquina tecleado (Z primero al subir, al final al bajar). **Save work zero** guarda dónde está el X0 Y0 Z0 de trabajo en coordenadas de máquina, y **Use as zero** en cualquier entrada restablece el origen de trabajo en ese punto (`G10 L2 P0`, sin movimiento): para restaurar un cero tras un reset o un nuevo homing. Los **User buttons** de la pestaña Control ejecutan las macros de la pestaña Macros (un botón por macro, icono SF Symbol opcional; «allow while running» mantiene un botón activo durante un trabajo, para comandos cortos como el refrigerante). **E-STOP** (también al final de la barra de trabajo, y ⇧⌘.) envía cancelación de jog, feed hold y soft reset de una vez sin esperar nada; la posición se marca como no fiable si la máquina se movía. ⌘. sigue siendo la parada controlada.

### Jog y overrides
Toque un botón de jog para un paso; mantenga pulsado para un movimiento continuo que se detiene al soltar (en un FluidNC referenciado con límites por software el jog corre hasta el límite y se cancela al soltar; en otro caso se transmiten segmentos cortos). Los botones diagonales mueven dos ejes. **Jog por teclado**: flechas = X/Y, Re Pág/Av Pág = Z, Mayús = paso ×10, Esc o ⌘. = parar. Los overrides ajustan el avance (10–200 %, en pasos de 1 y 10), los rápidos (25/50/100 %) y la velocidad del husillo en tiempo real; el controlador informa del valor que está usando.

**Controles de máquina** (pestaña Control): **Reset** (soft reset Ctrl‑X: detiene todo; la posición se pierde si la máquina se movía), **Hold** / **Resume** (feed hold, cycle start), **Check** (`$C`: el G-code se analiza pero nada se mueve), **Spindle** encendido/apagado a las rpm de al lado (acotadas al mínimo y máximo de Settings → Machine), **Coolant** (M8/M9), y bajo More: **Sleep**, **Safety Door**, y las consultas `$G` (estado del analizador), `$#` (desplazamientos) y `$I` (información de compilación), cuyas respuestas aparecen en la Console.

### Pestaña Positions
Posiciones de máquina con nombre en dos listas, elegidas con el selector **Machine / Work**. **Machine** guarda los puntos a los que vuelve el husillo: **Save current…** guarda las coordenadas de máquina donde está ahora el husillo, **Go to…** se mueve a una coordenada de máquina tecleada, y cada entrada tiene **Go** (Z primero al subir, al final al bajar, al avance de jog). **Work** guarda ceros de trabajo, es decir, dónde estaba el X0 Y0 Z0 de trabajo en coordenadas de máquina: **Save work zero** guarda el actual a mano, y con *Save the work zero when a program is sent* (Ajustes → Machine, activado por defecto) cada envío registra uno automáticamente, con el nombre del programa y la hora ("Front copper – 8 Oct 14:07", icono de reloj). **Use as zero** en una entrada Work vuelve a convertir ese punto en el origen de trabajo con `G10 L2` (la máquina no se mueve), de modo que tras un choque, un reset o un homing el mismo cero vuelve sin palpar de nuevo. Clic derecho en una entrada para **Rename…**, **Overwrite with Current Position** / **Current Work Zero**, **Go There…** / **Use as Work Zero…** de la otra lista, y **Delete**. Las macros pueden ir a una posición guardada con `@goto <nombre>`.

### Pestaña Program: envío
Elija una capa generada (o CNC export → **Send … to Machine…** en la barra lateral), u **Open .ngc file…** para un programa externo (una placa de prueba, por ejemplo). **Backlash** y **Apply height map** transforman la copia que se envía, nunca los archivos en disco; **Save sent program…** conserva esa copia. **Verify** transmite el programa en modo check sin movimiento. Si el recorrido de la máquina no puede contener el programa, la barra de trabajo lo dice con todas las letras —por ejemplo que la línea 12 sube a una Z por encima del tope del recorrido porque el Z0 de trabajo está cerca del tope—; cuando ese es el único problema, **Clamp Z to top** vuelve a preparar el programa con esas alturas de retirada bajadas justo bajo el tope (las profundidades de corte no se tocan; una insignia naranja «Z clamped» se muestra mientras está activo) para poder hacer una prueba en vacío. **Send** lo transmite con conteo de caracteres; los lienzos de la ventana principal, la vista lateral, la vista 3D y la pestaña G-code siguen el trabajo, una cruz azul marca la posición real de la máquina, y la barra de trabajo muestra la línea, el tiempo transcurrido y el restante. Hold/Resume y los overrides siguen activos. **Stop** hace hold, resetea cuando la máquina está parada y apaga el husillo.

Los cambios de herramienta (tamaños de broca adicionales) suspenden el trabajo antes del cambio: husillo apagado, Z aparcada arriba, y un cartel nombra la broca. Jog, Zero y **Probe Z** están activos durante la suspensión para palpar la nueva broca, y después **Continue**, que reanuda de inmediato; el cartel lista las líneas de preámbulo que enviará (Settings → Machine → *Confirm before continuing after a tool change* recupera la hoja de confirmación). **Send from line…** reanuda a mitad de programa con un preámbulo seguro (retirada, husillo, rápido sobre el punto, inmersión), siempre mostrado para confirmación. La aplicación pregunta antes de cambiar de proyecto, desconectar o salir mientras se ejecuta un trabajo.

### Pestaña Probe
Un palpado Z en dos pasadas: bajada rápida hasta encontrar contacto, retroceso de 1 mm, bajada lenta hasta el punto exacto; el origen de trabajo activo se fija entonces en el punto de contacto (`G10 L20`; la pasada lenta se detiene a un micrómetro del disparo) y se relee del controlador: el DRO muestra entonces la altura de retirada, con Z0 en la superficie. Grosor de placa 0 = pinza en el cobre y la broca como palpador; introduzca el grosor para una placa de contacto. Settings → Machine guarda los avances, el recorrido máximo y la retirada.

### Calibración de ejes (pasos/mm)

Si un jog de 10 mm mueve el husillo 9,85 mm, los pasos/mm del controlador están mal. Settings → Machine → **Axis calibration** (FluidNC, conectado) lee `axes/x|y/steps_per_mm` y el nombre del archivo de configuración del controlador. Mida con un reloj comparador o una regla: haga jog un poco en la dirección de medida primero (recupera la holgura), ponga el reloj a cero, haga jog una distancia conocida —cuanto más larga mejor— e introduzca la ordenada y la medida; nuevos pasos/mm = actual × ordenada ÷ medida. **Apply** escribe la configuración en ejecución al instante (`$/axes/x/steps_per_mm=…`) y, con el conmutador de guardado activado, `$CD=<archivo de config>` reescribe ese archivo (p. ej. `raptorex.yaml`) desde la configuración en ejecución para que el valor sobreviva al reinicio. Vuelva a medir después; las medidas que difieren en más de unas centésimas apuntan a holgura o a una polea floja, no a los pasos/mm.

### Pestaña Macros
Sus propias secuencias de comandos. **Add** crea una macro con un nombre, un icono SF Symbol opcional (`fan.fill`, `drop.fill`, `house`…) y las líneas de G-code que envía; **Run** envía las líneas una tras otra esperando cada confirmación (la máquina debe estar conectada y en reposo); **Edit**, y con clic derecho **Duplicate** y **Delete**; **Restore Defaults** sustituye la lista por los ejemplos integrados. Cada macro es también un **user button** en la pestaña Control; *allow while running* mantiene un botón activo durante un trabajo, para comandos cortos como el refrigerante. `@goto <posición>` en una línea va a una posición guardada de la pestaña Positions.

### Pestaña Height Map
Defina una cuadrícula sobre la placa (**Auto** la ajusta al programa seleccionado), **Probe** la palpa y lee la desviación. Los mapas son por cara y se guardan relativos a la Z palpada en el origen de trabajo, así que volver a palpar Z allí tras un cambio de herramienta los mantiene válidos. Con **Apply height map** activado, cada corte e inmersión baja de la copia transmitida se deforma según la superficie medida (interpolación bilineal); los rápidos a altura segura no se tocan. Si el origen de trabajo se movió desde el palpado, la aplicación avisa antes de aplicar. Los mapas se guardan por proyecto en Application Support y pueden guardarse/cargarse como JSON; View Options → Height Map muestra los puntos sobre la trayectoria.

### Probar sin máquina
Active **Show the Simulator in the connection picker** en Settings → Machine, elija **Simulator** en la barra de conexión y pulse Connect: la aplicación arranca un simulador FluidNC integrado (`fake-grbl.py`, incluido; necesita python3 de las herramientas de línea de comandos de Xcode) en un puerto privado y habla con él como con un controlador real: movimiento en tiempo real, alarmas, suspensiones por cambio de herramienta, palpado Z contra una superficie sintética 1 mm bajo el cero de trabajo, mapas de altura. Su cero de trabajo está preajustado para que los programas de ejemplo quepan en el recorrido. La píldora de estado lleva una etiqueta **SIM** y la insignia dice Simulator; Disconnect o salir lo detiene. (Dev: `-debugMachineWindow 1 -debugMachineConnect sim`.)

## Solución de problemas

- **Falta pcb2gcode** → solo en compilaciones hechas sin él; el motor nativo toma el relevo (Machine setup → Toolpath engine). Las compilaciones normales llevan pcb2gcode dentro de la aplicación: nada que instalar.
- **Falló la vista previa** → la pestaña Log tiene la salida completa con tiempos por paso; el error está al final.
- **Huecos sin cortar entre pistas cercanas** → herramienta demasiado ancha para pasar; pcb2gcode avisa en el Log. Reduzca el diámetro efectivo de la herramienta o aumente la separación del diseño.
- **Abertura de máscara sin despejar** → abertura menor que la herramienta de máscara, o Clear width introducido a mano < mitad de la abertura (vuelva a activar «Clear width from the mask layers»).
- **Generación lenta** → Clear width de máscara demasiado grande, o ancho de aislamiento muy grande.

## Atajos de teclado

| Acción | Teclas |
|---|---|
| New Project / Open Project… / Open Gerber Folder… | ⌘N / ⌘O / ⇧⌘O |
| Save Project / Save Project As… | ⌘S / ⇧⌘S |
| Import Layer… / New Custom Layer | ⌘I / ⇧⌘N |
| Generate Test Board… / Tool Library… | ⇧⌘T / ⇧⌘L |
| Deshacer / Rehacer | ⌘Z / ⇧⌘Z |
| Seleccionar todas las formas / Duplicar formas | ⇧⌘A / ⌘D |
| Snap to Grid | ⌘' |
| Panel de máquina / Parada de emergencia | ⇧⌘M / ⇧⌘. |
| Ajustes / Ayuda | ⌘, / ⌘? |
| Herramientas de dibujo (capa personalizada, vista enfocada) | V seleccionar · L línea · R rectángulo · C círculo · T texto |
| Cinta métrica / salir de la herramienta | M / Esc |
| Desplazar las formas seleccionadas | Flechas 0,1 mm · ⇧Flechas 1 mm |
| Jog de máquina (Keyboard jog activado) | Flechas X/Y · Re Pág/Av Pág Z · ⇧ paso ×10 · Esc o ⌘. parar |
| Historial de la consola | ↑ / ↓ |
