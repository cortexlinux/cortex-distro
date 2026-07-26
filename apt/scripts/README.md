# Dependency Conflict Resolver Tool

This directory contains the Dependency Conflict Resolver tool for the CX Linux APT repository.

## Overview

The tool parses Debian package metadata from the repository pool, builds a dependency graph,
detects conflicts, and generates an interactive HTML visualization of the dependency tree.

## Usage

Run the resolver script:

```bash
python3 dependency-conflict-resolver.py --pool-dir pool/main --output conflict-report.html
```

Open the generated `conflict-report.html` in a web browser to explore the dependency graph.

## Requirements

- Python 3.8+
- `networkx`
- `jinja2`

Install dependencies:

```bash
pip3 install networkx jinja2
```

## Purpose

This tool solves GitHub Issue #50 by providing a visual dependency conflict resolver.

## License

Apache-2.0 License
