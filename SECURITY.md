# Política de seguridad

La seguridad de SeraphYieldProtocol depende tanto del código como de su configuración y operación.
Agradecemos los informes responsables que permitan evaluar cualquier comportamiento inesperado sin
poner en riesgo a usuarios ni despliegues.

## Versiones cubiertas

Mientras el proyecto permanezca en desarrollo, solo la revisión más reciente de la rama principal
recibe correcciones. Las ramas, etiquetas o forks anteriores no se consideran mantenidos salvo que
se indique expresamente.

## Cómo informar de forma privada

Utilice la opción **Report a vulnerability** de la pestaña **Security** del repositorio para crear
un aviso privado de GitHub. Si esa opción no está disponible, contacte de forma privada con los
mantenedores antes de compartir detalles técnicos.

Incluya, cuando sea posible:

- versión, commit y configuración afectados;
- descripción del comportamiento observado y del esperado;
- pasos mínimos y deterministas para reproducirlo;
- impacto estimado y supuestos necesarios;
- prueba de concepto o prueba automatizada;
- propuesta de corrección, si dispone de ella.

No incluya claves privadas, frases semilla, credenciales, datos personales ni fondos reales en el
informe o en la reproducción.

## Coordinación

Los mantenedores intentarán confirmar la recepción en un plazo de tres días laborables. Después se
evaluarán alcance y prioridad, se preparará una corrección y se acordará con el informante una fecha
de divulgación. Los tiempos pueden variar según la complejidad y el riesgo operativo.

Hasta que exista una solución publicada:

- no abra issues, pull requests o conversaciones públicas con detalles explotables;
- no pruebe el comportamiento sobre redes o contratos de terceros;
- limite la demostración a entornos locales o forks controlados;
- conserve de forma confidencial los artefactos de reproducción.

## Alcance orientativo

Son especialmente relevantes los problemas que puedan afectar a:

- custodia, retiros o disponibilidad de activos;
- emisión, quema o valoración de participaciones;
- distribución de recompensas y cobro de comisiones;
- permisos, pausas y cambios de configuración;
- integración, valoración o liquidación de estrategias;
- denegación de servicio persistente o incumplimiento de invariantes económicas.

Los errores puramente informativos, recomendaciones de estilo y problemas que solo existen en una
configuración explícitamente no soportada pueden tratarse mediante el flujo normal de contribución.

## Puerto seguro

La investigación de buena fe debe evitar perjuicios, proteger la privacidad y limitarse a activos
propios o expresamente autorizados. Esta política no concede permiso para interactuar con sistemas
de terceros, degradar servicios ni acceder a información ajena.
