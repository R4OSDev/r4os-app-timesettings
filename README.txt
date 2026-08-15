TIMESET.R4X
===========

TIMESET.R4X ist die Desktop-nahe Zeit- und Zeitzonenverwaltung.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\TimeSettings
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\TimeSettings\zig-out\TIMESET.R4X

Contract:
- R4XStart-Entry: `timeset_main`
- App-Klasse: `gui`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`,
  `R4STD:DATE_V1:1`, `R4STD:TIME_V1:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\TIMESET.R4X`
