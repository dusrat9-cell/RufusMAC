# RufusMac

Rufus para macOS, en Swift y con interfaz SwiftUI. Reimplementación nativa de lo que
Rufus hace en Windows: escribir ISOs híbridas y montar un USB instalador de Windows,
incluidas las dos cosas que macOS no sabe hacer solo (partir `install.wim` y quitar los
requisitos de Windows 11).

```bash
./build.sh          # compila RufusMac.app (solo Command Line Tools, sin Xcode)
open RufusMac.app
```

## Interfaz

La ventana replica el diálogo de Rufus: mismos bloques, mismos controles, misma
distribución.

- **Propiedades del dispositivo**
  - *Dispositivo* — discos externos con etiqueta, identificador y tamaño. Los internos
    y `/dev/disk0` no aparecen nunca.
  - *Selección de arranque* — la lista completa de Rufus: `No arrancable`, `MS-DOS`,
    `FreeDOS`, `Imagen de disco o ISO (seleccionar)`, `Syslinux 4.07`, `Syslinux 6.04`,
    `ReactOS`, `Grub 2.04`, `Grub4DOS 0.4.6a`, `UEFI:NTFS`, más `SELECT` para elegir el
    archivo (o arrastrarlo a la ventana).
  - *Formato de imagen* — ISO estándar o DD, solo cuando hay imagen cargada.
  - *Esquema de partición* / *Sistema destino* — MBR/GPT y BIOS o UEFI / Solo UEFI /
    Solo BIOS.
  - *Propiedades avanzadas* (plegables) — tamaño de partición persistente, listar discos
    USB, correcciones para BIOS antiguos, Rufus MBR con ID de BIOS.
- **Opciones de formato** — etiqueta del volumen, sistema de archivos (`FAT`, `FAT32`,
  `exFAT`), tamaño de clúster, y las opciones avanzadas: formateo rápido, etiqueta
  extendida con icono, comprobar bloques defectuosos con 1/2/4 pasadas.
- **Estado** — caja de estado, barra de progreso, `START` / `CLOSE` y los cuatro iconos
  del pie (sitio de Rufus, acerca de, opciones avanzadas, registro).

### La lista de arranque

Rufus **no descarga** estos cargadores: los lleva dentro de su propio binario, en
`res/` (`res/freedos/*`, `res/syslinux/ldlinux_v4.bss`, `res/grub/grldr.mbr`,
`res/grub2/core.img`, `res/uefi/uefi-ntfs.img`). La única descarga real que hace Rufus
es opcional: si la ISO trae una versión de Grub distinta a la suya, intenta bajar
`core.img` de `rufus.ie/files/grub/<versión>/`.

Aquí no se empaqueta nada: se descargan **esos mismos ficheros** del repositorio de
Rufus (GPLv3, el proyecto del que esto es un port) la primera vez, se cachean en
`~/Library/Application Support/RufusMac/loaders/` y luego se instalan en el USB.

| Entrada | Estado | Cómo |
|---|---|---|
| No arrancable | funciona | solo formatea |
| MS-DOS, FreeDOS | funciona | 27 ficheros de FreeDOS 1.4 + boot record FAT16/FAT32 de ms-sys |
| Grub 2.04 | funciona | `boot.img` en el MBR, `core.img` en el sector 1, `boot/grub/grub.cfg` |
| Imagen de disco o ISO | funciona | ISO de Windows, o escritura DD para ISO híbridas |
| Syslinux 4.07 / 6.04 | pendiente | necesita el instalador de Syslinux (mapa de sectores dentro de `ldlinux.sys`); Rufus lo porta en `src/syslinux.c` con `libfat` |
| Grub4DOS 0.4.6a | pendiente | el MBR está, falta `grldr`, que Rufus no publica en su repo |
| ReactOS | vía ISO | elige la ISO de ReactOS y se escribe tal cual |
| UEFI:NTFS | pendiente | necesita una segunda partición FAT con el driver de NTFS |

Los boot records de DOS son los bytes exactos de `rufus/src/ms-sys/inc`, convertidos a
blobs en `DosBoot.swift`; se escriben encima del BPB que acaba de crear `diskutil`, así
que la geometría y la etiqueta del volumen se conservan.

## Arquitectura

El binario es **a la vez la app y el motor privilegiado**. La GUI nunca escribe en el
disco: serializa el trabajo a JSON y se relanza a sí misma con

```
osascript -e 'do shell script "<app> --engine <job.json> <log.txt>" with administrator privileges'
```

El motor corre como root, escribe el progreso como líneas `valor<TAB>mensaje` en un log
temporal y la GUI lo sondea a 10 Hz. Así hay **un solo binario**, un solo prompt de
administrador y ninguna lógica duplicada entre interfaz y motor.

```
Sources/
  main.swift         despacho: --engine / --list / --info / --selftest / GUI
  App.swift          escena SwiftUI
  Views.swift        la ventana
  Theme.swift        paleta y controles con el aspecto de Rufus
  RufusModel.swift   estado, elevación, sondeo del progreso
  Engine.swift       el trabajo: montar, formatear, copiar, partir, expulsar
  WIM.swift          parser y splitter de WIM (puerto de wimlib split.c)
  DiskService.swift  diskutil
  IsoService.swift   hdiutil
  CLI.swift          modos de línea de comandos y autotest
```

