// codedb — line parsers for Godot projects: GDScript (.gd), scenes (.tscn),
// resources (.tres), and project.godot. Zero-dependency and line-based, in
// the style of t4_parser.zig / tsql_parser.zig. Returned slices point into
// the input line; callers dupe what they keep.
const std = @import("std");

/// Godot-specific symbol kinds, mapped to generic SymbolKind in lifecycle.zig.
pub const Kind = enum {
    class_name_decl, // class_name Foo
    inner_class, // class Foo: (nested in a script)
    function_def, // func foo(): at script top level
    method_def, // func foo(): inside an inner class
    signal_decl, // signal foo(a, b)
    variable_decl, // var x / @export var x
    constant_decl, // const X = 1
    enum_decl, // enum Foo { A, B }
    node_def, // [node name="Main" type="Node2D" ...]
    connection, // [connection signal="pressed" from=... to=... method=...]
    resource_def, // [gd_resource ... script_class="CardData"]
    input_action, // project.godot [input] action key
    section_header, // project.godot [section]
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    import: struct {
        path: []const u8,
    },
    annotation: struct {
        name: []const u8, // standalone @annotation line, e.g. "@export"
    },
};

/// Per-file parse state for GDScript.
pub const GdState = struct {
    in_multiline_string: bool = false,
    inner_class_indent: ?usize = null,
};

/// project.godot section tracking.
pub const ProjectSection = enum { none, autoload, input, other };

// ── GDScript ───────────────────────────────────────────────────────────────

pub fn parseGdLine(raw_line: []const u8, trimmed: []const u8, state: *GdState) ParsedLine {
    if (trimmed.len == 0) return .none;

    // Multiline ("""/''') string tracking: an odd number of markers on a
    // line toggles the state. Inside one, nothing is a declaration.
    if (state.in_multiline_string) {
        if (countTripleQuotes(trimmed) % 2 == 1) state.in_multiline_string = false;
        return .none;
    }

    const line = stripGdComment(trimmed);
    if (line.len == 0) return .none;
    if (countTripleQuotes(line) % 2 == 1) state.in_multiline_string = true;

    const indent = leadingIndent(raw_line);
    // Any declaration at or below the inner class's own indent leaves its scope.
    if (state.inner_class_indent) |ci| {
        if (indent <= ci) state.inner_class_indent = null;
    }

    if (line[0] == '@') {
        const rest = skipAnnotations(line);
        if (rest.len == 0) return .{ .annotation = .{ .name = firstAnnotationName(line) } };
        return parseGdDecl(rest, indent, state);
    }
    return parseGdDecl(line, indent, state);
}

