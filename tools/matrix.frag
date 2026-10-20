#version 440

// Digital rain for the matrix theme.
//
// Started from bjarneo/quickshell's `matrix.frag` (MIT,
// https://github.com/bjarneo/quickshell): the cell structure, the per-column
// offset hashed from the id and the scanlines all come from there.
//
// Changed from the original: that one drew procedural 3x5 pixel blocks. Here an
// atlas of the real halfwidth katakana is sampled instead -- exactly the ones
// `ttfx matrix --rain-symbols` uses, the effect behind Omarchy's screensaver.
// The colours are its own too (--highlight-color and --rain-color-gradient),
// and the head goes at the BOTTOM, which is where ttfx puts it ("color for the
// bottom of the rain column").

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float iTime;
    vec2 iResolution;
    vec4 colBg;
    vec4 colHead;
    vec4 colRainA;
    vec4 colRainB;
    float cellH;
    // The three below sit AFTER cellH on purpose. A vec4 aligns to 16 bytes in
    // std140, so slipping a float in among the colours moves every colour that
    // follows it and the rain comes out in the wrong palette.
    float dpr;
    float period;
    float birth;
};

layout(binding = 1) uniform sampler2D atlas;

const float ATLAS_COLS = 8.0;
const float ATLAS_ROWS = 7.0;
const float GLYPHS = 50.0;

// One cycle is the screen plus this many rows, so a trail is always completely
// gone before its column is allowed to start again.
const float TAIL_MAX = 36.0;

float hash11(float n) {
    return fract(sin(n) * 43758.5453);
}