Los desplegables son `NSMenu` reales colgados de un `Button` con el marco dibujado a
mano: `Menu` de SwiftUI no respeta la etiqueta personalizada y se degrada al típico
«⌄ título» de macOS.

## Lo que hace

| Función | Cómo |
|---|---|
| Detectar discos | `diskutil list/info -plist`, filtrado a externos |
| Formatear | `diskutil eraseDisk MS-DOS FAT16\|MS-DOS FAT32\|ExFAT … MBR\|GPT` |
| Copiar la ISO | `FileManager` con progreso por bytes |
| Partir `install.wim` | splitter propio, algoritmo de wimlib |
| Quitar requisitos Win11 | `autounattend.xml` con `RunSynchronous` |
| Arranque BIOS legacy | `etfsboot.com` como VBR preservando el BPB |
| ISO híbrida (Linux) | escritura cruda a `/dev/rdiskN` |
| FreeDOS / MS-DOS | descarga los ficheros de Rufus + boot record de ms-sys |
| Grub 2 | descarga `boot.img`/`core.img` y los coloca como MBR y PBR |
| Etiqueta extendida | `autorun.inf` + `autorun.ico` generado en código |
| Bloques defectuosos | lectura completa de `/dev/rdiskN` por pasadas |

### El splitter de WIM

Mismo algoritmo que `src/wimlib/split.c` de Rufus: los blobs de metadatos van a la
parte 1 y nunca fuerzan una parte nueva, el resto se copia **verbatim** en orden
secuencial y se abre parte al llegar al límite. Header de 208 bytes, entradas de tabla
de 50 bytes (`reshdr` 24 + `part` 2 + `refcnt` 4 + `sha1` 20), GUID compartido y
`boot_idx` solo en la parte 1.

## Verificación

```bash
./RufusMac.app/Contents/MacOS/RufusMac --selftest   # construye un WIM, lo parte y verifica SHA-1
./RufusMac.app/Contents/MacOS/RufusMac --list
./RufusMac.app/Contents/MacOS/RufusMac --info Win11.iso
./RufusMac.app/Contents/MacOS/RufusMac --engine job.json log.txt
```

El autotest genera un WIM sintético con el layout real, lo parte en varias piezas y
comprueba que cada blob siga hasheando a su SHA-1, que los offsets estén en rango, que
los metadatos queden solo en la parte 1 y que ninguna pieza pase de 4 GiB.

Probado además sobre discos virtuales (`hdiutil create`): formateo FAT16/FAT32/exFAT con
la etiqueta correcta, copia del árbol, `autounattend.xml` con las tres claves de
`LabConfig`, VBR con `eb5290` y BPB intacto, flag activo `0x80` en el MBR, `autorun.inf`
y un `.ico` que `file` reconoce como *MS Windows icon resource 16x16 32bpp*, y la
comprobación de bloques recorriendo el dispositivo entero.

## Limitaciones

- Sin NTFS ni UDF (macOS no los formatea sin software de terceros).
- El tamaño de clúster lo decide macOS: el desplegable se muestra pero está bloqueado.
- Sin partición persistente (el control existe y avisa de que se ignora).
- Arranque BIOS legacy (`--legacy`) es experimental: no probado en hardware real.
- Un `install.esd` (WIM solid/LZMS) no se puede partir; la app lo detecta y se detiene.
- Los cargadores embebidos de Rufus (MS-DOS, FreeDOS, Syslinux, Grub…) no están
  disponibles, por lo dicho arriba.

## Licencia

GPLv3, la misma que Rufus. El algoritmo de split viene de
[wimlib](https://wimlib.net) y [Rufus](https://github.com/pbatard/rufus).

Cualquier aporte o donacion : https://ko-fi.com/dusrat9

Este proyecto es una adaptación inspirada en la popular herramienta de código abierto **Rufus** (desarrollada originalmente por Pete Batard para Windows), con el objetivo de construir una solución funcional y nativa para entornos **macOS**.

## ⚖️ Créditos y Licencia (GNU GPLv3)

Este proyecto es de código abierto y se distribuye bajo la licencia **GNU General Public License v3 (GPLv3)**, en estricto cumplimiento con los términos del proyecto original.

* **Reconocimiento de Autoría:** Todo el crédito por el concepto original, algoritmos de validación y la excelencia técnica del ecosistema Rufus pertenece a **Pete Batard** (Copyright © 2011-2026 Pete Batard).
* **Derivación de Código:** En los módulos donde se ha adaptado o traducido lógica directa del repositorio original, se mantienen intactos los comentarios de derechos de autor y atribución correspondientes.

De acuerdo con la licencia GPLv3, este software es completamente libre: puedes modificarlo, distribuirlo y estudiar su código fuente, siempre y cuando cualquier versión derivada se mantenga bajo esta misma licencia abierta.


