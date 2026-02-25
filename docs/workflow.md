# Multi-machine Workflow

```mermaid
flowchart LR
A[Machine A] -->|Backup| B[Snapshot]
B -->|Move| C[Machine B]
C -->|Restore| D[Continue Work]
```