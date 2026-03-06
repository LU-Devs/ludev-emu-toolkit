# Toolkit de Emulador Android

Scripts de apoyo para ejecutar y recuperar el emulador Android desde terminal.

## Comando principal

- Ruta completa (ejemplo): `C:\tools\ludev-emu-toolkit\emu.cmd`
- Si la carpeta donde vive `emu.cmd` esta en `PATH`, puedes usar solo: `emu`

## Acciones

- `emu init`
  - Prepara el entorno (PATH de usuario + perfil de PowerShell) y muestra un reporte de diagnostico.
- `emu doctor`
  - Ejecuta diagnostico (ruta del SDK, resolucion de comandos y `adb devices`).
- `emu list`
  - Muestra AVDs disponibles.
- `emu run`
  - Reinicia el stack (`adb/emulator/qemu`) y arranca en limpio (cold boot) usando prioridad por defecto (`Medium_Phone_API_35`, luego `Pixel_9_Pro`, luego el primero disponible).
- `emu run <AVD_NAME>`
  - Mismo flujo de reinicio completo, pero para un AVD especifico.
- `emu run <AVD_NAME> -ColdBoot`
  - Fuerza arranque limpio (comportamiento por defecto).
- `emu run -Fast`
  - Omite el reinicio completo y hace inicio rapido (reutiliza estado existente cuando aplique).
- `emu run <AVD_NAME> -Fast -ColdBoot`
  - Inicio rapido con AVD especifico, forzando cold boot si lo necesitas.
- `emu status`
  - Muestra ruta del SDK y `adb devices -l`.
- `emu stop`
  - Cierre elegante usando `adb emu kill`.
- `emu fix`
  - Cierra procesos trabados (`emulator/qemu/adb`) y vuelve a iniciar el AVD.
- `emu fix <AVD_NAME>`
  - Mismo flujo de recuperacion con AVD especifico.
- `emu kill`
  - Detiene procesos relacionados al emulador.

## Flujo recomendado

```bash
emu run
# Si falla:
emu fix
# Verificar:
emu status
# Cerrar bien:
emu stop
# Solo si esta trabado:
emu kill
```

## Preinstalacion recomendada (una sola vez)

```bash
emu init
```

Si una terminal no reconoce `emu` despues de eso, abrir una terminal nueva o ejecutar:

```powershell
. $PROFILE
```

## Fallback por ruta completa

Usa estos comandos si `emu` no se reconoce en una terminal:

```powershell
C:\tools\ludev-emu-toolkit\emu.cmd status
C:\tools\ludev-emu-toolkit\emu.cmd run
C:\tools\ludev-emu-toolkit\emu.cmd stop
C:\tools\ludev-emu-toolkit\emu.cmd fix
```

Si una terminal no reconoce `emu`, ejecuta `C:\tools\ludev-emu-toolkit\emu.cmd init` una vez y luego abre una terminal nueva (o corre `. $PROFILE`).

## Notas

- Usa el SDK desde `ANDROID_SDK_ROOT`, `ANDROID_HOME` o `%LOCALAPPDATA%\\Android\\Sdk`.
- Diseñado para Windows PowerShell.
- El script intenta iniciar el emulador con consola de arranque oculta cuando es posible, para mantener la salida mas limpia en terminales de VS Code.
