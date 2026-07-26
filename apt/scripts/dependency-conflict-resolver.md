# Dependency Conflict Resolver with Visual Tree

This tool analyzes a Debian APT repository pool directory, parses package metadata,
builds a dependency graph, detects dependency conflicts, and generates an interactive
HTML visualization of the dependency tree highlighting conflicts.

## Usage

```bash
python3 apt/scripts/dependency-conflict-resolver.py --pool-dir pool/main --output conflict-report.html
```

Open the generated `conflict-report.html` in a web browser to explore the dependency graph.

## Features

- Parses `Packages` or `Packages.gz` files in the specified pool directory.
- Builds a directed graph of package dependencies.
- Detects conflicting packages based on `Conflicts` fields.
- Visualizes the dependency tree with interactive zoom, pan, and node selection.
- Highlights conflicting packages in red.

## Requirements

- Python 3.8 or newer
- `networkx` Python package
- `jinja2` Python package

Install dependencies with:

```bash
pip3 install networkx jinja2
```

## Purpose

This tool addresses GitHub Issue #50: Dependency Conflict Resolver with Visual Tree.

It helps maintainers and users understand complex package dependency relationships
and identify conflicts before installation, reducing "dependency hell".

## License

Licensed under Apache-2.0 License.

## Author

AI Venture Holdings LLC
