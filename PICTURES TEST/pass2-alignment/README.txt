PICTURES TEST/pass2-alignment — fila del panel frente a la banda (ítem 1 del plan)

Qué se comprueba: que la fila viva (dashes de la passphrase) viaja con la
misma compresión vertical que la imagen horneada del panel (banda + cuadrados
de las esquinas), cuando el clamp de altura dispara en mx_box_h.

Sonda: stage copiado a scratch con probe añadido al final del .script
(mx_probe_refresh llama a refresh_callback + mx_password_callback("", 9) en
cada frame). Escenario: pausa 1.2 s, una foto. Sin sudo, sin tema instalado.

01-panel.png: panel "enter password" con 9 dashes. Los cuadrados flotan en la
  banda con aire arriba y abajo; la fila de dashes cae en la zona de
  contenido, sin derivar hacia el borde inferior del panel.
02-panel-zoom.png: recorte de la banda. Cuadrados huecos dentro de la banda,
  caption centrado en el tramo libre.

Cambio que lo sostiene (lib/derive-plymouth.py, solo ese fichero):
BOX_ROW_FRAC y BOX_PITCH_FRAC ahora se miden contra box_h (antes box_w) y el
template los aplica contra mx_box_h (antes mx_box_w). Sin clamp ambas bases
coinciden (box_h == box_w * BOX_ASPECT en derive), así que el caso normal no
cambia; con clamp la fila sufre el mismo squash vertical que el panel.