fn parseGdDecl(line: []const u8, indent: usize, state: *GdState) ParsedLine {
    if (std.mem.startsWith(u8, line, "class_name ")) {
        const name = extractIdent(line["class_name ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .class_name_decl } };
    }
    if (std.mem.startsWith(u8, line, "extends ")) {
        const target = std.mem.trim(u8, line["extends ".len..], " \t");
        if (target.len >= 2 and (target[0] == '"' or target[0] == '\'')) {
            // extends "res://base.gd" (GDScript accepts either quote style)
            const quote = target[0];
            const inner = target[1..];
            const end = std.mem.indexOfScalar(u8, inner, quote) orelse return .none;
            return .{ .import = .{ .path = stripResPrefix(inner[0..end]) } };
        }
        const name = extractIdent(target) orelse return .none;
        return .{ .import = .{ .path = name } };
    }
    if (std.mem.startsWith(u8, line, "class ")) {
        const name = extractIdent(line["class ".len..]) orelse return .none;
        state.inner_class_indent = indent;
        return .{ .symbol = .{ .name = name, .kind = .inner_class } };
    }
    var rest = line;
    if (std.mem.startsWith(u8, rest, "static ")) rest = rest["static ".len..];
    if (std.mem.startsWith(u8, rest, "func ")) {
        const name = extractIdent(rest["func ".len..]) orelse return .none;
        const kind: Kind = if (state.inner_class_indent) |ci|
            (if (indent > ci) .method_def else .function_def)
        else
            .function_def;
        return .{ .symbol = .{ .name = name, .kind = kind } };
    }
    if (std.mem.startsWith(u8, rest, "signal ")) {
        const name = extractIdent(rest["signal ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .signal_decl } };
    }
    if (std.mem.startsWith(u8, rest, "var ")) {
        const name = extractIdent(rest["var ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable_decl } };
    }
    if (std.mem.startsWith(u8, rest, "const ")) {
        const name = extractIdent(rest["const ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .constant_decl } };
    }
    if (std.mem.startsWith(u8, rest, "enum ")) {
        const name = extractIdent(rest["enum ".len..]) orelse "enum";
        return .{ .symbol = .{ .name = name, .kind = .enum_decl } };
    }
    return .none;
}

/// Find a preload("res://...") or load("res://...") reference on a line.
/// Returns the project-relative path (res:// stripped), or null. Only
/// res:// paths count — user:// and absolute paths are runtime-only.
/// Both quote styles are accepted, and `my_load(` / `foo.preload(` style
/// identifiers are not mistaken for the Godot calls.
pub fn extractResPath(line: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "preload(\"", "preload('", "load(\"", "load('" };
    for (needles) |needle| {
        const quote = needle[needle.len - 1];
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, needle)) |pos| {
            from = pos + 1;
            // "load(" also matches inside "preload(" (handled by its own
            // needle), and identifiers such as "my_load(" are not calls.
            if (pos > 0 and isIdentChar(line[pos - 1])) continue;
            const rest = line[pos + needle.len ..];
            const end = std.mem.indexOfScalar(u8, rest, quote) orelse break;
            const path = rest[0..end];
            if (std.mem.startsWith(u8, path, "res://")) return path["res://".len..];
        }
    }
    return null;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Strip a trailing `#` comment, respecting single/double-quoted strings.
/// Public: the lifecycle dispatch also strips comments before scanning for
/// preload()/load() imports, so commented-out code can't create dep edges.
pub fn stripGdComment(line: []const u8) []const u8 {
    var in_str: u8 = 0; // 0 = outside strings, else the active quote char
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 1; // skip escaped char
            } else if (ch == in_str) {
                in_str = 0;
            }
        } else if (ch == '"' or ch == '\'') {
            in_str = ch;
        } else if (ch == '#') {
            return std.mem.trimEnd(u8, line[0..i], " \t");
        }
    }
    return line;
}

fn countTripleQuotes(line: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= line.len) {
        if (std.mem.eql(u8, line[i .. i + 3], "\"\"\"") or
            std.mem.eql(u8, line[i .. i + 3], "'''"))
        {
            count += 1;
            i += 3;
        } else {
            i += 1;
        }
    }
    return count;
}

/// Leading whitespace count. Tabs and spaces each count as one — enough to
/// order nesting levels within one file; mixed indentation degrades but
/// never crashes.
fn leadingIndent(raw_line: []const u8) usize {
    var i: usize = 0;
    while (i < raw_line.len and (raw_line[i] == ' ' or raw_line[i] == '\t')) i += 1;
    return i;
}

/// Skip leading @annotations (with optional (args)); returns the rest, trimmed.
fn skipAnnotations(line: []const u8) []const u8 {
    var rest = line;
    while (rest.len > 0 and rest[0] == '@') {
        var i: usize = 1;
        while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_')) i += 1;
        if (i < rest.len and rest[i] == '(') {
            var depth: usize = 0;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '(') depth += 1;
                if (rest[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
        }
        rest = std.mem.trimStart(u8, rest[i..], " \t");
    }
    return rest;
}

/// "@export_range(0, 10) ..." -> "@export_range"
fn firstAnnotationName(line: []const u8) []const u8 {
    var i: usize = 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
    return line[0..i];
}

fn extractIdent(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return null;
    var i: usize = 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    return text[0..i];
}

/// Strip Godot resource-path prefixes: leading autoload '*' and res://.
fn stripResPrefix(path: []const u8) []const u8 {
    var p = path;
    if (p.len > 0 and p[0] == '*') p = p[1..];
    if (std.mem.startsWith(u8, p, "res://")) return p["res://".len..];
    return p;
}

// ── Scenes (.tscn) and resources (.tres) ───────────────────────────────────
// Godot's text formats are INI-like: [section key="value" ...] headers
// followed by key = value property lines. Only headers carry cross-file
// signal; property lines are ignored.

pub fn parseSceneLine(trimmed: []const u8) ParsedLine {
    if (trimmed.len == 0 or trimmed[0] != '[') return .none;
    if (std.mem.startsWith(u8, trimmed, "[ext_resource")) {
        const path = extractQuotedAttr(trimmed, "path") orelse return .none;
        return .{ .import = .{ .path = stripResPrefix(path) } };
    }
    if (std.mem.startsWith(u8, trimmed, "[node ")) {
        const name = extractQuotedAttr(trimmed, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .node_def } };
    }
    if (std.mem.startsWith(u8, trimmed, "[connection ")) {
        const sig = extractQuotedAttr(trimmed, "signal") orelse return .none;
        return .{ .symbol = .{ .name = sig, .kind = .connection } };
    }
    if (std.mem.startsWith(u8, trimmed, "[gd_resource")) {
        const cls = extractQuotedAttr(trimmed, "script_class") orelse return .none;
        return .{ .symbol = .{ .name = cls, .kind = .resource_def } };
    }
    return .none; // [gd_scene], [sub_resource], [resource], [editable ...]
}

// ── project.godot ──────────────────────────────────────────────────────────

pub fn parseProjectLine(trimmed: []const u8, section: *ProjectSection) ParsedLine {
    if (trimmed.len == 0) return .none;
    if (trimmed[0] == '[') {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return .none;
        const name = trimmed[1..end];
        if (name.len == 0) return .none;
        section.* = if (std.mem.eql(u8, name, "autoload"))
            .autoload
        else if (std.mem.eql(u8, name, "input"))
            .input
        else
            .other;
        return .{ .symbol = .{ .name = name, .kind = .section_header } };
    }
    switch (section.*) {
        .autoload => {
            // GameState="*res://GameState.gd" — the '*' marks an autoload node
            const path = autoloadResPath(trimmed) orelse return .none;
            return .{ .import = .{ .path = path } };
        },
        .input => {
            // place_tower={ "deadzone": 0.5, ... } — only the key line matters
            const brace = std.mem.indexOf(u8, trimmed, "={") orelse return .none;
            const key = std.mem.trim(u8, trimmed[0..brace], " \t");
            const name = extractIdent(key) orelse return .none;
            if (name.len != key.len) return .none; // reject e.g. quoted keys
            return .{ .symbol = .{ .name = name, .kind = .input_action } };
        },
        .none, .other => return .none,
    }
}

// ── Detail extraction ──────────────────────────────────────────────────────

/// Structured detail for scene symbols. Returns "" for kinds whose detail is
/// just the source line (callers fall back to the trimmed line).
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    switch (kind) {
        .node_def => {
            var len: usize = 0;
            len = appendAttrDetail(line, "type", "type=", buf, len);
            len = appendAttrDetail(line, "parent", if (len == 0) "parent=" else " parent=", buf, len);
            return buf[0..len];
        },
        .connection => {
            var len: usize = 0;
            len = appendAttrDetail(line, "from", "from=", buf, len);
            len = appendAttrDetail(line, "to", if (len == 0) "to=" else " to=", buf, len);
            len = appendAttrDetail(line, "method", if (len == 0) "method=" else " method=", buf, len);
            return buf[0..len];
        },
        else => return "",
    }
}

fn appendAttrDetail(line: []const u8, attr: []const u8, prefix: []const u8, buf: []u8, len_in: usize) usize {
    var len = len_in;
    const val = extractQuotedAttr(line, attr) orelse return len;
    if (len + prefix.len + val.len > buf.len) return len;
    @memcpy(buf[len .. len + prefix.len], prefix);
    len += prefix.len;
    @memcpy(buf[len .. len + val.len], val);
    len += val.len;
    return len;
}

/// Extract attr="value" from a section header, respecting escaped quotes and
/// requiring a word boundary before the attribute name (so `signal=` does not
/// match inside `my_signal=`). Returns null on missing or unterminated value.
fn extractQuotedAttr(line: []const u8, attr: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (attr.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..attr.len], attr);
    needle_buf[attr.len] = '=';
    needle_buf[attr.len + 1] = '"';
    const needle = needle_buf[0 .. attr.len + 2];

    var search_from: usize = 0;
    const start = blk: while (std.mem.indexOfPos(u8, line, search_from, needle)) |pos| {
        if (pos == 0 or line[pos - 1] == ' ' or line[pos - 1] == '[') break :blk pos;
        search_from = pos + 1;
    } else return null;

    const vstart = start + needle.len;
    var i = vstart;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // skip escaped char
        } else if (line[i] == '"') {
            return line[vstart..i];
        }
    }
    return null; // unterminated value
}

