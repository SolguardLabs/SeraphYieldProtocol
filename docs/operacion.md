# Operación y observabilidad

## Preparación local

El compilador está fijado en `foundry.toml` a Solidity 0.8.26, EVM Cancun, optimizador activo y perfil `ci` con más iteraciones de fuzz. Instale `forge-std` en la versión indicada y ejecute:

```bash
forge install foundry-rs/forge-std@v1.9.6 --no-git --shallow
forge fmt --check
forge build --sizes
forge test -vvv
```

`scripts/ci.sh` ejecuta formato, compilación y suite con el perfil `ci`. Los artefactos `out/`, `cache/` y dependencias `lib/` son locales y no se publican.

## Lecturas recomendadas

1. `snapshot()` para caja, deuda y presión de cola.
2. `strategies()` para comparar pesos objetivo, deuda real y caps.
3. `stress(lossBps, redemptionBps)` para una sensibilidad contable explícita.
4. Eventos de `harvest`, cola y claims para reconstruir la secuencia económica.

`idleCoverageBps` puede superar 10 000 si la caja excede los activos estimados en cola. Si no hay solicitudes, devuelve cero como no aplicable. `lastHarvest` es un timestamp, no una garantía de frescura del precio de cada estrategia. La vista no modifica el vault.

El script de despliegue se conserva para simulación local y revisión de parámetros; no se ejecuta en redes como parte de este release. Guarde commit, parámetros, plataforma y salida de Foundry al informar de un fallo.
