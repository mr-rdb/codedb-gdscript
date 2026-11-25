// Tests for src/godot_parser.zig — GDScript, scene, resource, project.godot.
const std = @import("std");
const testing = std.testing;
const gp = @import("../../godot_parser.zig");
const Explorer = @import("../../explore.zig").Explorer;
const explore = @import("../../explore.zig");
const SymbolKind = explore.SymbolKind;

fn parseGd(line: []const u8, state: *gp.GdState) gp.ParsedLine {
    return gp.parseGdLine(line, std.mem.trim(u8, line, " \t"), state);
}

test "gdscript: class_name declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("class_name TowerManager", &st);
    try testing.expectEqualStrings("TowerManager", r.symbol.name);
    try testing.expectEqual(gp.Kind.class_name_decl, r.symbol.kind);
}

test "gdscript: extends by class name becomes an import" {
    var st: gp.GdState = .{};
    const r = parseGd("extends Node2D", &st);
    try testing.expectEqualStrings("Node2D", r.import.path);
}

test "gdscript: extends by res:// path becomes a project-relative import" {
    var st: gp.GdState = .{};
    const r = parseGd("extends \"res://enemy/base_enemy.gd\"", &st);
    try testing.expectEqualStrings("enemy/base_enemy.gd", r.import.path);
}

test "gdscript: func with params and return type" {
    var st: gp.GdState = .{};
    const r = parseGd("func place_tower(tower_scene: PackedScene, lane_index: int) -> bool:", &st);
    try testing.expectEqualStrings("place_tower", r.symbol.name);
    try testing.expectEqual(gp.Kind.function_def, r.symbol.kind);
}

test "gdscript: static func" {
    var st: gp.GdState = .{};
    const r = parseGd("static func from_dict(d: Dictionary) -> SaveData:", &st);
    try testing.expectEqualStrings("from_dict", r.symbol.name);
    try testing.expectEqual(gp.Kind.function_def, r.symbol.kind);
}

test "gdscript: signal declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("signal tower_placed(tower: Node2D, lane_index: int)", &st);
    try testing.expectEqualStrings("tower_placed", r.symbol.name);
    try testing.expectEqual(gp.Kind.signal_decl, r.symbol.kind);
}

test "gdscript: bare signal without params" {
    var st: gp.GdState = .{};
    const r = parseGd("signal wave_started", &st);
    try testing.expectEqualStrings("wave_started", r.symbol.name);
}

test "gdscript: var, const, enum" {
    var st: gp.GdState = .{};
    const v = parseGd("var lane_count: int = 0", &st);
    try testing.expectEqualStrings("lane_count", v.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, v.symbol.kind);

    const c = parseGd("const MAX_TOWERS = 32", &st);
    try testing.expectEqualStrings("MAX_TOWERS", c.symbol.name);
    try testing.expectEqual(gp.Kind.constant_decl, c.symbol.kind);

    const e = parseGd("enum TowerType { BASIC, SPLASH, SNIPER }", &st);
    try testing.expectEqualStrings("TowerType", e.symbol.name);
    try testing.expectEqual(gp.Kind.enum_decl, e.symbol.kind);
}

test "gdscript: static var is still a variable declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("static var counter: int = 0", &st);
    try testing.expectEqualStrings("counter", r.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, r.symbol.kind);
}

test "gdscript: inline annotation still yields the declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("@export var default_tower_scene: PackedScene", &st);
    try testing.expectEqualStrings("default_tower_scene", r.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, r.symbol.kind);

    const r2 = parseGd("@export_range(0, 10) var speed: float = 1.0", &st);
    try testing.expectEqualStrings("speed", r2.symbol.name);
}

test "gdscript: standalone annotation line" {
    var st: gp.GdState = .{};
    const r = parseGd("@rpc(\"any_peer\")", &st);
    try testing.expectEqualStrings("@rpc", r.annotation.name);
    const r2 = parseGd("@tool", &st);
    try testing.expectEqualStrings("@tool", r2.annotation.name);
}

test "gdscript: inner class scope makes funcs methods" {
    var st: gp.GdState = .{};
    const cls = parseGd("class WaveEntry:", &st);
    try testing.expectEqualStrings("WaveEntry", cls.symbol.name);
    try testing.expectEqual(gp.Kind.inner_class, cls.symbol.kind);

    const m = parseGd("\tfunc duration() -> float:", &st);
    try testing.expectEqual(gp.Kind.method_def, m.symbol.kind);

    // Back at top level: plain function again
    const f = parseGd("func start_wave():", &st);
    try testing.expectEqual(gp.Kind.function_def, f.symbol.kind);
}

test "gdscript: hash inside string is not a comment" {
    var st: gp.GdState = .{};
    const r = parseGd("var color_tag = \"#ff0000\"", &st);
    try testing.expectEqualStrings("color_tag", r.symbol.name);
}

test "gdscript: comment lines and commented-out decls yield none" {
    var st: gp.GdState = .{};
    try testing.expect(parseGd("# func not_real():", &st) == .none);
    try testing.expect(parseGd("## docstring comment", &st) == .none);
}

