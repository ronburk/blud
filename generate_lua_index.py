#!/usr/bin/env python3

import hashlib
import json
from pathlib import Path

from tree_sitter import Language, Parser
import tree_sitter_lua


OUTPUT_PATH = Path("lua-index.json")


def node_text(source: bytes, node) -> str:
    return source[node.start_byte:node.end_byte].decode(
        "utf-8",
        errors="replace",
    )


def walk(root):
    cursor = root.walk()

    while True:
        node = cursor.node
        yield node

        if cursor.goto_first_child():
            continue

        if cursor.goto_next_sibling():
            continue

        while cursor.goto_parent():
            if cursor.goto_next_sibling():
                break
        else:
            return


def index_file(parser: Parser, path: Path) -> dict:
    source = path.read_bytes()
    tree = parser.parse(source)

    functions = []

    for node in walk(tree.root_node):
        if node.type != "function_declaration":
            continue

        name = node.child_by_field_name("name")
        parameters = node.child_by_field_name("parameters")

        functions.append(
            {
                "name": node_text(source, name) if name else None,
                "parameters": (
                    node_text(source, parameters)
                    if parameters
                    else "()"
                ),
                "start_line": node.start_point.row + 1,
                "end_line": node.end_point.row + 1,
            }
        )

    return {
        "path": path.as_posix(),
        "sha256": hashlib.sha256(source).hexdigest(),
        "bytes": len(source),
        "has_parse_error": tree.root_node.has_error,
        "functions": functions,
    }


def main() -> None:
    parser = Parser(Language(tree_sitter_lua.language()))

    paths = sorted(Path(".").glob("*.lua"))

    files = [
        index_file(parser, path)
        for path in paths
        if path.is_file()
    ]

    result = {
        "format": "blud-lua-index-v1",
        "files": files,
    }

    OUTPUT_PATH.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(f"wrote {OUTPUT_PATH}")
    print(f"files: {len(files)}")
    print(
        "parse errors:",
        sum(entry["has_parse_error"] for entry in files),
    )
    print(
        "functions:",
        sum(len(entry["functions"]) for entry in files),
    )


if __name__ == "__main__":
    main()