// ── GDScript references, autoloads, and scene wiring ───────────────────────
// Reference dependency keys carry `ref_prefix`. deps.zig resolves them at
// query time against class_name declarations and project.godot autoloads, so
// a key stays only a name until a question asks what it refers to.

pub const ref_prefix = "ref:";

/// Maximum type-annotation texts reported for one declaration line.
pub const max_annotations = 32;

/// Built-in types and engine singletons. They never name a project file, so
/// references to them are not recorded.
pub fn isBuiltinGdType(name: []const u8) bool {
    const names = [_][]const u8{
        "void",         "bool",          "int",               "float",          "String",
        "StringName",   "NodePath",      "Variant",           "Vector2",        "Vector2i",
        "Vector3",      "Vector3i",      "Vector4",           "Vector4i",       "Rect2",
        "Rect2i",       "Transform2D",   "Transform3D",       "Plane",          "Quaternion",
        "AABB",         "Basis",         "Projection",        "Color",          "RID",
        "Object",       "Callable",      "Signal",            "Dictionary",     "Array",
        "PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array",
        "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array",
        "PackedColorArray", "Input",     "Engine",            "OS",             "Time",
        "Math",
    };
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Type-annotation texts of a declaration line (`var x: T`, `const X: T`,
/// `func f(a: A, b: B) -> R`, `signal s(a: A)`), as slices of `detail`.
/// Declarations are cut at their initializer, so a dictionary literal's
/// colons are not read as types; `:=` infers and is not an annotation.
pub fn typeAnnotations(detail: []const u8, out: *[max_annotations][]const u8) usize {
    var n: usize = 0;
    var text = detail;
    if (std.mem.indexOf(u8, detail, "func ") == null) {
        if (std.mem.indexOfScalar(u8, detail, '=')) |eq| {
            text = detail[0 .. if (eq > 0 and detail[eq - 1] == ':') eq - 1 else eq];
        }
    }
    if (std.mem.indexOf(u8, text, "->")) |arrow| {
        const ret = std.mem.trim(u8, text[arrow + 2 ..], " \t:");
        if (ret.len > 0) {
            out[n] = ret;
            n += 1;
        }
        text = text[0..arrow];
    }
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':' or (i + 1 < text.len and text[i + 1] == '=')) continue;
        const start = i + 1;
        var j = start;
        var depth: usize = 0; // commas inside Array[A, B] do not end the type
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (c == '[') {
                depth += 1;
            } else if (c == ']') {
                if (depth > 0) depth -= 1;
            } else if (depth == 0 and (c == ',' or c == ')' or c == '=' or c == ':')) {
                break;
            }
        }
        const t = std.mem.trim(u8, text[start..j], " \t");
        if (t.len > 0 and n < max_annotations) {
            out[n] = t;
            n += 1;
        }
        i = j;
    }
    return n;
}