test "gdscript: multiline string swallows fake decls until closed" {
    var st: gp.GdState = .{};
    _ = parseGd("var doc = \"\"\"", &st);
    try testing.expect(st.in_multiline_string);
    try testing.expect(parseGd("func fake_decl_inside_string():", &st) == .none);
    _ = parseGd("\"\"\"", &st);
    try testing.expect(!st.in_multiline_string);
    const r = parseGd("func real_decl():", &st);
    try testing.expectEqualStrings("real_decl", r.symbol.name);
}

test "gdscript: unterminated multiline string does not crash later parsing" {
    var st: gp.GdState = .{};
    _ = parseGd("var s = \"\"\"never closed", &st);
    try testing.expect(parseGd("func swallowed():", &st) == .none); // stays inside; no crash
}

test "gdscript: extractResPath finds preload and load references" {
    try testing.expectEqualStrings(
        "tower/Tower.tscn",
        gp.extractResPath("const TowerScene = preload(\"res://tower/Tower.tscn\")").?,
    );
    try testing.expectEqualStrings(
        "GameState.gd",
        gp.extractResPath("var gs = load(\"res://GameState.gd\")").?,
    );
    try testing.expect(gp.extractResPath("var x = compute(1, 2)") == null);
    try testing.expect(gp.extractResPath("preload(\"user://save.dat\")") == null);
}

test "gdscript: stripGdComment respects strings; commented-out preload yields no path" {
    try testing.expectEqualStrings(
        "var color = \"#ff0000\"",
        gp.stripGdComment("var color = \"#ff0000\" # a hex color"),
    );
    // Callers strip comments before extracting res:// paths (see lifecycle
    // dispatch) so commented-out preloads don't become dependency edges.
    try testing.expect(gp.extractResPath(gp.stripGdComment("# preload(\"res://x.gd\")")) == null);
}

test "scene: ext_resource becomes a project-relative import" {
    const r = gp.parseSceneLine("[ext_resource type=\"Script\" path=\"res://TowerManager.gd\" id=\"ext_12\"]");
    try testing.expectEqualStrings("TowerManager.gd", r.import.path);
}

test "scene: node with type and parent" {
    const r = gp.parseSceneLine("[node name=\"Main\" type=\"Node2D\" id=\"1\"]");
    try testing.expectEqualStrings("Main", r.symbol.name);
    try testing.expectEqual(gp.Kind.node_def, r.symbol.kind);

    var buf: [256]u8 = undefined;
    const detail = gp.extractDetail("[node name=\"HUD\" type=\"CanvasLayer\" parent=\"1\"]", .node_def, &buf);
    try testing.expectEqualStrings("type=CanvasLayer parent=1", detail);
}

test "scene: connection captures signal wiring" {
    const line = "[connection signal=\"pressed\" from=\"StartButton\" to=\".\" method=\"_on_start_pressed\"]";
    const r = gp.parseSceneLine(line);
    try testing.expectEqualStrings("pressed", r.symbol.name);
    try testing.expectEqual(gp.Kind.connection, r.symbol.kind);

    var buf: [256]u8 = undefined;
    const detail = gp.extractDetail(line, .connection, &buf);
    try testing.expectEqualStrings("from=StartButton to=. method=_on_start_pressed", detail);
}

test "scene: gd_resource script_class, sub_resource ignored" {
    const r = gp.parseSceneLine("[gd_resource type=\"Resource\" script_class=\"CardData\" format=3]");
    try testing.expectEqualStrings("CardData", r.symbol.name);
    try testing.expectEqual(gp.Kind.resource_def, r.symbol.kind);

    try testing.expect(gp.parseSceneLine("[sub_resource type=\"RectangleShape2D\" id=\"rect_1\"]") == .none);
    try testing.expect(gp.parseSceneLine("[gd_scene format=3]") == .none);
    try testing.expect(gp.parseSceneLine("position = Vector2(100, 200)") == .none);
}

test "scene: malformed lines degrade to none" {
    try testing.expect(gp.parseSceneLine("[node name=\"Unterminated") == .none);
    try testing.expect(gp.parseSceneLine("[ext_resource type=\"Script\"]") == .none); // no path
    try testing.expect(gp.parseSceneLine("[") == .none);
}

test "scene: escaped quote inside node name" {
    const r = gp.parseSceneLine("[node name=\"He said \\\"hi\\\"\" type=\"Label\"]");
    try testing.expectEqualStrings("He said \\\"hi\\\"", r.symbol.name);
}

test "scene: attribute name is matched on word boundary" {
    // "signal" must not match inside a hypothetical attr ending in ...signal
    const r = gp.parseSceneLine("[connection my_signal=\"nope\" signal=\"hit\" from=\"A\" to=\"B\" method=\"m\"]");
    try testing.expectEqualStrings("hit", r.symbol.name);
}

test "project.godot: autoloads become imports, input actions become symbols" {
    var section: gp.ProjectSection = .none;

    const hdr = gp.parseProjectLine("[autoload]", &section);
    try testing.expectEqualStrings("autoload", hdr.symbol.name);
    try testing.expectEqual(gp.Kind.section_header, hdr.symbol.kind);

    const al = gp.parseProjectLine("GameState=\"*res://GameState.gd\"", &section);
    try testing.expectEqualStrings("GameState.gd", al.import.path);

    _ = gp.parseProjectLine("[input]", &section);
    const act = gp.parseProjectLine("place_tower={", &section);
    try testing.expectEqualStrings("place_tower", act.symbol.name);
    try testing.expectEqual(gp.Kind.input_action, act.symbol.kind);

    // continuation lines inside the action block are not symbols
    try testing.expect(gp.parseProjectLine("\"deadzone\": 0.5,", &section) == .none);

    _ = gp.parseProjectLine("[application]", &section);
    try testing.expect(gp.parseProjectLine("config/name=\"Lunch Rush\"", &section) == .none);
}

