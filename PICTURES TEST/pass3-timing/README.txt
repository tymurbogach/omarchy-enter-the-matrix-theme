PICTURES TEST/pass3-timing — segunda pasada de timing, tras corte real en reboot

Motivo: en un reinicio real, "They changed something." se cortaba a mitad
de palabra (en la "i"). La pasada anterior (pass2-exit-timing) medía 2.9s
(reboot) / 3.3s (shutdown) en el sandbox, pero la ventana real de apagado
resultó más corta que eso.

Cambio (lib/derive-plymouth.py, solo constantes + comentarios):
- EXIT_FRAMES_PER_CHAR 2->1, EXIT_OPEN_PAUSE 5->0, EXIT_HOLD_PAUSE 20->8,
  EXIT_GAP_PAUSE 8->3. Nuevo total: reboot 2.0s, shutdown 2.3s (antes 2.9/3.3).
- Pedido explícito del usuario: "todo un poco más rápido, incluyendo todo".
  También se bajó el ritmo de boot (FRAMES_PER_CHAR 5->4, OPEN/HOLD/GAP
  60/120/60 -> 45/90/45) y GRANTED_HOLD/DENIED_HOLD 60->45. Boot pasa de
  23.8s a 18.6s de tipeo total.

reboot-line2-full.png: "They changed something." completo y legible en el
  sandbox con el nuevo timing (antes se habría cortado en un apagado real).
shutdown-line2-full.png: "Unplug him." completo y legible.

Sigue sin garantía: la ventana real de apagado/reinicio varía por máquina.
Esto reduce el riesgo (2.0-2.3s de diseño contra "un par de segundos"
reales), no lo elimina. Solo un reinicio real lo confirma del todo.
