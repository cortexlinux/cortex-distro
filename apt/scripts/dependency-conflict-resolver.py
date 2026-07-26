#!/usr/bin/env python3
"""
Dependency Conflict Resolver with Visual Tree

This tool analyzes a Debian package repository pool directory,
parses package metadata, builds a dependency graph, detects conflicts,
and outputs an interactive HTML visualization of the dependency tree
highlighting conflicts.

Usage:
    python3 dependency-conflict-resolver.py --pool-dir pool/main --output report.html

Requirements:
    - Python 3.8+
    - networkx
    - jinja2
"""

import os
import sys
import argparse
import gzip
import re
from collections import defaultdict, deque
import networkx as nx
from jinja2 import Template

PKG_FIELDS = [
    "Package",
    "Version",
    "Depends",
    "Pre-Depends",
    "Conflicts",
    "Breaks",
    "Replaces",
    "Provides",
]

def parse_deb_control_file(path):
    """
    Parse a Debian control file (Packages or Packages.gz) and yield package dicts.
    """
    if path.endswith(".gz"):
        f = gzip.open(path, "rt", encoding="utf-8", errors="replace")
    else:
        f = open(path, "rt", encoding="utf-8", errors="replace")

    pkg = {}
    for line in f:
        line = line.rstrip("\n")
        if line == "":
            if pkg:
                yield pkg
                pkg = {}
            continue
        if line[0].isspace() and pkg:
            # continuation line
            last_key = list(pkg.keys())[-1]
            pkg[last_key] += " " + line.strip()
        else:
            if ":" not in line:
                continue
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip()
            if key in PKG_FIELDS:
                pkg[key] = val
    if pkg:
        yield pkg
    f.close()

def parse_depends_field(dep_str):
    """
    Parse Depends or similar field into list of alternatives.
    Each alternative is a list of package names (ORed).
    Example: "foo (>= 1.0), bar | baz" -> [["foo"], ["bar", "baz"]]
    """
    if not dep_str:
        return []
    parts = []
    # Split by commas not inside parentheses
    depth = 0
    current = ""
    for c in dep_str:
        if c == ',' and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += c
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
    if current:
        parts.append(current.strip())

    result = []
    for part in parts:
        # alternatives separated by '|'
        alts = [alt.strip() for alt in part.split('|')]
        # strip version info in parentheses
        alts_clean = [re.sub(r'\s*\(.*?\)', '', alt) for alt in alts]
        result.append(alts_clean)
    return result

def build_package_graph(packages):
    """
    Build a directed graph of packages and their dependencies.
    Nodes: package names (with version)
    Edges: dependency relations
    """
    G = nx.DiGraph()
    pkg_versions = {}  # package name -> version
    provides_map = defaultdict(set)  # virtual package -> set of real packages

    # First pass: record versions and provides
    for pkg in packages:
        name = pkg.get("Package")
        version = pkg.get("Version")
        if not name or not version:
            continue
        pkg_versions[name] = version
        provides = pkg.get("Provides", "")
        for prov in [p.strip() for p in provides.split(",") if p.strip()]:
            provides_map[prov].add(name)

    # Add nodes
    for name, version in pkg_versions.items():
        G.add_node(name, version=version)

    # Add edges for Depends and Pre-Depends
    for pkg in packages:
        name = pkg.get("Package")
        if not name or name not in pkg_versions:
            continue
        for dep_field in ["Depends", "Pre-Depends"]:
            dep_str = pkg.get(dep_field, "")
            dep_groups = parse_depends_field(dep_str)
            for group in dep_groups:
                # For each group of alternatives, add edges to all alternatives
                for dep in group:
                    # If dep is virtual, add edges to all providers
                    if dep in provides_map:
                        for real_pkg in provides_map[dep]:
                            if real_pkg in pkg_versions:
                                G.add_edge(name, real_pkg)
                    else:
                        if dep in pkg_versions:
                            G.add_edge(name, dep)
    return G

def detect_conflicts(packages):
    """
    Detect conflicts between packages.
    Returns a dict: package -> set of conflicting packages
    """
    conflicts = defaultdict(set)
    pkg_versions = {}
    for pkg in packages:
        name = pkg.get("Package")
        version = pkg.get("Version")
        if not name or not version:
            continue
        pkg_versions[name] = version

    for pkg in packages:
        name = pkg.get("Package")
        if not name:
            continue
        conflict_str = pkg.get("Conflicts", "")
        conflict_groups = parse_depends_field(conflict_str)
        for group in conflict_groups:
            for conflict_pkg in group:
                if conflict_pkg in pkg_versions:
                    conflicts[name].add(conflict_pkg)
                    conflicts[conflict_pkg].add(name)
    return conflicts