test "project.godot: malformed section header degrades to none" {
    var section: gp.ProjectSection = .none;
    try testing.expect(gp.parseProjectLine("[unclosed", &section) == .none);
    try testing.expect(gp.parseProjectLine("[]", &section) == .none);
}

fn findSymbol(outline: anytype, name: []const u8) ?explore.Symbol {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym;
    }
    return null;
}

fn hasImport(outline: anytype, path: []const u8) bool {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, path)) return true;
    }
    return false;
}

test "e2e: .gd file yields outline symbols and imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("TowerManager.gd",
        \\extends Node
        \\## TowerManager — autoload singleton.
        \\
        \\const TowerScene = preload("res://tower/Tower.tscn")
        \\
        \\@export var default_tower_scene: PackedScene
        \\var lane_count: int = 0
        \\
        \\signal tower_placed(tower: Node2D, lane_index: int)
        \\
        \\func place_tower(scene: PackedScene, lane_index: int) -> bool:
        \\    return true
        \\
        \\static func reset() -> void:
        \\    pass
    );

    const outline = explorer.outlines.get("TowerManager.gd").?;
    try testing.expectEqual(explore.Language.gdscript, outline.language);

    try testing.expectEqual(SymbolKind.function, findSymbol(outline, "place_tower").?.kind);
    try testing.expectEqual(SymbolKind.function, findSymbol(outline, "reset").?.kind);
    try testing.expectEqual(SymbolKind.signal, findSymbol(outline, "tower_placed").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSymbol(outline, "default_tower_scene").?.kind);
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "TowerScene").?.kind);

    // signal detail carries the full signature (falls back to trimmed line)
    const sig = findSymbol(outline, "tower_placed").?;
    try testing.expect(std.mem.startsWith(u8, sig.detail.?, "signal tower_placed"));

    try testing.expect(hasImport(outline, "Node")); // extends
    try testing.expect(hasImport(outline, "tower/Tower.tscn")); // preload
}

test "e2e: .tscn yields node tree symbols and script/scene imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Main.tscn",
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://main.gd" id="ext_1"]
        \\[ext_resource type="PackedScene" path="res://HUD.tscn" id="ext_4"]
        \\
        \\[node name="Main" type="Node2D" id="1"]
        \\script = ExtResource("ext_1")
        \\
        \\[node name="TowerManager" type="Node" id="3" parent="1"]
        \\
        \\[connection signal="pressed" from="StartButton" to="." method="_on_start_pressed"]
    );

    const outline = explorer.outlines.get("Main.tscn").?;
    try testing.expectEqual(explore.Language.godot_scene, outline.language);

    try testing.expect(hasImport(outline, "main.gd"));
    try testing.expect(hasImport(outline, "HUD.tscn"));

    try testing.expectEqual(SymbolKind.class_def, findSymbol(outline, "Main").?.kind);
    const tm = findSymbol(outline, "TowerManager").?;
    try testing.expectEqualStrings("type=Node parent=1", tm.detail.?);

    const conn = findSymbol(outline, "pressed").?;
    try testing.expectEqual(SymbolKind.variable, conn.kind);
    // `to="."` is the root, whose script is main.gd: the wiring is linked to it.
    try testing.expectEqualStrings("from=StartButton to=. method=_on_start_pressed script=main.gd", conn.detail.?);
}

test "e2e: project.godot yields autoload imports and input actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("project.godot",
        \\config_version=5
        \\
        \\[application]
        \\config/name="Lunch Rush"
        \\
        \\[autoload]
        \\GameState="*res://GameState.gd"
        \\TowerManager="*res://TowerManager.gd"
        \\
        \\[input]
        \\place_tower={
        \\"deadzone": 0.5,
        \\"events": []
        \\}
    );

    const outline = explorer.outlines.get("project.godot").?;
    try testing.expectEqual(explore.Language.godot_project, outline.language);

    try testing.expect(hasImport(outline, "GameState.gd"));
    try testing.expect(hasImport(outline, "TowerManager.gd"));
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "place_tower").?.kind);
    try testing.expectEqual(SymbolKind.type_alias, findSymbol(outline, "autoload").?.kind);
}

test "e2e: standalone annotation attaches as decorator to next symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Net.gd",
        \\extends Node
        \\
        \\@rpc("any_peer")
        \\func fire_projectile(lane: int) -> void:
        \\    pass
    );

    const outline = explorer.outlines.get("Net.gd").?;
    const f = findSymbol(outline, "fire_projectile").?;
    try testing.expectEqual(@as(usize, 1), f.decorators.len);
    try testing.expectEqualStrings("@rpc", f.decorators[0]);
}

// ── Added: symbol spans, comments, class_name and res:// resolution ────────

const deps = @import("../../explore/deps.zig");
const search_utils = @import("../../explore/search_utils.zig");
const source_lexical = @import("../../source_lexical.zig");
const Store = @import("../../store.zig").Store;
const watcher = @import("../../watcher.zig");
const FilteredWalker = @import("../../watcher/filtered_walker.zig").FilteredWalker;
const io = std.testing.io;

