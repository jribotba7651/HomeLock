# Session Notes — 2026-04-19

Continuación del security audit (PR #1). Se atacaron los TODOs #6, #7 y #8
que habían quedado pendientes al cierre del audit anterior.

## TODO #6 — Biometric domain state check

**Problema:** `LAContext` expone `evaluatedPolicyDomainState` (iOS ≤17) /
`domainState.biometry.stateHash` (iOS 18+), un hash opaco de la base biométrica
del device. Si un niño añade su propia Face ID / Touch ID al device después
de que el padre configuró HomeLock, puede desbloquear la app con su biometría
porque HomeLock confía en el device-owner authentication.

**Solución:**
- En `requestBiometricSetup`, tras éxito, guardamos snapshot del hash en
  Keychain con byte de versión (1 = API vieja, 2 = API nueva).
- En `authenticateWithBiometrics`, tras éxito, comparamos el hash actual vs
  el guardado.
  - Si **mismo formato y hash distinto** → `biometricDatabaseChanged`,
    `AuthenticationManager` desactiva biometría automáticamente y fuerza PIN.
    El padre debe re-habilitar biometría manualmente desde Settings (nuevo
    snapshot).
  - Si **formato distinto** (iOS 17→18 upgrade) → re-captura silenciosa,
    no es manipulación.
  - Si **no hay snapshot guardado** (build anterior) → captura ahora, no
    bloquea migración.
- `setBiometricEnabled(false)` borra el snapshot para que el próximo setup
  parta limpio.

**Archivos:** `Security/KeychainManager.swift`,
`Security/BiometricAuthManager.swift`, `Security/AuthenticationManager.swift`.

## TODO #7 — ChangePINView

**Problema:** `ChangePINView` era un cascarón: los 3 steps (current / new /
confirm) renderizaban `PINEntryView` pero este solo sabía autenticar contra
el PIN guardado, no capturar PINs nuevos. El step `.confirm` tenía
`// TODO implement` y simplemente dismiss.

**Solución:**
- `PINEntryView` ahora tiene dos modos:
  - `.authenticate(onSuccess:)` — comportamiento existente (verifica contra
    Keychain, maneja lockout, muestra biometric button).
  - `.capture(onCaptured:)` — captura 6 dígitos y los entrega crudos.
    Oculta biometric button y lockout UI, que no aplican.
- Nuevo `AuthenticationManager.changePIN(newPin:confirmation:)` — valida
  formato + coincidencia, guarda nuevo hash, resetea failedAttempts. No
  dispara el prompt de setup de biometría que `setupPIN` tiene (no aplica
  a cambios, solo a setup inicial).
- `ChangePINView` reescrito: step 1 usa authenticate mode (reusa lockout);
  steps 2 y 3 usan capture mode; si `commitPINChange` falla, vuelve al step
  `.new` con banner de error; si tiene éxito, banner verde y dismiss.
- El `.id(currentStep)` en la vista fuerza reset del `@State` interno del
  `PINEntryView` cuando se cambia de step (evita que el `pin` persista
  entre steps).

**Archivos:** `Views/Authentication/PINEntryView.swift`,
`Views/Settings/SecuritySettingsView.swift`,
`Security/AuthenticationManager.swift`.

## TODO #8 — CloudKit spoof prevention

**Problemas encontrados:**

1. **`lockedByName` spoofing:** `createSharedLock` aceptaba el nombre como
   parámetro del caller. Un participante malicioso del CKShare podía crear
   records atribuyendo el lock a otro padre.
2. **No había check de `creatorUserRecordID`:** `lockedByUserID` es un
   field user-writable que cualquiera puede poner. CloudKit SÍ pone
   automáticamente `creatorUserRecordID` (system field, no spoofable).
   No estábamos comparando los dos.
3. **`deleteLock` borraba locks ajenos:** un participante con permiso
   `.readWrite` en el CKShare podía borrar records de otros usuarios.

**Solución:**
- `createSharedLock` ya no acepta `lockedByName` — lo deriva internamente
  de `UIDevice.current.name`.
- `fetchLocks` filtra con `isRecordAuthentic(_:)`: descarta records donde
  `creatorUserRecordID.recordName != record["lockedByUserID"]`. Un
  participante malicioso puede intentar escribir el record, pero no puede
  pasarlo a los demás clientes porque el filter client-side lo elimina.
- `deleteLock` rechaza con `.notAuthorized` si el caller no es el
  `lockedByUserID` del record.
- `SharedLock` gana flag `isTrusted: Bool` para que la UI pueda
  diferenciar (actualmente CloudKitService solo retorna trusted=true
  porque filtra los otros, pero el flag queda explícito para el futuro).

**No hecho (pendiente futuro):**
- Roles diferenciados en `CKShare` (parent vs viewer). Requiere flujo de
  invitaciones que no encontré en el repo. Nota para v2.0.

**Archivos:** `Services/CloudKitService.swift`, `Models/SharedLock.swift`,
`LockManager.swift`.

## Bonus: debug Pro toggle

Añadido `StoreManager.debug_setProOverride(_:)` envuelto en `#if DEBUG`, y
una sección "Developer" en `SettingsView` (también `#if DEBUG`) con un
toggle "Force Pro". Permite testing de features Pro sin configurar sandbox
ni StoreKit config. No compila en Release — no llega al App Store.

Reset on app restart: el override vive en memoria y se pierde al relanzar.
Intencional para que no se quede pegado por olvido.

**Archivos:** `StoreManager.swift`, `SettingsView.swift`.

## Estado del build

- Compila en Xcode para iPhone Simulator (verified) y iPhone device
  (signing configurado con team 696M9GC74E, bundle
  `com.jibaroenlaluna.HomeLock`, iOS deployment target 26.2).
- Los errores de SourceKit en el CLI (`No such module 'HomeKit'`, `Cannot
  find KeychainManager`) siguen siendo ruido — Xcode compila limpio.
- 3 warnings no bloqueantes:
  - `UIRequiresFullScreen` deprecated iOS 26 (key vieja en Info.plist).
  - `url` never used (código muerto, no tocado).
  - `self` never used en un `if let self = self` del LockManager.

## Próximos pasos sugeridos

1. **Testing runtime** de los 3 fixes antes de archive. El simulator no
   tiene HomeKit real pero sirve para: PIN change flow, biometry setup
   (con simulated Face ID), debug Pro toggle.
2. Probar CloudKit con 2 Apple IDs distintos en 2 devices para verificar
   que el filter de `isRecordAuthentic` bota records forgeados.
3. Archive → TestFlight. Antes de subir, confirmar en App Store Connect
   que existe el in-app product `com.jibaroenlaluna.homelock.pro`.
4. Pendiente v2.0: roles en CKShare.

## Diff stat

```
HomeLock/LockManager.swift                         |   3 +-
HomeLock/Models/SharedLock.swift                   |   9 +-
HomeLock/Security/AuthenticationManager.swift      |  32 +++++++
HomeLock/Security/BiometricAuthManager.swift       |  60 ++++++++++++-
HomeLock/Security/KeychainManager.swift            |  34 +++++++
HomeLock/Services/CloudKitService.swift            |  95 ++++++++++++++------
HomeLock/SettingsView.swift                        |  18 ++++
HomeLock/StoreManager.swift                        |  11 +++
HomeLock/Views/Authentication/PINEntryView.swift   |  48 ++++++++--
HomeLock/Views/Settings/SecuritySettingsView.swift | 100 ++++++++++++---------
```