def generate_html_report(graph, conflicts, output_path):
    """
    Generate an interactive HTML report visualizing the dependency graph and conflicts.
    """
    # Prepare data for visualization
    nodes = []
    edges = []
    for node in graph.nodes:
        nodes.append({
            "id": node,
            "label": f"{node}\n{graph.nodes[node].get('version','')}",
            "color": "red" if node in conflicts else "lightblue",
        })
    for src, dst in graph.edges:
        edges.append({"from": src, "to": dst})

    # Use vis.js for visualization
    template_str = """
<!DOCTYPE html>
<html>
<head>
  <title>Dependency Conflict Resolver</title>
  <script type="text/javascript" src="https://unpkg.com/vis-network@9.1.2/dist/vis-network.min.js"></script>
  <style>
    #mynetwork {
      width: 100%;
      height: 90vh;
      border: 1px solid lightgray;
    }
    body {
      font-family: Arial, sans-serif;
      margin: 0; padding: 0;
    }
    h1 {
      margin: 10px;
      font-size: 1.5em;
    }
    #legend {
      margin: 10px;
    }
    .legend-item {
      display: inline-block;
      margin-right: 20px;
      font-size: 0.9em;
    }
    .color-box {
      display: inline-block;
      width: 15px;
      height: 15px;
      vertical-align: middle;
      margin-right: 5px;
      border: 1px solid #ccc;
    }
  </style>
</head>
<body>
  <h1>Dependency Conflict Resolver with Visual Tree</h1>
  <div id="legend">
    <div class="legend-item"><span class="color-box" style="background-color: lightblue;"></span> Package</div>
    <div class="legend-item"><span class="color-box" style="background-color: red;"></span> Conflicting Package</div>
  </div>
  <div id="mynetwork"></div>
  <script type="text/javascript">
    const nodes = new vis.DataSet({{ nodes | safe }});
    const edges = new vis.DataSet({{ edges | safe }});

    const container = document.getElementById('mynetwork');
    const data = {
      nodes: nodes,
      edges: edges
    };
    const options = {
      layout: {
        hierarchical: {
          direction: 'UD',
          sortMethod: 'directed',
          nodeSpacing: 150,
          levelSeparation: 150,
        }
      },
      interaction: {
        hover: true,
        navigationButtons: true,
        keyboard: true,
      },
      physics: {
        enabled: false
      },
      nodes: {
        shape: 'box',
        font: {
          multi: 'html',
          size: 14,
          face: 'monospace',
        },
        margin: 10,
      },
      edges: {
        arrows: {
          to: {enabled: true, scaleFactor: 0.5}
        },
        smooth: {
          type: 'cubicBezier',
          forceDirection: 'vertical',
          roundness: 0.4
        }
      }
    };
    const network = new vis.Network(container, data, options);

    network.on("selectNode", function(params) {
      const nodeId = params.nodes[0];
      alert("Selected package: " + nodeId);
    });
  </script>
</body>
</html>
"""
    template = Template(template_str)
    html = template.render(nodes=nodes, edges=edges)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html)

def main():
    parser = argparse.ArgumentParser(description="Dependency Conflict Resolver with Visual Tree")
    parser.add_argument("--pool-dir", required=True, help="Path to APT pool directory containing .deb packages and Packages files")
    parser.add_argument("--output", required=True, help="Output HTML report file path")
    args = parser.parse_args()

    # Find Packages or Packages.gz file in pool-dir
    packages_file = None
    for fname in ["Packages", "Packages.gz"]:
        candidate = os.path.join(args.pool_dir, fname)
        if os.path.isfile(candidate):
            packages_file = candidate
            break
    if not packages_file:
        print(f"Error: No Packages or Packages.gz file found in {args.pool_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing package metadata from {packages_file}...")
    packages = list(parse_deb_control_file(packages_file))
    print(f"Parsed {len(packages)} packages.")

    print("Building dependency graph...")
    graph = build_package_graph(packages)
    print(f"Graph has {graph.number_of_nodes()} nodes and {graph.number_of_edges()} edges.")

    print("Detecting conflicts...")
    conflicts = detect_conflicts(packages)
    print(f"Found {len(conflicts)} packages with conflicts.")

    print(f"Generating HTML report to {args.output}...")
    generate_html_report(graph, conflicts, args.output)
    print("Done.")

if __name__ == "__main__":
    main()