fn importPath(result: gp.ParsedLine) ?[]const u8 {
    return switch (result) {
        .import => |imp| imp.path,
        else => null,
    };
}

test "gdscript: single-quoted res:// paths in extends, preload and load" {
    var state: gp.GdState = .{};
    try testing.expectEqualStrings("base/card.gd", importPath(parseGd("extends 'res://base/card.gd'", &state)).?);
    try testing.expectEqualStrings("scripts/a.gd", gp.extractResPath("const A = preload('res://scripts/a.gd')").?);
    try testing.expectEqualStrings("scripts/b.gd", gp.extractResPath("var b = load(\"res://scripts/b.gd\")").?);
    // ResourceLoader.load is a real call; my_load is an unrelated identifier.
    try testing.expectEqualStrings("scripts/c.gd", gp.extractResPath("ResourceLoader.load(\"res://scripts/c.gd\")").?);
    try testing.expect(gp.extractResPath("var x = my_load(\"res://scripts/d.gd\")") == null);
}

test "gdscript: unterminated or non-res path literals yield nothing" {
    var state: gp.GdState = .{};
    try testing.expect(gp.extractResPath("preload(\"res://broken") == null);
    try testing.expect(gp.extractResPath("load('") == null);
    try testing.expect(gp.extractResPath("load(\"user://save.dat\")") == null);
    try testing.expect(importPath(parseGd("extends \"res://unterminated", &state)) == null);
    try testing.expect(importPath(parseGd("extends '", &state)) == null);
}

test "gdscript: function, enum and class_name symbols span their real bodies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Body.gd",
        \\class_name Body
        \\extends Node
        \\
        \\enum Mode {
        \\    IDLE,
        \\    RUN
        \\}
        \\
        \\func tick(delta: float) -> void:
        \\    if delta > 0.0:
        \\        pass
        \\    # trailing comment
        \\
        \\func idle():
        \\    pass
        \\
        \\class Inner:
        \\    func inner_fn():
        \\        return 1
    );

    const outline = explorer.outlines.get("Body.gd").?;
    const class_sym = findSymbol(outline, "Body").?;
    try testing.expectEqual(@as(u32, 1), class_sym.line_start);
    try testing.expectEqual(@as(u32, 1), class_sym.line_end);

    const enum_sym = findSymbol(outline, "Mode").?;
    try testing.expectEqual(SymbolKind.enum_def, enum_sym.kind);
    try testing.expectEqual(@as(u32, 4), enum_sym.line_start);
    try testing.expectEqual(@as(u32, 7), enum_sym.line_end);

    // The trailing comment does not extend the body; the blank line ends it.
    const tick = findSymbol(outline, "tick").?;
    try testing.expectEqual(@as(u32, 9), tick.line_start);
    try testing.expectEqual(@as(u32, 11), tick.line_end);

    const idle = findSymbol(outline, "idle").?;
    try testing.expectEqual(@as(u32, 14), idle.line_start);
    try testing.expectEqual(@as(u32, 15), idle.line_end);

    const inner = findSymbol(outline, "Inner").?;
    try testing.expectEqual(SymbolKind.class_def, inner.kind);
    try testing.expectEqual(@as(u32, 17), inner.line_start);
    try testing.expectEqual(@as(u32, 19), inner.line_end);

    const inner_fn = findSymbol(outline, "inner_fn").?;
    try testing.expectEqual(SymbolKind.method, inner_fn.kind);
    try testing.expectEqual(@as(u32, 18), inner_fn.line_start);
    try testing.expectEqual(@as(u32, 19), inner_fn.line_end);
}

