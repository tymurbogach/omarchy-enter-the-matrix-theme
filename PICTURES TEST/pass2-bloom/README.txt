PICTURES TEST/pass2-bloom — halo de las letras (ítem 3 del plan)

Referencia: boot splash objective/wallpaperflare.com_wallpaper (1).jpg
("Follow the white rabbit."): halo prieto y brillante pegado a la letra que
decae hacia fuera, sin outline.

Iteración medida sobre line-boot-0.png (corte horizontal por mitad de letra,
48 px a la izquierda del centro del glifo, alfa del halo):
  0x5 (viejo):  imperceptible en pantalla, se veía plano.
  0x18 (primer intento): pico ~109, suelo ~70-90. Niebla plana sin borde
    brillante: los halos vecinos se funden en una sola bruma.
  0x8 (elegido): pico 163 junto a la tinta, cae a ~15 en 48 px de bake.
    Gradiente real: borde caliente que decae, como la referencia.

01-wake-blur-0x18.png: "Wake" con 0x18/0.65. Suavidad leve, sin brillo junto
  a la letra. Rechazado.
02-wake-blur-0x8.png: "Wake" con 0x8/0.7. Halo visible que sangra al negro
  alrededor de cada letra y decae hacia fuera. Aceptado, una sola capa (sin
  segundo halo interior: el sprite solo tiene opacidad, sin blend aditivo, y
  la capa simple ya convence junto a la referencia).

Constantes en lib/derive-plymouth.py:190-197, con el razonamiento medido en
el comentario. Sin outline/hollow: fuera de alcance, confirmado por Q&A.