/// Iterates the type names in a type text: `Array[ClayBlob]` yields Array and
/// ClayBlob; a qualifier such as `Outer` in `Outer.Inner` is skipped.
pub fn nextTypeName(text: []const u8, pos: *usize) ?[]const u8 {
    var i = pos.*;
    while (i < text.len) {
        if (!isIdentStart(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isIdentChar(text[i])) i += 1;
        pos.* = i;
        if (i < text.len and text[i] == '.') continue;
        return text[start..i];
    }
    pos.* = i;
    return null;
}

/// Iterates `Name.member` receivers in masked source (comments and strings
/// already blanked). Only capitalized names count: Godot class and autoload
/// names follow that convention, while lowercase names are locals.
pub fn nextReceiver(masked: []const u8, pos: *usize) ?[]const u8 {
    var i = pos.*;
    while (i < masked.len) {
        if (!isIdentStart(masked[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < masked.len and isIdentChar(masked[i])) i += 1;
        const bounded = start == 0 or (!isIdentChar(masked[start - 1]) and masked[start - 1] != '.');
        const member = i + 1 < masked.len and masked[i] == '.' and isIdentStart(masked[i + 1]);
        if (bounded and member and std.ascii.isUpper(masked[start])) {
            pos.* = i;
            return masked[start..i];
        }
    }
    pos.* = i;
    return null;
}

/// `Name="*res://path.gd"` in [autoload] → the singleton name.
pub fn autoloadName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const name = std.mem.trim(u8, line[0..eq], " \t");
    const ident = extractIdent(name) orelse return null;
    return if (ident.len == name.len) ident else null;
}

/// Project-relative script path of an [autoload] entry ('*' and res:// stripped).
pub fn autoloadResPath(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (value.len < 2 or value[0] != '"') return null;
    const inner = value[1..];
    const close = std.mem.indexOfScalar(u8, inner, '"') orelse return null;
    return stripResPrefix(inner[0..close]);
}

/// Quoted attribute value of a scene header (`name="..."`), or null.
pub fn quotedAttr(line: []const u8, name: []const u8) ?[]const u8 {
    return extractQuotedAttr(line, name);
}

/// `script = ExtResource("1_abc")` property line → the ext_resource id.
pub fn nodeScriptId(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "script")) return null;
    const rest = std.mem.trimStart(u8, line["script".len..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    const ext = std.mem.indexOf(u8, rest, "ExtResource(") orelse return null;
    const after = rest[ext + "ExtResource(".len ..];
    const open = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const id = after[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, id, '"') orelse return null;
    return id[0..close];
}

/// Scene-tree path of a [node] header relative to the scene root ("." for the
/// root, which has no parent attribute). Children of the root are "name".
pub fn nodePath(alloc: std.mem.Allocator, parent: ?[]const u8, name: []const u8) ![]const u8 {
    const p = parent orelse return ".";
    if (std.mem.eql(u8, p, ".")) return name;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ p, name });
}