test "gdscript: malformed input keeps every symbol span well-formed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Broken.gd",
        \\func broken(
        \\    a: int,
        \\) -> void:
        \\    var s = "{ not a brace"
        \\    var t = '''never closed
        \\enum Open {
        \\func after():
        \\    pass
    );

    const outline = explorer.outlines.get("Broken.gd").?;
    try testing.expect(outline.symbols.items.len >= 1);
    for (outline.symbols.items) |sym| {
        try testing.expect(sym.line_end >= sym.line_start);
    }
}

test "gdscript: # comment lines are not code for callers and lexical masking" {
    try testing.expect(search_utils.isCommentOrBlank("  # old_call()", .gdscript));
    try testing.expect(!search_utils.isCommentOrBlank("  func real_call():", .gdscript));

    const masked = try source_lexical.mask(testing.allocator, "var a = fake_call() # gone_call()\nfunc real_call():", .gdscript);
    defer testing.allocator.free(masked);
    try testing.expect(std.mem.indexOf(u8, masked, "gone_call") == null);
    try testing.expect(std.mem.indexOf(u8, masked, "fake_call") != null);
    try testing.expect(std.mem.indexOf(u8, masked, "real_call") != null);
}

test "project.godot: only the exact file name is a Godot project file" {
    try testing.expect(explore.detectLanguage("myproject.godot") != .godot_project);
    try testing.expect(explore.detectLanguage("games/a/project.godot") == .godot_project);
}

test "gdscript: extends by class_name resolves to the snake_case file that declares it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("scripts/clay/clay_model.gd", "class_name ClayModel\nextends Node3D\n");
    try explorer.indexFile("scripts/props/sky_star.gd", "extends ClayModel\n");

    try testing.expectEqualStrings(
        "scripts/clay/clay_model.gd",
        deps.resolveDependency(&explorer, "scripts/props/sky_star.gd", "ClayModel").?,
    );

    const importers = try explorer.getImportedBy("scripts/clay/clay_model.gd", testing.allocator);
    defer {
        for (importers) |p| testing.allocator.free(p);
        testing.allocator.free(importers);
    }
    try testing.expectEqual(@as(usize, 1), importers.len);
    try testing.expectEqualStrings("scripts/props/sky_star.gd", importers[0]);
}

test "gdscript: ambiguous class_name stays unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a/one.gd", "class_name Shared\n");
    try explorer.indexFile("b/two.gd", "class_name Shared\n");
    try explorer.indexFile("c/user.gd", "extends Shared\n");

    try testing.expect(deps.resolveDependency(&explorer, "c/user.gd", "Shared") == null);
}

test "godot: res:// paths resolve against the nested project that holds the importer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("games/a/project.godot", "[application]\nconfig/name=\"a\"\n");
    try explorer.indexFile("games/a/scenes/main.tscn", "[ext_resource type=\"Script\" path=\"res://scripts/player.gd\" id=\"1_x\"]\n");
    try explorer.indexFile("games/a/scripts/player.gd", "extends Node\n");
    try explorer.indexFile("games/b/scripts/player.gd", "extends Node\n");

    try testing.expectEqualStrings(
        "games/a/scripts/player.gd",
        deps.resolveDependency(&explorer, "games/a/scenes/main.tscn", "scripts/player.gd").?,
    );

    // The same-named file in games/b is not the target of games/a's scene.
    const importers = try explorer.getImportedBy("games/a/scripts/player.gd", testing.allocator);
    defer {
        for (importers) |p| testing.allocator.free(p);
        testing.allocator.free(importers);
    }
    try testing.expectEqual(@as(usize, 1), importers.len);
    try testing.expectEqualStrings("games/a/scenes/main.tscn", importers[0]);
}

test "godot: root-level project res:// paths still resolve exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("project.godot", "[application]\n");
    try explorer.indexFile("scripts/x.gd", "extends Node\n");
    try explorer.indexFile("scenes/main.tscn", "[ext_resource type=\"Script\" path=\"res://scripts/x.gd\" id=\"1\"]\n");

    try testing.expectEqualStrings("scripts/x.gd", deps.resolveDependency(&explorer, "scenes/main.tscn", "scripts/x.gd").?);
}

test "godot: .gdignore excludes its directory from the index and from path checks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "keep");
    try tmp_dir.dir.createDirPath(io, "hidden");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "hidden/.gdignore", .data = "" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "hidden/secret.gd", .data = "extends Node\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "keep/visible.gd", .data = "extends Node\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);

    try testing.expect(explorer.contents.contains("keep/visible.gd"));
    try testing.expect(!explorer.contents.contains("hidden/secret.gd"));

    try testing.expect(FilteredWalker.allowsPath(io, tmp_dir.dir, "keep/visible.gd", testing.allocator));
    try testing.expect(!FilteredWalker.allowsPath(io, tmp_dir.dir, "hidden/secret.gd", testing.allocator));
}

// ── Added: type annotations, receivers, autoloads, scene connections ───────

fn containsPath(list: []const []const u8, path: []const u8) bool {
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn freeImporters(list: []const []const u8) void {
    for (list) |p| testing.allocator.free(p);
    testing.allocator.free(list);
}

test "gdscript: type annotations come from declarations, not initializers" {
    var out: [gp.max_annotations][]const u8 = undefined;

    try testing.expectEqual(@as(usize, 1), gp.typeAnnotations("var x: ClayBlob = null", &out));
    try testing.expectEqualStrings("ClayBlob", out[0]);

    // `:=` infers the type, and a dictionary literal's colon is not a type.
    try testing.expectEqual(@as(usize, 0), gp.typeAnnotations("var y := ClayBlob.new()", &out));
    try testing.expectEqual(@as(usize, 0), gp.typeAnnotations("var d = {\"k\": ClayBlob}", &out));
    try testing.expectEqual(@as(usize, 0), gp.typeAnnotations("class Inner:", &out));

    // Return type first, then each parameter; the default value is not read.
    const n = gp.typeAnnotations("func f(a: ClayBlob, b: Array[Foo], c: int = 3) -> Bar:", &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("Bar", out[0]);
    try testing.expectEqualStrings("ClayBlob", out[1]);
    try testing.expectEqualStrings("Array[Foo]", out[2]);
    try testing.expectEqualStrings("int", out[3]);
}

test "gdscript: type names skip namespace qualifiers; builtins are filtered" {
    const text = "Array[Outer.ClayBlob]";
    var pos: usize = 0;
    try testing.expectEqualStrings("Array", gp.nextTypeName(text, &pos).?);
    try testing.expectEqualStrings("ClayBlob", gp.nextTypeName(text, &pos).?);
    try testing.expect(gp.nextTypeName(text, &pos) == null);

    try testing.expect(gp.isBuiltinGdType("Vector3"));
    try testing.expect(gp.isBuiltinGdType("int"));
    try testing.expect(!gp.isBuiltinGdType("ClayBlob"));
}

test "gdscript: receivers come from code, not from comments or strings" {
    const source = "# ClayBlob.old()\nvar s = \"Travel.text\"\nfunc f():\n\tTravel.foo()\n\tvar n = my.Thing\n";
    const masked = try source_lexical.mask(testing.allocator, source, .gdscript);
    defer testing.allocator.free(masked);

    var pos: usize = 0;
    try testing.expectEqualStrings("Travel", gp.nextReceiver(masked, &pos).?);
    try testing.expect(gp.nextReceiver(masked, &pos) == null);
}

test "gdscript: typed and receiver references link a user to the class file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("scripts/clay/clay_blob.gd", "class_name ClayBlob\nextends Node3D\n");
    try explorer.indexFile("scripts/clay/clay_kit.gd", "class_name ClayKit\nstatic func make():\n\treturn null\n");
    try explorer.indexFile("scripts/user.gd",
        \\extends Node
        \\var blob: ClayBlob
        \\func build(out: Array[ClayBlob]) -> ClayBlob:
        \\    return ClayKit.make()
    );
    try explorer.indexFile("scripts/comment_only.gd",
        \\# ClayBlob.new() was removed
        \\var n = 1
    );

    const blob_users = try explorer.getImportedBy("scripts/clay/clay_blob.gd", testing.allocator);
    defer freeImporters(blob_users);
    try testing.expect(containsPath(blob_users, "scripts/user.gd"));
    try testing.expect(!containsPath(blob_users, "scripts/comment_only.gd"));

    const kit_users = try explorer.getImportedBy("scripts/clay/clay_kit.gd", testing.allocator);
    defer freeImporters(kit_users);
    try testing.expect(containsPath(kit_users, "scripts/user.gd"));
}

test "gdscript: a file is never a reference dependency of itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("scripts/clay_kit.gd", "class_name ClayKit\nfunc make():\n\treturn ClayKit.new()\n");

    const users = try explorer.getImportedBy("scripts/clay_kit.gd", testing.allocator);
    defer freeImporters(users);
    try testing.expect(!containsPath(users, "scripts/clay_kit.gd"));
}

test "gdscript: autoload references resolve to the autoload script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("project.godot",
        \\[autoload]
        \\
        \\Travel="*res://scripts/travel.gd"
        \\BackgroundMusic="*res://scripts/music.gd"
    );
    try explorer.indexFile("scripts/travel.gd", "extends Node\nfunc foo():\n\tpass\n");
    try explorer.indexFile("scripts/music.gd", "extends Node\nfunc bar():\n\tpass\n");
    try explorer.indexFile("scripts/player.gd", "extends Node\nfunc _ready():\n\tTravel.foo()\n\tBackgroundMusic.bar()\n");

    // The autoload name is a symbol of project.godot, pointing at its script.
    const project = explorer.outlines.get("project.godot").?;
    const travel = findSymbol(project, "Travel").?;
    try testing.expectEqual(SymbolKind.variable, travel.kind);

    try testing.expectEqualStrings(
        "scripts/travel.gd",
        deps.resolveDependency(&explorer, "scripts/player.gd", "ref:Travel").?,
    );

    const travel_users = try explorer.getImportedBy("scripts/travel.gd", testing.allocator);
    defer freeImporters(travel_users);
    try testing.expect(containsPath(travel_users, "scripts/player.gd"));

    const music_users = try explorer.getImportedBy("scripts/music.gd", testing.allocator);
    defer freeImporters(music_users);
    try testing.expect(containsPath(music_users, "scripts/player.gd"));
}

test "gdscript: an autoload name shared by nested projects resolves inside its own project" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const autoload = "[autoload]\n\nTravel=\"*res://scripts/travel.gd\"\n";
    try explorer.indexFile("games/a/project.godot", autoload);
    try explorer.indexFile("games/b/project.godot", autoload);
    try explorer.indexFile("games/a/scripts/travel.gd", "extends Node\n");
    try explorer.indexFile("games/b/scripts/travel.gd", "extends Node\n");
    try explorer.indexFile("games/b/scripts/player.gd", "extends Node\nfunc _ready():\n\tTravel.x()\n");

    try testing.expectEqualStrings(
        "games/b/scripts/travel.gd",
        deps.resolveDependency(&explorer, "games/b/scripts/player.gd", "ref:Travel").?,
    );
    // Outside both projects the name is ambiguous, so it stays unresolved.
    try testing.expect(deps.resolveDependency(&explorer, "tools/x.gd", "ref:Travel") == null);
}

test "gdscript: unresolved references are hidden from forward dependency listings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("scripts/clay/clay_blob.gd", "class_name ClayBlob\n");

    try testing.expectEqualStrings(
        "scripts/clay/clay_blob.gd",
        deps.displayDependency(&explorer, "scripts/user.gd", "ref:ClayBlob").?,
    );
    try testing.expect(deps.displayDependency(&explorer, "scripts/user.gd", "ref:Unknown") == null);
    try testing.expectEqualStrings("Node", deps.displayDependency(&explorer, "scripts/user.gd", "Node").?);
}

test "gdscript: scene connections link to the target script and label callers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Main.tscn",
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://scripts/main.gd" id="1_abc"]
        \\[ext_resource type="Script" path="res://scripts/button.gd" id="2_def"]
        \\
        \\[node name="Main" type="Node2D"]
        \\script = ExtResource("1_abc")
        \\
        \\[node name="Button" type="Button" parent="."]
        \\script = ExtResource("2_def")
        \\
        \\[node name="Label" type="Label" parent="."]
        \\
        \\[connection signal="pressed" from="Button" to="." method="_on_pressed"]
        \\[connection signal="toggled" from="Button" to="Button" method="_on_toggled"]
        \\[connection signal="timeout" from="Button" to="Label" method="_missing"]
        \\[connection signal="broken" from="Button" to="Label" method=]
    );

    const outline = explorer.outlines.get("Main.tscn").?;

    // The root's script is main.gd; a child's is button.gd. A target without a
    // script keeps the plain wiring detail.
    const pressed = findSymbol(outline, "pressed").?;
    try testing.expectEqualStrings("from=Button to=. method=_on_pressed script=scripts/main.gd", pressed.detail.?);
    const toggled = findSymbol(outline, "toggled").?;
    try testing.expectEqualStrings("from=Button to=Button method=_on_toggled script=scripts/button.gd", toggled.detail.?);
    const timeout = findSymbol(outline, "timeout").?;
    try testing.expectEqualStrings("from=Button to=Label method=_missing", timeout.detail.?);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "pressed -> _on_pressed (scripts/main.gd)",
        gp.connectionLabel("pressed", pressed.detail.?, &buf).?,
    );
    try testing.expectEqualStrings("timeout -> _missing", gp.connectionLabel("timeout", timeout.detail.?, &buf).?);
    // A method-less connection is not a handler, so it has no wiring label.
    try testing.expect(gp.connectionLabel("broken", "from=Button to=Label", &buf) == null);
}

test "gdscript: a connection written before its target node stays unlinked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Early.tscn",
        \\[ext_resource type="Script" path="res://scripts/main.gd" id="1_abc"]
        \\[connection signal="pressed" from="Button" to="." method="_on_pressed"]
        \\[node name="Main" type="Node2D"]
        \\script = ExtResource("1_abc")
    );

    const outline = explorer.outlines.get("Early.tscn").?;
    const pressed = findSymbol(outline, "pressed").?;
    try testing.expectEqualStrings("from=Button to=. method=_on_pressed", pressed.detail.?);
}

// ── CRLF, function-local declarations, class_name bases, typed signatures ──

test "gdscript: CRLF blank lines keep an inner class scope (method vs function)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // Every line ends in CRLF, as Windows-authored Godot scripts do. The blank
    // line between two methods used to read as a column-0 statement.
    try explorer.indexFile("crlf.gd", "class_name Hud\r\nextends Control\r\n\r\n" ++
        "class Rule extends Control:\r\n" ++
        "\tfunc _init() -> void:\r\n" ++
        "\t\tpass\r\n" ++
        "\r\n" ++
        "\tfunc _draw() -> void:\r\n" ++
        "\t\tpass\r\n");

    const outline = explorer.outlines.get("crlf.gd").?;
    try testing.expectEqual(SymbolKind.method, findSymbol(outline, "_init").?.kind);
    try testing.expectEqual(SymbolKind.method, findSymbol(outline, "_draw").?.kind);
    // The detail is the trimmed line: no trailing CR leaks into it.
    try testing.expectEqualStrings("func _draw() -> void:", findSymbol(outline, "_draw").?.detail.?);
}

test "gdscript: function-local var and const are not outline symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "class_name Spawner\n" ++
        "var lane_count: int = 0\n" ++
        "\n" ++
        "func spawn(n: int) -> int:\n" ++
        "\tvar spawned: int = n * 2\n" ++
        "\tconst LIMIT := 8\n" ++
        "\tif spawned > LIMIT:\n" ++
        "\t\tvar clipped: int = LIMIT\n" ++
        "\t\treturn clipped\n" ++
        "\treturn spawned\n" ++
        "\n" ++
        "var after_func: float = 1.0\n";
    try explorer.indexFile("locals.gd", src);

    const outline = explorer.outlines.get("locals.gd").?;
    try testing.expect(findSymbol(outline, "lane_count") != null);
    try testing.expect(findSymbol(outline, "after_func") != null);
    try testing.expect(findSymbol(outline, "spawned") == null);
    try testing.expect(findSymbol(outline, "LIMIT") == null);
    try testing.expect(findSymbol(outline, "clipped") == null);
}

test "gdscript: a bare closing paren of a multi-line signature keeps the function scope" {
    var st: gp.GdState = .{};
    _ = gp.parseGdLine("func build(", "func build(", &st);
    _ = gp.parseGdLine("\ta: int,", "a: int,", &st);
    _ = gp.parseGdLine(")", ")", &st);
    const r = gp.parseGdLine("\tvar inner: int = 1", "var inner: int = 1", &st);
    try testing.expectEqual(gp.ParsedLine.none, r);
}

test "gdscript: top-level extends on the line after class_name becomes the class base" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Enemy.gd", "class_name ClayEnemy\nextends CharacterBody3D\n");
    try explorer.indexFile("Boss.gd", "class_name ClayBoss\nextends ClayEnemy\n");

    const enemy_bases = explorer.type_graph.getBases("ClayEnemy");
    try testing.expectEqual(@as(usize, 1), enemy_bases.len);
    try testing.expectEqualStrings("CharacterBody3D", enemy_bases[0]);

    const enemy_derived = explorer.type_graph.getDerived("ClayEnemy");
    try testing.expectEqual(@as(usize, 1), enemy_derived.len);
    try testing.expectEqualStrings("ClayBoss", enemy_derived[0]);
}

test "gdscript: typed parameters and return type are recorded on the function symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "extends Node\n" ++
        "func on_enemy_spawned(enemy: ClayEnemy, wave_id: int = 0) -> ClayEnemy:\n" ++
        "\treturn enemy\n";
    try explorer.indexFile("wave.gd", src);

    const outline = explorer.outlines.get("wave.gd").?;
    const sym = findSymbol(outline, "on_enemy_spawned").?;
    try testing.expectEqualStrings("ClayEnemy", sym.return_type.?);
    try testing.expectEqual(@as(usize, 2), sym.param_types.len);
    try testing.expectEqualStrings("ClayEnemy", sym.param_types[0]);
    try testing.expectEqualStrings("int", sym.param_types[1]);

    const hits = explorer.type_index.findByParamType("ClayEnemy");
    try testing.expect(hits.len >= 1);
}

test "shader: top-level declarations and includes are outlined, function locals are not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "shader_type spatial;\n" ++
        "render_mode unshaded;\n" ++
        "#include \"res://shaders/lib.gdshaderinc\"\n" ++
        "/* block comment\n" ++
        "uniform float hidden = 0.0;\n" ++
        "*/\n" ++
        "uniform float speed = 1.0; // trailing comment\n" ++
        "uniform sampler2D albedo_tex : source_color;\n" ++
        "const float SCALE = 2.0;\n" ++
        "varying vec3 v_pos;\n" ++
        "void fragment() {\n" ++
        "\tfloat local_value = speed;\n" ++
        "\tALBEDO = vec3(local_value);\n" ++
        "}\n";
    try explorer.indexFile("clay.gdshader", src);

    const outline = explorer.outlines.get("clay.gdshader").?;
    try testing.expectEqual(explore.Language.gdshader, outline.language);
    try testing.expectEqual(SymbolKind.variable, findSymbol(outline, "speed").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSymbol(outline, "albedo_tex").?.kind);
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "SCALE").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSymbol(outline, "v_pos").?.kind);
    try testing.expectEqual(SymbolKind.function, findSymbol(outline, "fragment").?.kind);
    try testing.expect(findSymbol(outline, "local_value") == null);
    try testing.expect(findSymbol(outline, "hidden") == null); // inside a block comment
    try testing.expect(hasImport(outline, "shaders/lib.gdshaderinc"));
    try testing.expect(!hasImport(outline, "shader_type"));
}

test "shader: file extensions map to the gdshader language" {
    try testing.expectEqual(explore.Language.gdshader, explore.detectLanguage("shaders/clay.gdshader"));
    try testing.expectEqual(explore.Language.gdshader, explore.detectLanguage("shaders/common.gdshaderinc"));
    try testing.expectEqual(explore.Language.unknown, explore.detectLanguage("shaders/notes.txt"));
}

test "gdscript: an unnamed script is not labelled by its inner class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "extends Control\n" ++
        "class HudSlot extends Control:\n" ++
        "\tfunc _init() -> void:\n" ++
        "\t\tpass\n";
    try explorer.indexFile("drive_hud.gd", src);

    const outline = explorer.outlines.get("drive_hud.gd").?;
    const descriptor = try Explorer.buildOutlineDescriptor(testing.allocator, &outline);
    defer testing.allocator.free(descriptor);
    try testing.expect(std.mem.indexOf(u8, descriptor, "HudSlot") == null);
    try testing.expect(std.mem.indexOf(u8, descriptor, "1 functions") != null or std.mem.indexOf(u8, descriptor, "1 methods") != null);
}

test "shader: braces inside an include path do not change the scope depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "#include \"res://shaders/odd{name}.gdshaderinc\"\n" ++
        "uniform float after_include = 1.0;\n" ++
        "void fragment() {\n" ++
        "\tfloat inside = 1.0;\n" ++
        "}\n" ++
        "uniform float after_function = 2.0;\n";
    try explorer.indexFile("braces.gdshader", src);

    const outline = explorer.outlines.get("braces.gdshader").?;
    try testing.expect(findSymbol(outline, "after_include") != null);
    try testing.expect(findSymbol(outline, "after_function") != null);
    try testing.expect(findSymbol(outline, "inside") == null);
}

test "tree summary: a GDScript class lists both its functions and its methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const src = "class_name Hub\n" ++
        "extends Control\n" ++
        "static func helper() -> int:\n" ++
        "\treturn 1\n" ++
        "static func other() -> int:\n" ++
        "\treturn 2\n" ++
        "class Inner extends Control:\n" ++
        "\tfunc _draw() -> void:\n" ++
        "\t\tpass\n";
    try explorer.indexFile("hub.gd", src);

    const outline = explorer.outlines.get("hub.gd").?;
    const descriptor = try Explorer.buildOutlineDescriptor(testing.allocator, &outline);
    defer testing.allocator.free(descriptor);
    try testing.expect(std.mem.indexOf(u8, descriptor, "class_def Hub") != null);
    try testing.expect(std.mem.indexOf(u8, descriptor, "2 functions") != null);
    try testing.expect(std.mem.indexOf(u8, descriptor, "1 methods") != null);
}
