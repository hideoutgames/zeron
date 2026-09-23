#!/usr/bin/env python3
"""Generate mobile/Generated from Zeron's Rust/Serde declarations.

Deterministic and narrow: it understands the serde attributes Zeron actually
uses. Anything else stops generation with a review error instead of guessing.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOBILE = HERE.parent
REPO = MOBILE.parent
OUT = MOBILE / "Generated"

PRIMITIVES = {
    "String": "String",
    "bool": "Bool",
    "i32": "Int",
    "u32": "Int",
    "i64": "Int",
    "u64": "Int",
    "usize": "Int",
    "f32": "Double",
    "f64": "Double",
    "DateTime<Utc>": "Date",
    "serde_json::Value": "JSONValue",
    "serde_json::Map<String, serde_json::Value>": "[String: JSONValue]",
}

DEFAULTS = {"Bool": "false", "Int": "0", "Double": "0", "String": '""'}

SWIFT_KEYWORDS = {"default", "repeat", "in", "as", "is", "self", "case", "class", "struct", "enum", "func", "var", "let", "import", "return", "true", "false", "nil", "operator", "protocol", "static", "where", "while", "for", "if", "else", "switch", "break", "continue", "do", "try", "catch", "throw", "throws", "init", "deinit", "extension", "public", "private", "internal", "open"}

SUPPORTED_CONTAINER_ATTRS = {"rename_all", "tag", "untagged"}
SUPPORTED_FIELD_ATTRS = {"default", "skip_serializing_if", "rename"}


class ReviewRequired(Exception):
    pass


@dataclass
class Field:
    name: str
    rust_type: str
    attrs: dict[str, str | None] = field(default_factory=dict)


@dataclass
class Variant:
    name: str
    fields: list[Field]
    attrs: dict[str, str | None]


@dataclass
class Decl:
    kind: str  # struct | enum
    name: str
    attrs: dict[str, str | None]
    fields: list[Field] = field(default_factory=list)
    variants: list[Variant] = field(default_factory=list)


# ---------------------------------------------------------------- parsing

ATTR_RE = re.compile(r"#\[serde\(([^)]*)\)\]")
DECL_RE = re.compile(r"^pub (struct|enum) (\w+)(<[^>]*>)?\s*\{", re.M)


def strip_comments(src: str) -> str:
    return "\n".join(line for line in src.splitlines() if not line.strip().startswith("//"))


def parse_attrs(text: str) -> dict[str, str | None]:
    attrs: dict[str, str | None] = {}
    for match in ATTR_RE.finditer(text):
        for part in match.group(1).split(","):
            key, _, value = part.strip().partition("=")
            attrs[key.strip()] = value.strip().strip('"') if value else None
    return attrs


def leading_attrs(src: str, end: int) -> str:
    """Attribute lines directly above position `end`."""
    lines = src[:end].splitlines()
    collected = []
    for line in reversed(lines):
        if line.strip().startswith("#["):
            collected.append(line)
        else:
            break
    return "\n".join(reversed(collected))


def block_body(src: str, open_brace: int) -> tuple[str, int]:
    depth = 0
    for i in range(open_brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[open_brace + 1 : i], i
    raise ReviewRequired("unbalanced braces")


def split_items(body: str) -> list[str]:
    """Split a struct/enum body into top-level items (fields or variants)."""
    items, depth, current = [], 0, []
    for ch in body:
        if ch in "{<(":
            depth += 1
        elif ch in "}>)":
            depth -= 1
        if ch == "," and depth == 0:
            items.append("".join(current))
            current = []
        else:
            current.append(ch)
    tail = "".join(current)
    if tail.strip():
        items.append(tail)
    return items


def parse_fields(body: str) -> list[Field]:
    fields = []
    for item in split_items(body):
        item = item.strip()
        if not item:
            continue
        attrs = parse_attrs(item)
        signature = ATTR_RE.sub("", item).strip()
        match = re.match(r"(?:pub(?:\([^)]*\))?\s+)?(\w+)\s*:\s*(.+)$", signature, re.S)
        if not match:
            raise ReviewRequired(f"cannot parse field: {signature!r}")
        fields.append(Field(match.group(1), " ".join(match.group(2).split()), attrs))
    return fields


def parse_variants(body: str) -> list[Variant]:
    variants = []
    i = 0
    while i < len(body):
        match = re.compile(r"((?:\s*#\[[^\]]*\]\s*)*)\s*(\w+)\s*(\{|,|$)", re.M).match(body, i)
        if not match:
            break
        attrs = parse_attrs(match.group(1))
        name = match.group(2)
        if match.group(3) == "{":
            inner, close = block_body(body, match.end() - 1)
            variants.append(Variant(name, parse_fields(inner), attrs))
            i = close + 1
            comma = body.find(",", i)
            i = comma + 1 if comma != -1 else len(body)
        else:
            variants.append(Variant(name, [], attrs))
            i = match.end()
    return variants


def parse_file(path: Path) -> dict[str, Decl]:
    src = strip_comments(path.read_text())
    decls = {}
    for match in DECL_RE.finditer(src):
        kind, name, generics = match.group(1), match.group(2), match.group(3)
        attr_text = leading_attrs(src, match.start())
        if "Serialize" not in attr_text and "Deserialize" not in attr_text:
            continue
        if generics:
            raise ReviewRequired(f"{name}: generic types are not supported")
        attrs = parse_attrs(attr_text)
        body, _ = block_body(src, match.end() - 1)
        decl = Decl(kind, name, attrs)
        if kind == "struct":
            decl.fields = parse_fields(body)
        else:
            decl.variants = parse_variants(body)
        decls[name] = decl
    return decls


# ---------------------------------------------------------------- naming

def camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(part.capitalize() for part in rest)


def wire_name(name: str, rule: str | None) -> str:
    if rule is None:
        return name
    if rule == "camelCase":
        return camel(name) if "_" in name else name[0].lower() + name[1:]
    if rule == "lowercase":
        return name.lower()
    if rule == "kebab-case":
        return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower() if "_" not in name else name.replace("_", "-")
    if rule == "snake_case":
        return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()
    raise ReviewRequired(f"unsupported rename_all: {rule}")


def swift_ident(name: str) -> str:
    ident = camel(name) if "_" in name else name
    return f"`{ident}`" if ident in SWIFT_KEYWORDS else ident


def variant_case(name: str) -> str:
    return swift_ident(name[0].lower() + name[1:])


# ---------------------------------------------------------------- generation

class Generator:
    def __init__(self, mapping: dict, decls: dict[str, Decl]):
        self.mapping = mapping
        self.decls = decls
        self.emitted: dict[str, str] = {}
        self.pending: list[str] = list(mapping["roots"])
        self.lenient = set(mapping.get("lenient", []))
        self.unknown_variant = set(mapping.get("unknownVariant", []))

    def run(self) -> str:
        while self.pending:
            name = self.pending.pop(0)
            if name in self.emitted:
                continue
            decl = self.decls.get(name)
            if decl is None:
                raise ReviewRequired(f"{name}: no Serialize/Deserialize declaration found in sources")
            self.emitted[name] = self.emit_decl(decl)
        return "\n\n".join(self.emitted[name] for name in sorted(self.emitted))

    # types

    def swift_type(self, rust: str, owner: str) -> str:
        if rust in PRIMITIVES:
            return PRIMITIVES[rust]
        for wrapper in ("Option", "Vec", "HashMap", "BTreeMap"):
            if rust.startswith(wrapper + "<") and rust.endswith(">"):
                inner = rust[len(wrapper) + 1 : -1]
                if wrapper == "Option":
                    return self.swift_type(inner, owner) + "?"
                if wrapper == "Vec":
                    return f"[{self.swift_type(inner, owner)}]"
                key, _, value = inner.partition(",")
                if key.strip() != "String":
                    raise ReviewRequired(f"{owner}: map key {key.strip()} is not String")
                return f"[String: {self.swift_type(value.strip(), owner)}]"
        bare = rust.rsplit("::", 1)[-1]
        if bare in self.decls:
            self.pending.append(bare)
            return bare
        raise ReviewRequired(f"{owner}: unsupported type {rust}")

    def default_value(self, swift: str, owner: str) -> str:
        if swift.endswith("?"):
            return "nil"
        if swift.startswith("["):
            return "[:]" if ":" in swift else "[]"
        if swift in DEFAULTS:
            return DEFAULTS[swift]
        raise ReviewRequired(f"{owner}: #[serde(default)] on {swift} needs a Default mapping")

    # structs

    def check_field_attrs(self, owner: str, attrs: dict):
        unsupported = set(attrs) - SUPPORTED_FIELD_ATTRS
        if unsupported:
            raise ReviewRequired(f"{owner}: unsupported serde field attributes {sorted(unsupported)}")

    def emit_struct(self, name: str, fields: list[Field], rename_all: str | None, indent: str = "") -> str:
        lines = [f"{indent}public struct {name}: Codable, Hashable, Sendable {{"]
        keys, inits, decodes = [], [], []
        needs_custom_decode = False
        for f in fields:
            owner = f"{name}.{f.name}"
            self.check_field_attrs(owner, f.attrs)
            swift = self.swift_type(f.rust_type, owner)
            ident = swift_ident(f.name)
            wire = f.attrs.get("rename") or wire_name(f.name, rename_all)
            keys.append(f'case {ident} = "{wire}"' if wire != ident.strip("`") else f"case {ident}")
            optional = swift.endswith("?")
            lenient = owner in self.lenient
            if lenient and not optional:
                raise ReviewRequired(f"{owner}: lenient fields must be Option")
            defaulted = "default" in f.attrs
            if defaulted and not optional:
                needs_custom_decode = True
                default = self.default_value(swift, owner)
                decodes.append(f"{ident} = try container.decodeIfPresent({swift}.self, forKey: .{ident}) ?? {default}")
            elif lenient:
                needs_custom_decode = True
                decodes.append(f"{ident} = try? container.decodeIfPresent({swift[:-1]}.self, forKey: .{ident})")
            elif optional:
                decodes.append(f"{ident} = try container.decodeIfPresent({swift[:-1]}.self, forKey: .{ident})")
            else:
                decodes.append(f"{ident} = try container.decode({swift}.self, forKey: .{ident})")
            lines.append(f"{indent}    public var {ident}: {swift}")
            inits.append(f"{ident}: {swift}" + (" = nil" if optional else (f" = {self.default_value(swift, owner)}" if defaulted else "")))
        if fields:
            lines.append("")
            lines.append(f"{indent}    public init({', '.join(inits)}) {{")
            lines.extend(f"{indent}        self.{swift_ident(f.name)} = {swift_ident(f.name)}" for f in fields)
            lines.append(f"{indent}    }}")
            lines.append("")
            lines.append(f"{indent}    enum CodingKeys: String, CodingKey {{")
            lines.extend(f"{indent}        {key}" for key in keys)
            lines.append(f"{indent}    }}")
        else:
            lines.append(f"{indent}    public init() {{}}")
        if needs_custom_decode:
            lines.append("")
            lines.append(f"{indent}    public init(from decoder: Decoder) throws {{")
            lines.append(f"{indent}        let container = try decoder.container(keyedBy: CodingKeys.self)")
            lines.extend(f"{indent}        {line}" for line in decodes)
            lines.append(f"{indent}    }}")
        lines.append(f"{indent}}}")
        return "\n".join(lines)

    # enums

    def emit_decl(self, decl: Decl) -> str:
        unsupported = set(decl.attrs) - SUPPORTED_CONTAINER_ATTRS
        if unsupported:
            raise ReviewRequired(f"{decl.name}: unsupported serde container attributes {sorted(unsupported)}")
        rename_all = decl.attrs.get("rename_all")
        if decl.kind == "struct":
            return self.emit_struct(decl.name, decl.fields, rename_all)
        if all(not v.fields for v in decl.variants) and "tag" not in decl.attrs:
            return self.emit_string_enum(decl, rename_all)
        if "untagged" in decl.attrs:
            return self.emit_untagged_enum(decl)
        if "tag" in decl.attrs:
            return self.emit_tagged_enum(decl, rename_all)
        raise ReviewRequired(f"{decl.name}: externally tagged enums with payloads are not supported")

    def emit_string_enum(self, decl: Decl, rename_all: str | None) -> str:
        lines = [f"public enum {decl.name}: String, Codable, Hashable, Sendable, CaseIterable {{"]
        for v in decl.variants:
            self.check_field_attrs(f"{decl.name}.{v.name}", {k: None for k in v.attrs if k != "rename"})
            wire = v.attrs.get("rename") or wire_name(v.name, rename_all)
            lines.append(f'    case {variant_case(v.name)} = "{wire}"')
        lines.append("}")
        return "\n".join(lines)

    def payload_structs(self, decl: Decl) -> list[str]:
        out = []
        for v in decl.variants:
            if v.fields:
                out.append(self.emit_struct(v.name, v.fields, v.attrs.get("rename_all"), indent="    "))
        return out

    def emit_tagged_enum(self, decl: Decl, rename_all: str | None) -> str:
        tag = decl.attrs["tag"]
        allow_unknown = decl.name in self.unknown_variant
        lines = [f"public enum {decl.name}: Codable, Hashable, Sendable {{"]
        for v in decl.variants:
            lines.append(f"    case {variant_case(v.name)}" + (f"({v.name})" if v.fields else ""))
        if allow_unknown:
            lines.append("    case unrecognized(kind: String)")
        lines.append("")
        lines.extend(self.payload_structs(decl))
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append(f'        let kind = try decoder.container(keyedBy: TagKey.self).decode(String.self, forKey: TagKey("{tag}"))')
        lines.append("        switch kind {")
        for v in decl.variants:
            wire = v.attrs.get("rename") or wire_name(v.name, rename_all)
            value = f"(try {v.name}(from: decoder))" if v.fields else ""
            lines.append(f'        case "{wire}": self = .{variant_case(v.name)}{value}')
        if allow_unknown:
            lines.append("        default: self = .unrecognized(kind: kind)")
        else:
            lines.append(f'        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown {decl.name} kind \\(kind)"))')
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var tag = encoder.container(keyedBy: TagKey.self)")
        lines.append("        switch self {")
        for v in decl.variants:
            wire = v.attrs.get("rename") or wire_name(v.name, rename_all)
            pattern = f".{variant_case(v.name)}" + ("(let payload)" if v.fields else "")
            body = f'try tag.encode("{wire}", forKey: TagKey("{tag}"))' + ("; try payload.encode(to: encoder)" if v.fields else "")
            lines.append(f"        case {pattern}: {body}")
        if allow_unknown:
            lines.append(f'        case .unrecognized(let kind): try tag.encode(kind, forKey: TagKey("{tag}"))')
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        return "\n".join(lines)

    def emit_untagged_enum(self, decl: Decl) -> str:
        if any(not v.fields for v in decl.variants):
            raise ReviewRequired(f"{decl.name}: untagged unit variants are ambiguous")
        lines = [f"public enum {decl.name}: Codable, Hashable, Sendable {{"]
        lines.extend(f"    case {variant_case(v.name)}({v.name})" for v in decl.variants)
        lines.append("")
        lines.extend(self.payload_structs(decl))
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        for v in decl.variants:
            lines.append(f"        if let payload = try? {v.name}(from: decoder) {{ self = .{variant_case(v.name)}(payload); return }}")
        lines.append(f'        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no {decl.name} variant matched"))')
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        switch self {")
        lines.extend(f"        case .{variant_case(v.name)}(let payload): try payload.encode(to: encoder)" for v in decl.variants)
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        return "\n".join(lines)

    # mobile-owned request and reply shapes

    def emit_owned(self, shapes: dict[str, dict[str, str]]) -> str:
        out = []
        for name in sorted(shapes):
            fields = []
            for key, swift in shapes[name].items():
                fields.append(Field(key, self.rust_for(swift), {"default": None} if swift.endswith("?") else {}))
            out.append(self.emit_struct(name, fields, None))
        return "\n\n".join(out)

    def rust_for(self, swift: str) -> str:
        if swift.endswith("?"):
            return f"Option<{self.rust_for(swift[:-1])}>"
        if swift.startswith("["):
            return f"Vec<{self.rust_for(swift[1:-1])}>"
        for rust, mapped in PRIMITIVES.items():
            if mapped == swift:
                return rust
        return swift


def parse_methods(path: Path) -> dict[str, str]:
    src = path.read_text()
    module = re.search(r"pub mod methods \{(.*?)\n\}", src, re.S)
    if not module:
        raise ReviewRequired("methods module not found")
    return dict(re.findall(r'pub const (\w+): &str = "(\w+)";', module.group(1)))


def emit_rpc(mapping: dict, methods: dict[str, str]) -> str:
    names = set(methods.values())
    lines = ["public enum Rpc {"]
    for name, spec in mapping["rpc"].items():
        if name not in names:
            raise ReviewRequired(f"rpc {name}: method no longer exists upstream")
        params = spec.get("params", "NoParams")
        ident = name[0].lower() + name[1:]
        if "stream" in spec:
            lines.append(f'    public static let {ident} = StreamRpc<{params}, {spec["stream"]}>("{name}")')
        else:
            lines.append(f'    public static let {ident} = UnaryRpc<{params}, {spec["reply"]}>("{name}")')
    lines.append("}")
    return "\n".join(lines)


HEADER = "// Generated by mobile/Codegen/generate.py. Do not edit.\n\nimport Foundation\n\n"


def main() -> int:
    check = "--check" in sys.argv
    mapping = json.loads((HERE / "mappings.json").read_text())
    decls: dict[str, Decl] = {}
    for source in mapping["sources"]:
        decls.update(parse_file(REPO / source))
    try:
        generator = Generator(mapping, decls)
        protocol = generator.run()
        owned = generator.emit_owned({**mapping["requests"], **mapping["replies"]})
        rpc = emit_rpc(mapping, parse_methods(REPO / mapping["methods"]))
    except ReviewRequired as err:
        print(f"review required: {err}", file=sys.stderr)
        return 2

    files = {
        "Protocol.swift": HEADER + protocol + "\n",
        "Requests.swift": HEADER + owned + "\n",
        "Rpc.swift": HEADER + rpc + "\n",
        "Support.swift": "// Copied by mobile/Codegen/generate.py from Codegen/templates. Do not edit.\n\n" + (HERE / "templates" / "Support.swift").read_text(),
    }
    stale = False
    for name, content in files.items():
        path = OUT / name
        if path.exists() and path.read_text() == content:
            continue
        stale = True
        if check:
            print(f"out of date: {path.relative_to(REPO)}", file=sys.stderr)
        else:
            path.write_text(content)
            print(f"wrote {path.relative_to(REPO)}")
    return 1 if (check and stale) else 0


if __name__ == "__main__":
    sys.exit(main())
