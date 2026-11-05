PICTURES TEST/pass4-exit-root-cause — por qué el timing de salida se rompió

El usuario confirmó: reboot/shutdown eran perfectos ANTES del rediseño de
hoy (sin cortes nunca), y boot (login) sigue bien con el ritmo humano nuevo.
Después de mi segundo ajuste (EXIT_FRAMES_PER_CHAR=1, pausas casi a cero),
el reboot terminaba con 1-2s de sobra: ya no se cortaba, pero ahora sobraba.

Causa real, confirmada contra el commit 92e0a46 (el último antes de hoy):
- El original NO tenía keystroke_frames(): storyboard() usaba
  `steps.append((index, n, per_char))`, plano, igual para todos los modos.
- El nuevo tipeo humano (keystroke_frames, para el ritmo de boot) se
  conectó a TODOS los modos, incluida la salida. Eso añade peso extra por
  mayúscula/puntuación que el timing de salida nunca tuvo cuando se probó
  como "perfecto" -- por eso empezó a cortarse aunque EXIT_FRAMES_PER_CHAR
  no había cambiado a mano todavía.
- Perseguir el corte bajando las constantes (3->2->1) compensaba el peso
  extra en vez de quitarlo, y terminó sobrecorrigiendo (demasiado rápido).

Arreglo real: storyboard() aplica keystroke_frames() solo si mode=="boot".
Los modos de salida vuelven a ser per-char plano, exactamente como en
92e0a46. Las constantes EXIT_* vuelven a sus valores originales
(3/10/50/25), los mismos que el usuario ya probó como perfectos.

Medido ahora (--stage-only): reboot 4.6s, shutdown 4.7s -- muy cerca del
primer valor medido en este sesión (4.9s/5.42s), que YA incluía por error
el peso de keystroke_frames(). La diferencia confirma cuánto peso añadía.

Nota para el futuro: el sandbox de tools/preview-plymouth.sh (renderer X11)
corre mas rapido que los 50fps que asume el diseño (confirmado antes en
esta sesión). El Plymouth real en el arranque/apagado de esta máquina NO
mostró ese mismo adelanto -- el timing "perfecto" original y el medido
ahora con el mismo método coinciden. Para afinar el timing de salida,
confiar en un reinicio real, no en el sandbox.
