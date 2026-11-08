//! The trim button's icon, embedded as raw RGBA8 pixels (see tools/gen_icons.ps1).
//!
//! `icons/silence.rgba` is a `size` x `size` white glyph on a transparent
//! background. zigui draws images as they are (no tinting), so a dark copy for
//! the light theme and a light copy for the dark theme are derived at compile
//! time. Both are `const` globals: zigui caches an image's texture by address
//! and size, so the address must never change.

/// Width and height of the image, in pixels.
pub const size = 60;

const len = size * size * 4;
const source = @embedFile("icons/silence.rgba");

const dark_glyph = recolor(30);
const light_glyph = recolor(235);

fn recolor(comptime v: u8) [len]u8 {
    @setEvalBranchQuota(1_000_000);
    if (source.len != len) @compileError("icons/silence.rgba is not a 60x60 RGBA image");
    var out: [len]u8 = undefined;
    var i: usize = 0;
    while (i < len) : (i += 4) {
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = source[i + 3];
    }
    return out;
}

/// RGBA pixels of the trim icon: a light glyph for the dark theme, a dark one otherwise.
pub fn silence(dark_theme: bool) []const u8 {
    return if (dark_theme) &light_glyph else &dark_glyph;
}
