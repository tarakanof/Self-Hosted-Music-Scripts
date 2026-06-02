# Shared norm() for music-lidarr-sync.sh.
# Used by both the beets-side and Lidarr-side passes. Output must be byte-identical
# for equivalent strings on either side, otherwise the sync produces false-positive
# Case-E rows (incident 2026-04-24).
#
# Patches relative to the inline 2026-04-24 version:
#   - Cyrillic case fold (tolower handles ASCII only; Дельфин/Земфира/Кино/etc.)
#   - Cardinal words → digits ("Underground Eleven" ↔ "Underground 11")
#   - Trailing decimal ".0" stripped on numeric tokens ("6.0" ↔ "6")
#   - Year-prefix on album field stripped ("2011 - Destroyed" ↔ "Destroyed")
#   - Looser parens-edition strip via terminal-token match ("(Mystery Version)",
#     "(Workout mix)", "(vinyl)", "(EP)" — anything ending in version/edition/mix/etc.)

function norm(s,    t, i, _u, _l, _n) {
    t = tolower(s)

    # Cyrillic uppercase → lowercase (awk tolower() is ASCII-only).
    _u = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    _l = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
    _n = length(_u)
    for (i = 1; i <= _n; i++) gsub(substr(_u, i, 1), substr(_l, i, 1), t)
    # Fold ё → е. They're separate Cyrillic letters but interchangeably used in
    # song/album titles ("Нечётный" ≡ "Нечетный", "взорвётся" ≡ "взорвется").
    gsub(/ё/, "е", t)

    # Strip leading year prefix on album titles: "2011 - Destroyed" → "Destroyed".
    sub(/^[12][0-9]{3}[ ]*[-‐‑‒–—―−][ ]*/, "", t)

    # Ellipsis (U+2026) as word separator — "Hardwired…To" vs "Hardwired… to".
    gsub(/…/, " ", t)

    # Soundtrack-prefix stripping: beets sometimes carries the full release
    # title ("The Music From Drawing Restraint 9") while Lidarr/MB store the
    # bare work title ("Drawing Restraint 9").
    sub(/^(the[ ])?(music|songs|themes?)[ ]from[ ](the[ ])?/, "", t)
    sub(/^original[ ](motion[ ]picture[ ])?soundtrack[ ]/, "", t)

    # Strip parens containing a label catalog number (e.g. "MKK821CD1").
    gsub(/[ ]*[(\[][^()\[\]]*[a-z]{2,}-?[a-z]*[0-9]+[a-z0-9-]*[^()\[\]]*[)\]]/, "", t)

    # Strip parens whose content contains a clear edition/version/format token —
    # catches "(Mystery Version)", "(Workout mix)", "(vinyl)", "(Limited Ed.)",
    # "(2024 Remaster)", etc. \< / \> are gawk word boundaries so "limited"
    # doesn't trigger on its trailing "ed".
    gsub(/[ ]*[(\[][^()\[\]]*\<(version|edition|mix|remix|remaster(ed)?|deluxe|expanded|special|anniversary|definitive|limited|reissue|extended|live|acoustic|demo|explicit|clean|bonus|vinyl|ep|workout)\>[^()\[\]]*[)\]]/, "", t)

    # Strip parens/brackets containing 1+ edition/variant tokens (compound forms).
    for (i = 0; i < 2; i++) {
        gsub(/[ ]*[(\[][ ]*((remaster(ed)?|remix(ed)?|remake|rerecord(ed)?|deluxe|expanded|special|super[ ]deluxe|anniversary|definitive|collector(s)?|limited|platinum|gold|promo|bonus|track[s]?|disc[s]?|reissue|extended|original|motion|picture|soundtrack|score|ost|live|acoustic|demo|explicit|clean|edition|version|japan|japanese|us|uk|european|france|tour|press|mix|workout|vinyl|ep|side|[ab]|[0-9]{4}|[0-9]+[ ]year[ ]anniversary|[0-9]+(st|nd|rd|th)[ ]anniversary)[ ,\-‐‑‒–—―−]*)+[)\]]/, "", t)
    }

    # Replace residual parens/brackets/colons/commas with spaces.
    gsub(/[][():;,]/, " ", t)

    # Trailing ".0" on a numeric token: "6.0" → "6", "2.0" → "2". Must run
    # BEFORE the punct-strip below — that strip removes "." entirely, which
    # would otherwise turn "2.0" into "20" (not equivalent to "2").
    t = gensub(/([0-9])\.0([^0-9]|$)/, "\\1\\2", "g", t)

    # Strip leading "v" before a digit ("V2.0" / "Vol2" → "2"). Lidarr/MB
    # commonly use "V2.0" while beets stores "2.0" for the same release.
    t = gensub(/(^| )v([0-9])/, "\\1\\2", "g", t)

    # Strip trailing edition words.
    sub(/([ ]*[-‐‑‒–—―−]|[ ]+)[ ]*((remaster(ed)?|remix(ed)?|deluxe|expanded|special|reissue|extended|anniversary|definitive|japan|us|uk|european|france|tour|edition|version|live|acoustic|demo|explicit|clean|bonus|mix|workout|vinyl|ep)[ ]*)+$/, "", t)

    # Trailing Roman-numeral anniversary markers.
    sub(/[ ]+(xx|xxx|xxv|xv)$/, "", t)

    # Strip all hyphen variants.
    gsub(/[-‐‑‒–—―−]/, "", t)

    # Curly quote / decorative punct strip. · = U+00B7 middle dot.
    gsub(/["'\''.!?+&_/\\*<>|}{`~^’‘“”‚„‛‟ʼ`´·•«»]/, "", t)

    # Latin diacritic strip (NFKD-style fold to ASCII).
    gsub(/[àáâãäåāăą]/, "a", t); gsub(/[èéêëēĕėęě]/, "e", t)
    gsub(/[ìíîïĩīĭįı]/, "i", t); gsub(/[òóôõöōŏőø]/, "o", t)
    gsub(/[ùúûüũūŭůűų]/, "u", t); gsub(/[ýÿŷȳỹ]/, "y", t)
    gsub(/[ñńňņ]/, "n", t); gsub(/[çčćĉċ]/, "c", t)
    gsub(/[šśŝş]/, "s", t); gsub(/[žźż]/, "z", t)
    gsub(/[ðđ]/, "d", t); gsub(/[þ]/, "th", t)
    gsub(/[ßẞ]/, "ss", t); gsub(/[æ]/, "ae", t); gsub(/[œ]/, "oe", t)
    gsub(/[ł]/, "l", t); gsub(/[ř]/, "r", t); gsub(/[ť]/, "t", t)

    # Cardinal words → digits. Word-boundary via leading/trailing space.
    gsub(/(^| )one( |$)/, " 1 ", t);    gsub(/(^| )two( |$)/, " 2 ", t)
    gsub(/(^| )three( |$)/, " 3 ", t);  gsub(/(^| )four( |$)/, " 4 ", t)
    gsub(/(^| )five( |$)/, " 5 ", t);   gsub(/(^| )six( |$)/, " 6 ", t)
    gsub(/(^| )seven( |$)/, " 7 ", t);  gsub(/(^| )eight( |$)/, " 8 ", t)
    gsub(/(^| )nine( |$)/, " 9 ", t);   gsub(/(^| )ten( |$)/, " 10 ", t)
    gsub(/(^| )eleven( |$)/, " 11 ", t);gsub(/(^| )twelve( |$)/, " 12 ", t)
    gsub(/(^| )thirteen( |$)/, " 13 ", t)

    # Standalone abbreviations.
    gsub(/(^| )pt( |$)/, " part ", t)
    gsub(/(^| )vol( |$)/, " volume ", t)

    # Final whitespace canonicalization. Collapse runs to single space first
    # so the trailing-edition strip and roman-anniversary strip above land on
    # canonical input.
    gsub(/[[:space:]]+/, " ", t)
    sub(/^ +/, "", t); sub(/ +$/, "", t)
    # Drop ALL spaces in the final compare key. This makes "LP 2" ≡ "LP2",
    # "Tri Polar" ≡ "Tri-Polar" (both already → "tri polar" / "tripolar"),
    # "Hardwired To" ≡ "Hardwired… To". Equality compare is exact, so word-
    # boundary collisions ("be st" vs "best") are not a real concern at this
    # stage — both sides are normalized identically.
    gsub(/ /, "", t)
    return t
}