/// Per-scene wiring state. Godot writes ext_resource headers first, nodes
/// next, and [connection] lines last, so one streaming pass has every target
/// node before the connection that names it. Connections written out of that
/// order simply stay unlinked.
pub const SceneWiring = struct {
    alloc: std.mem.Allocator,
    ext_paths: std.StringHashMap([]const u8), // ext id -> project-relative script path
    node_scripts: std.StringHashMap([]const u8), // node path -> ext id
    current_node: ?[]const u8 = null, // node whose property lines follow its header

    pub fn init(alloc: std.mem.Allocator) SceneWiring {
        return .{
            .alloc = alloc,
            .ext_paths = std.StringHashMap([]const u8).init(alloc),
            .node_scripts = std.StringHashMap([]const u8).init(alloc),
        };
    }

    /// Feed one trimmed line in file order.
    pub fn observe(self: *SceneWiring, trimmed: []const u8) !void {
        if (trimmed.len == 0) return;
        if (trimmed[0] != '[') {
            if (self.current_node) |node| {
                if (nodeScriptId(trimmed)) |id| try self.node_scripts.put(node, id);
            }
            return;
        }
        self.current_node = null;
        if (std.mem.startsWith(u8, trimmed, "[ext_resource")) {
            const id = quotedAttr(trimmed, "id") orelse return;
            const path = quotedAttr(trimmed, "path") orelse return;
            try self.ext_paths.put(id, stripResPrefix(path));
        } else if (std.mem.startsWith(u8, trimmed, "[node ")) {
            const name = quotedAttr(trimmed, "name") orelse return;
            self.current_node = try nodePath(self.alloc, quotedAttr(trimmed, "parent"), name);
        }
    }

    /// Script path used by the node at `node_path`, or null.
    pub fn scriptForNode(self: *const SceneWiring, node_path: []const u8) ?[]const u8 {
        const id = self.node_scripts.get(node_path) orelse return null;
        return self.ext_paths.get(id);
    }

    /// Detail for a [connection] symbol: from/to/method, plus `script=` when the
    /// target node has a script. Built into `buf`; the result is a slice of it.
    pub fn connectionDetail(self: *const SceneWiring, trimmed: []const u8, buf: []u8) []const u8 {
        var base_buf: [256]u8 = undefined;
        const base = extractDetail(trimmed, .connection, &base_buf);
        const to = quotedAttr(trimmed, "to") orelse "";
        const out = if (self.scriptForNode(to)) |script|
            std.fmt.bufPrint(buf, "{s} script={s}", .{ base, script })
        else
            std.fmt.bufPrint(buf, "{s}", .{base});
        return out catch buf[0..0];
    }
};

/// Scope label for a scene connection line, e.g. `pressed -> _on_pressed (scripts/x.gd)`.
/// Null when the detail carries no method (not a connection symbol).
pub fn connectionLabel(signal: []const u8, detail: []const u8, buf: []u8) ?[]const u8 {
    const method = detailValue(detail, "method=") orelse return null;
    if (method.len == 0) return null;
    const out = if (detailValue(detail, "script=")) |script|
        std.fmt.bufPrint(buf, "{s} -> {s} ({s})", .{ signal, method, script })
    else
        std.fmt.bufPrint(buf, "{s} -> {s}", .{ signal, method });
    return out catch null;
}

fn detailValue(detail: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, detail, ' ');
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, key)) return tok[key.len..];
    }
    return null;
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}
