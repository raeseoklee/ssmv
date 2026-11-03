# Explore diagrams

Open either diagram in the diagram viewer. Try zoom, Fit, full screen, and search for **Agent**. Document search uses Command+F on macOS and Ctrl+F on Windows; the same shortcut searches labels when the diagram viewer is focused.

## Flowchart

```mermaid
flowchart TB
    N["노마디안 (BtoC)<br/>사용자에게 에이전트·자동화 서비스 제공"]
    A["AOS (Agent OS)<br/>에이전트 실행 및 외부 서비스 인증 관리"]
    O["OG (Orchestration Grid)<br/>사전 구성된 워크플로우를 웹훅으로 실행"]
    N <--> A
    A <--> O
```

## C4 context

```mermaid
C4Context
    title Agent service context
    Person(user, "User", "Reads and runs automation")
    System(agent, "Agent service", "Coordinates agents and workflows")
    System_Ext(integration, "Integration Hub", "Manages external service connections")
    Rel(user, agent, "Uses")
    Rel(agent, integration, "Authenticates through")
```
