# Diagrams

Graphviz diagrams for the ARCP Swift SDK. Edit the `.dot` sources;
render with `dot -Tsvg`.

| Source | Renders | Description |
|--------|---------|-------------|
| `architecture-light.dot` / `architecture-dark.dot` | `architecture-{light,dark}.svg` | Layer diagram — `ARCPClient` ↔ `Transport` ↔ `ARCPRuntime` subsystems |
| `job-fsm.dot` | `job-fsm.svg` | `JobState` lifecycle and wire-event transitions |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="ARCP Swift SDK architecture" src="architecture-light.svg">
</picture>

## Render

```sh
cd docs/diagrams
for f in *.dot; do dot -Tsvg "$f" -o "${f%.dot}.svg"; done
```

`graphviz` provides `dot`. On macOS: `brew install graphviz`. On
Debian/Ubuntu: `apt-get install -y graphviz`.
