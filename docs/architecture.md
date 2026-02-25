# Architecture

```mermaid
flowchart TD
A[Detect Paths] --> B[Validate]
B --> C[Create Snapshot]
C --> D[meta.json]
D --> E[tar.gz]
E --> F[Transfer]
F --> G[Safe Restore]
```