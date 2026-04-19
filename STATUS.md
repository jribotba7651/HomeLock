# HomeLock — Status de trabajo (handoff)

**Fecha:** 2026-04-19
**Repo vivo:** ~/repos/HomeLock (github.com/jribotba7651/HomeLock)
**Branch:** main

## 1. Hay dos copias de HomeLock
- `~/repos/HomeLock/` = copia VIVA (GitHub, la que trabajamos).
- `/Users/juanc.ribot/development/HomeLock/` = skeleton viejo (2026-01-04, un solo commit, mismo remote). Se puede borrar sin pérdida.

## 2. Trabajo completado: aislamiento Lutron

**Motivo:** El bridge Lutron Caséta satura y tira la conexión HomeKit de TODA la casa cuando hay muchas automatizaciones. Sin back-pressure en HomeKit. Lutron y Home Assistant lo reconocen públicamente.

**Cambios:**
- **HomeKitService.swift**: flag `shouldIgnoreLutron` (default true); `isLutronDevice` detecta por manufacturer Y model (Caseta/RA2/RA3); `filterOutlets` excluye Lutron y publica `hiddenLutronCount`; nuevo `refreshOutlets()`.
- **LockManager.swift**: `LockManagerError` ahora `LocalizedError` con `.lutronNotSupported`; `lockDevice` rechaza Lutron; en opt-in rutea ops por `LutronBridgeGatekeeper`; enforcer salta Lutron en default, usa gatekeeper en opt-in.
- **Services/LutronBridgeGatekeeper.swift** (NUEVO): actor que serializa ops, gap minimo 500ms, max concurrencia 1.
- **ContentView.swift**: `LutronHiddenBanner` naranja en Dashboard cuando hay Lutron ocultos, con boton "Show anyway".
- **SettingsView.swift**: bug corregido (usaba instancia duplicada de HomeKitService, ahora `.shared`); toggle "Ignore Lutron devices"; onChange -> refreshOutlets.

**Comportamiento:** Default -> Lutron invisible + banner + enforcer no los toca + Shortcuts rechaza. Opt-in -> aparecen pero todas las ops serializadas.

## 3. PENDIENTE

### Re-auditar seguridad/bugs
El audit previo corrio contra `/development/HomeLock` (skeleton viejo), describio archivos que NO existen en el repo real. Los hallazgos no aplican.

Pedirle a Claude: **"Re-audita ~/repos/HomeLock como el repo real, ignora el audit anterior"**.

### Ideas futuras
- Gatekeeper v2 con `HMAccessoryBridge.uniqueIdentifier` por bridge real (ahora usa key global).
- Telemetria antes de invertir mas.
- FAQ sobre requisito de mismo-subred del bridge Lutron.

## 4. Ignorar SourceKit noise
"No such module 'HomeKit'" / "Cannot find UIApplication" = falsos positivos del CLI sin iOS SDK. En Xcode compila bien.

## 5. Retomar
1. Leer este archivo.
2. Decidir: commit de Lutron primero o re-audit?
3. Pedir re-audit contra repo real.

**Diff stat:**
- ContentView.swift +42
- HomeKitService.swift +65 -3
- LockManager.swift +78 -17
- SettingsView.swift +14 -2
- Services/LutronBridgeGatekeeper.swift +118 (nuevo)
