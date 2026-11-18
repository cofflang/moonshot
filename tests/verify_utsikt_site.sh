#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# Exercise the production document pipeline with synthetic files and pixels.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import subprocess, sys, tempfile
root = Path(sys.argv[1])
source = root / 'programs/utsikt' if (root / 'programs/utsikt/utsikt.c0').exists() else root.parent / 'utsikt'
with tempfile.TemporaryDirectory(prefix='moonshot-site.') as directory:
    work = Path(directory)
    for name in ('paint', 'dom', 'style', 'flow'):
        text = (source / (name + '.c0')).read_text()
        text = text.replace('readfile(', 'fixture_readfile(').replace('glyph(', 'fixture_glyph(').replace('dealloc(', 'fixture_free(')
        (work / (name + '.c0')).write_text(text)
    text = (source / 'utsikt.c0').read_text().split('int main() {')[0]
    for name in ('moon', 'script', 'engine_test', 'glimt'):
        text = text.replace('include "' + name + '.c0";', '')
    # A page read as the opener's own (readfile_owned) is a plain read here,
    # since the fixture files have no owners.
    text = text.replace('readfile_owned(', 'readfile(')
    text = text.replace('readfile(', 'fixture_readfile(').replace('dealloc(', 'fixture_free(')
    (work / 'browser.c0').write_text(text)
    punkt = (root / 'kernel/screen/punkt.c0').read_text()
    (work / 'font.c0').write_text(punkt[punkt.index('int font_hi('):punkt.index('// Draws one character', punkt.index('int font_lo('))])
    (work / 'test.c0').write_text(r'''
int sheet_reads;
int image_reads;
int fixture_readfile(int name, int dest, int cap) {
    if (str_eq(name, "/fixture/picture.spr")) { image_reads += 1; return -1; }
    if (str_eq(name, "/fixture/large.css")) { if (!dest) { return 65537; } return -1; }
    if (str_eq(name, "/fixture/count.css")) { sheet_reads += 1; }
    int text = 0;
    if (str_eq(name, "/fixture/css/site.css") || str_eq(name, "/fixture/sub/../css/site.css")) {
        text = "body {background:#111;color:white} h1 {color:red} mark {background:transparent} main {padding:96px 0} p {margin:3px 3px}";
    }
    if (str_eq(name, "/fixture/sub/next.html")) {
        text = "<link rel='stylesheet' href='../css/site.css'><body><h1>Next</h1><a href='../index.html'>Back</a>";
    }
    if (!text) { return -1; }
    int n = str_len(text);
    if (!dest) { return n; }
    int i = 0;
    for (i = 0; i < n && i < cap; i += 1) { dest[i] = text[i]; }
    return n;
}
include "font.c0";
int fixture_glyph(int c, int p) {
    if (p) {
        int hi = font_hi(c); int lo = font_lo(c); int row = 0;
        for (row = 0; row < 4; row += 1) {
            p[row] = (hi >> ((3 - row) * 8)) & 255;
            p[row + 4] = (lo >> ((3 - row) * 8)) & 255;
        }
    }
    return 524296;
}
void fixture_free(int p) { return; }
void scripts_run(int root) { return; }
include "browser.c0";
int failures;
void check(int yes, int label) {
    if (!yes) { print("FAIL "); print(label); print("\n"); failures += 1; }
    return;
}
int find(int n, int name) {
    if (n.n_kind == KIND_ELEM && str_eq(n.n_name, name)) { return n; }
    int c = n.n_first;
    while (c) { int r = find(c, name); if (r) { return r; } c = c.n_next; }
    return 0;
}
int main() {
    cell_w = 8; cell_h = 8;
    current_page = "/fixture/index.html";
    doc_begin();
    int r = build_page("<link rel='icon' href='css/site.css'><style>h1{color:blue}</style><link rel='alternate STYLESHEET' href='css/site.css'><link rel='stylesheet' href='missing.css'><body><h1>Title</h1><main>Content</main><mark>Link</mark><p>Copy</p>");
    int n = find(r, "h1"); int p = n.n_style;
    check(p.p_color == 0xCC0000, "linked sheet and document order");
    n = find(r, "main"); p = n.n_style;
    check(p.p_pad == 0, "differing shorthand refused");
    n = find(r, "mark"); p = n.n_style;
    check(p.p_bg < 0, "transparent clears default background");
    n = find(r, "p"); p = n.n_style;
    check(p.p_margin == 3, "equal shorthand accepted");
    check(page_bg == 0x111111, "linked body background");
    r = goto_page("/fixture/sub/next.html");
    check(r != 0, "nested document loaded");
    check(page_bg == 0x111111, "sheet relative to destination page");
    r = build_page("<body><p>åäöÅÄÖé–…“”</p></body>");
    n = find(r, "p"); int t = n.n_first;
    check(str_len(t.n_text) == 11, "UTF-8 has one cell per supported character");
    check(font_init() == 1, "kernel font cached");
    int codes = alloc(88);
    store64(codes,229); store64(codes+8,228); store64(codes+16,246);
    store64(codes+24,197); store64(codes+32,196); store64(codes+40,214);
    store64(codes+48,233); store64(codes+56,8211); store64(codes+64,8230);
    store64(codes+72,8220); store64(codes+80,8221);
    int g = 0;
    for (g = 0; g < 11; g += 1) {
        int code = load64(codes + g * 8);
        check((font_hi(code) | font_lo(code)) != 0, "supported kernel glyph is visible");
        check(t.n_text[g] == unicode_slot(code), "UTF-8 maps to expected glyph slot");
    }
    view_w = 160; view_h = 80; fb = alloc(view_w * view_h * 4);
    font_cache = alloc(256 * 8);
    int c = 0;
    for (c = 0; c < 256 * 8; c += 1) { font_cache[c] = 255; }
    flow_init();
    r = build_page("<body><h1> <b>AB</b> CD</h1><style>h1{font-size:8px;color:transparent;background:linear-gradient(to right,#ff0000,#0000ff);background-clip:text;margin:0;padding:0}</style></body>");
    render_page(r);
    int reds = 0; int blues = 0; int mixed = 0; int k = 0;
    for (k = 0; k < view_w * view_h; k += 1) {
        int pixel = load32(fb + k * 4) & 0xFFFFFF;
        if (pixel == 0xFF0000) { reds += 1; }
        if (pixel == 0x0000FF) { blues += 1; }
        if ((pixel & 0xFF0000) != 0 && (pixel & 255) != 0) { mixed += 1; }
    }
    check(reds > 0 && blues > 0 && mixed > 0, "horizontal gradient glyph pixels");
    r = build_page("<body><h1>ABCD</h1><style>h1{font-size:8px;color:transparent;background:linear-gradient(120deg,#20880c 0,#6fcf6f 37.5%,#20880c 100%);background-clip:text;margin:0}</style></body>");
    render_page(r);
    int greens = 0;
    for (k = 0; k < view_w * view_h; k += 1) {
        int pixel2 = load32(fb + k * 4) & 0xFFFFFF;
        if (pixel2 == 0x20880C) { greens += 1; }
    }
    check(greens > 0, "positioned gradient stops painted horizontally");
    current_page = "/fixture/index.html";
    check(str_eq(resource_name("/absolute/file"), "/absolute/file"), "absolute resource path");
    check(str_eq(resource_name("../back.html"), "/fixture/../back.html"), "parent navigation allowed");
    r = build_page("<link rel='icon' href='css/site.css'><body><p>plain</p></body>");
    check(page_bg == 0xF6F5F0, "icon is not a sheet");
    r = build_page("<link rel='stylesheet' href='css/site.css'><style>body{background:red}</style><body><img src='picture.spr'></body>");
    check(page_bg == 0xCC0000, "inline sheet after linked sheet");
    check(image_reads == 1, "image path relative to page");
    r = build_page("<link rel='stylesheet' href='large.css'><body><p>plain</p></body>");
    check(page_bg == 0xF6F5F0, "oversized sheet omitted");
    int html = alloc(4096); int offset = 0; int j = 0;
    int tag = "<link rel='stylesheet' href='count.css'>";
    for (j = 0; j < 20; j += 1) {
        int a = 0;
        while (tag[a]) { html[offset] = tag[a]; offset += 1; a += 1; }
    }
    html[offset] = 0;
    r = build_page(html);
    check(sheet_reads == 16, "linked sheet count cap");
    int props = props_new();
    apply_decl(props, "padding", "96px 0");
    check(props.p_pad == -1, "differing box sides dropped whole");
    apply_decl(props, "padding", "4px 4px 4px 4px");
    check(props.p_pad == 4, "four equal sides accepted");
    apply_decl(props, "padding", "4px 2em");
    check(props.p_pad == 4, "unsupported unit leaves prior declaration");
    check(parse_gradient("linear-gradient(to right,#ff0000,#0000ff) trailing") == 0, "gradient trailing garbage dropped");
    check(parse_gradient("linear-gradient(to right,#ff0000 90%,#0000ff 10%)") == 0, "decreasing stops dropped whole");
    r = build_page("<body><a href='next.html'>AB</a><style>a{color:transparent}</style></body>");
    render_page(r);
    check(link_count == 1, "transparent link keeps its hit box");
    if (failures) { return 1; }
    print("PASS production site pipeline\n");
    return 0;
}
''')
    subprocess.run([str(root.parent/'c0-coff/coff1'), 'test.c0', 'test.s'], cwd=work, check=True)
    subprocess.run([str(root.parent/'c0-coff/smed'), 'test.s', 'test'], cwd=work, check=True)
    (work/'test').chmod(0o700)
    sys.exit(subprocess.run([str(work/'test')], cwd=work, timeout=10).returncode)
PY
