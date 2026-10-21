# Arquitectura y ciclo de vida

`SeraphVault` coordina todas las mutaciones del patrimonio. `SeraphShare` registra propiedad y bloqueo de participaciones. `StrategyRouter` mantiene deuda contable por estrategia, caps y pesos. `RewardDistributor` mantiene un índice global y checkpoints individuales. `WithdrawalQueue` gestiona solicitudes, ventanas y rondas. Los controladores de riesgo y comisiones aportan límites explícitos. `SeraphPortfolioLens` es una vista externa sin permisos de mutación.

```mermaid
sequenceDiagram
    participant U as Depositante
    participant V as Vault
    participant S as Share
    participant R as Router
    participant D as Distribuidor
    participant Q as Cola
    U->>V: deposit(assets)
    V->>S: mint(shares)
    V->>R: deployIdle(cap)
    R-->>V: deuda y reportes
    V->>D: notifyReward(fondos)
    U->>V: requestWithdrawal(shares)
    V->>S: lock(shares)
    V->>Q: enqueue(solicitud)
    Q-->>V: ventana ejecutable
    V->>S: burnLocked(shares)
    V-->>U: activos netos
```

Una orden de retiro transita por `Pending`, `Claimable`, `Claimed` o `Cancelled`; las ventanas se basan en tiempos de solicitud y vencimiento. Los eventos no sustituyen el estado de almacenamiento. Las interacciones entre módulos se validan con tests de integración sobre el mismo vault.
