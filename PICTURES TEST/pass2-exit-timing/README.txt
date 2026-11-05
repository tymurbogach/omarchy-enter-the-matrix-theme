PICTURES TEST/pass2-exit-timing — segunda línea de salida (ítem 2 del plan)

Problema: con el ritmo viejo el storyboard de reboot tardaba 245 frames
(4.9 s) y el de shutdown 271 (5.42 s); un splash real de salida vive un par
de segundos, así que la línea 2 no se veía nunca. No era bug de lógica
(storyboard/dispatch correctos), solo ritmo.

Ritmo nuevo (lib/derive-plymouth.py:180-183): EXIT_FRAMES_PER_CHAR=2,
EXIT_OPEN_PAUSE=5, EXIT_HOLD_PAUSE=20, EXIT_GAP_PAUSE=8. El --stage-only
reporta: reboot 35 steps / 2.9 s, shutdown 37 steps / 3.3 s (el extra sobre
el cálculo base lo pone el ritmo humano: mayúsculas y puntuación pesan).

Verificación: stage sin probe, preview-plymouth.sh --mode reboot / --mode
shutdown, ráfaga de 6 fotos en ~3 s. Sin garantía en un apagado real (la
máquina manda), pero la línea 2 ahora tiene una oportunidad real.

01-reboot-line1.png: "Déjà vu." completa y legible a ~0.4 s.
02-reboot-line2.png: "They changed something." completa y legible al final
  de la ráfaga (~2.9 s).
03-shutdown-line2.png: "Unplug him." completa y legible al final (~3.3 s).
Cada línea sigue legible, no es un parpadeo.