float hash12(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Everything one column is doing right now, worked out from its x and the clock
// alone. Called for the fragment's own column and for its two neighbours: that
// is what lets the head's glow spill sideways instead of stopping dead at a
// cell edge.
void column(float cx, float span, out float head, out float tail,
            out float dim, out float alive) {
    // The speed is quantised so that k whole cycles fit into exactly `period`
    // seconds. That is the entire trick behind wrapping the clock invisibly:
    // every column is periodic with `period`, so the wrap changes nothing.
    // A cycle therefore lasts period/k, whatever the screen is: `speed` scales
    // with `span`, so the two cancel.
    //
    // The unavoidable consequence is that the WHOLE FIELD repeats every
    // `period`, and there is no way round it in a shader with no state: a rain
    // that never repeats needs speeds that are not commensurate, and those give
    // the clock nowhere to wrap. So the repeat is pushed out of sight instead.
    // `k` and `period` scale together -- speed is k*span/period and a cycle is
    // period/k, so multiplying both by 30 leaves the rain looking identical and
    // only moves the repeat from every 2 minutes to every hour. It also buys
    // 601 distinct speeds instead of 21, and lets mod(cycle, k) run through
    // hundreds of variants of a column before it comes back round.
    //
    // An hour is where this stops, not where it stops being nice: `travel` is
    // computed in float32, and at period 3600 its quantum is 0.017 of a row.
    // Doubling the period doubles that, and the fall eventually judders.
    float k = 300.0 + floor(hash11(cx * 1.31 + 0.7) * 601.0);
    float speed = k * span / period;

    // The offset is spread across the column's WHOLE run of k cycles, and that
    // is not a detail to tune -- it is the one thing holding the field apart.
    // Every cycle length divides `period` exactly, so any clustering of these
    // offsets does not wash out: it comes back, in full, at every wrap.
    //
    // Written down because it shipped wrong. This used to be the cold start's
    // stagger, which put every column within 2.2 s of every other, and the
    // whole field then re-aligned every `period` -- the screen emptied almost
    // to black and a single wave fell from the top again. Measured on a 20 s
    // build: brightness 0.01506 at t=3.5 and 0.01507 at t=23.5, 0.00023 at
    // t=20.5 and 0.00023 at t=40.5. A carbon copy, twice a minute.
    float phi = hash11(cx * 7.13 + 4.7) * span * k;

    float travel = iTime * speed + phi;
    float cycle = floor(travel / span);
    head = travel - cycle * span;

    // Re-hashed on every cycle: the same column is never twice the same drop.
    // mod(cycle, k) rather than cycle, because the clock's wrap moves the cycle
    // count on by exactly k -- so this stays continuous straight across it.
    float c = mod(cycle, k);
    tail = 12.0 + hash12(vec2(cx + 0.5, c)) * 20.0;
    // Centred on 1.0, not below it. Varying the brightness per column is what
    // gives the field depth, but a range of 0.5..1.0 also quietly took a
    // quarter off everything -- and with one cycle in five now resting, the
    // whole thing came out 40% darker than the version this is an edit of.
    // Some columns land above 1 and clip a little at the head, which reads as
    // bloom rather than as an error.
    dim = 0.68 + hash12(vec2(cx + 3.7, c)) * 0.60;
    // Roughly one cycle in seven, the column simply does not fall. Columns that
    // rest are what stops the field reading as a machine.
    alive = step(0.15, hash12(vec2(cx + 9.1, c)));

    // The cold start, and the reason it is a gate rather than an offset: a
    // column waits until it BEGINS a cycle, so it enters over the top edge
    // instead of appearing halfway down. Because the offsets above are spread
    // across a whole cycle, so is this wait -- which is what fills the screen
    // gradually instead of in one wave, and costs nothing in synchrony.
    //
    // Measured against `birth` and never against iTime. `birth` counts from the
    // moment the surface appeared and QML caps it past the longest possible
    // wait (period/k for the slowest column), so from then on this term is 1
    // for good and cannot fire a second time at a wrap.
    float tFirst = (ceil(phi / span) * span - phi) / speed;
    alive *= step(tFirst, birth);
}

void main() {
    vec2 frag = qt_TexCoord0 * iResolution;

    // A terminal cell is far taller than it is wide; 0.47 is the ratio measured
    // off a screenshot of the real screensaver (29x64 native px).
    float cellW = cellH * 0.47;
    vec2 cell = vec2(cellW, cellH);
    vec2 cellId = floor(frag / cell);
    vec2 cellUV = fract(frag / cell);

    float span = iResolution.y / cellH + TAIL_MAX;

    float head, tail, dim, alive;
    column(cellId.x, span, head, tail, dim, alive);

    // Positive = above the head, which is where the trail goes.
    float above = head - cellId.y;
    float vis = step(0.0, above) * step(above, tail) * alive;
    float t = clamp(above / tail, 0.0, 1.0);

    // ttfx never fades the trail to nothing: each character takes a random
    // green from the gradient and stays. The floor of 0.24 keeps that body while
    // still letting the fall read. `dim` on top of it leaves some columns faint
    // and others vivid, which is what gives the field depth.
    float bright = mix(1.0, 0.24, pow(t, 0.85)) * vis * dim;

    // The glyph is redrawn faster at the head than down in the body: the drop
    // boils, the tail settles. Banded rather than continuous, so a cell changes
    // its rate four times on the way down instead of on every frame. The rates
    // are chosen so that rate*period is a whole number, which the wrap needs.
    float band = floor(t * 4.0);
    float rate = (band < 1.0) ? 9.0 : (band < 2.0) ? 3.0 : (band < 3.0) ? 1.5 : 0.75;
    float off = hash12(cellId * 1.7) * 8.0;
    float tick = mod(floor(iTime * rate + off), rate * period);

    float gi = floor(hash12(vec2(cellId.x * 3.1 + cellId.y * 7.7, tick)) * GLYPHS);
    vec2 slot = vec2(mod(gi, ATLAS_COLS), floor(gi / ATLAS_COLS));

    // The film mirrors its katakana. Flipping half of them, decided afresh on
    // each re-roll, turns 50 symbols into 100 shapes without touching the atlas.
    vec2 guv = cellUV;
    if (hash12(vec2(cellId.x * 1.9 + cellId.y * 4.3, tick + 0.5)) > 0.5)
        guv.x = 1.0 - guv.x;
    float a = texture(atlas, (slot + guv) / vec2(ATLAS_COLS, ATLAS_ROWS)).a;

    // Character colour: a random point on the gradient, fixed per cell.
    vec3 rain = mix(colRainA.rgb, colRainB.rgb, hash12(cellId + 3.7));
    // The head is not one cell: it burns up to the highlight and cools again
    // over about three rows, which is what makes it read as a drop leading a
    // trail rather than as a white square.
    float heat = clamp(1.0 - above / 3.0, 0.0, 1.0) * vis;
    vec3 glyph = mix(rain, colHead.rgb, heat * heat);

    // Phosphor bloom: light that comes from no glyph at all, so the column
    // reads as emitting rather than as painted. Summed over this column and its
    // two neighbours -- without the neighbours the glow would stop at the cell
    // edge and leave a seam down every column.
    //
    // The falloff has to DIE inside that three-column window or the truncation
    // shows. It is separate in x and y for that reason: 3.0 across, so that by
    // the edge of the window (1.5 cells) the term is a thousandth of its peak
    // and the cut is invisible; 0.5 down, because a head's light reaching a few
    // rows along its own trail is the whole point. The first version measured
    // both in cell heights with one coefficient, which left the glow at 76% of
    // peak where the window ended -- and drew a hard grey rectangle around every
    // column instead of a bloom.
    float glow = 0.0;
    for (int i = -1; i <= 1; i++) {
        float nh, nt, nd, na;
        column(cellId.x + float(i), span, nh, nt, nd, na);
        float dy = nh - cellId.y - cellUV.y;
        float dx = float(i) + 0.5 - cellUV.x;   // in cell WIDTHS
        glow += na * nd * exp(-dx * dx * 3.0 - dy * dy * 0.5);
    }

    vec3 col = colBg.rgb + glyph * a * bright + colHead.rgb * glow * 0.09;

    // A gentle scanline, so it reads like the output of a CRT. Two NATIVE
    // pixels to a cycle: tied to the panel rather than to logical pixels,
    // because at scale 1.6 the old sin(frag.y * PI) landed on 3.2 native px and
    // beat against the pixel grid into visible bands.
    col *= 0.93 + 0.07 * sin(frag.y * dpr * 3.14159265);

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
