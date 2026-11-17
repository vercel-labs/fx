# Captura de workspace por turno en fx: plan consolidado

Fecha: 2026-11-09. Base inspeccionada: `c3289122839043b3a42545f2ce9d02edfcc735ce`.

**Este es el plan vigente.** Las decisiones de producto están acordadas. Hay un prototipo ejecutable y pruebas de los mecanismos de Git, pero no hay implementación conectada a fx. Los detalles de integración y sus pruebas se cierran en las fases indicadas abajo, sin presentar el prototipo como garantía del producto.

## 1. Objetivo

Cumplir el pedido del thread: guardar HEAD, cambios sin commitear, archivos nuevos y metadatos de herramientas al empezar cada turno; guardar el estado resultante al terminar; y permitir relacionar commits posteriores con la sesión.

La captura es local. No envía datos ni autoriza entrenamiento. Sirve como evidencia para convertir sesiones en tareas reproducibles más adelante; no demuestra que una solución sea correcta ni quién produjo cada cambio.

### Alcance

- Sesiones guardadas de hosts nativos con filesystem y Git disponibles.
- Repositorios Git locales, incluidos los alcanzados durante un turno iniciado fuera de Git.
- Turnos del agente principal y de subagentes.
- Persistencia integrada con Sessions v2, sin convertir sesiones antiguas.
- Capturas futuras en sesiones retomadas; no se inventa el estado de turnos históricos.

Fuera de esta implementación: exportador, importer, Harbor, piloto de evals, entrenamiento, hooks de usuario configurables y captura de archivos que no pertenecen a ningún repositorio Git. Tampoco se congelan servicios, bases de datos, procesos ni dependencias externas.

## 2. Decisiones acordadas

| ID | Decisión |
| --- | --- |
| D1 | Se acepta depender del repositorio original: si desaparecen sus objetos, se informa `base no disponible`. No se hace un respaldo autocontenido |
| D2 | Se conserva el estado de archivos tracked y untracked admitidos; las exclusiones quedan registradas |
| D3 | Trabajo fuera de cualquier repositorio: `unavailable` con `not_git`, sin recorrer el home |
| D4 | Almacén Git privado de fx por repositorio, separado del `.git` del usuario, con alternates hacia sus objetos |
| D5 | Captura activada por defecto; exportación siempre opt-in; control para desactivarla |
| D6 | Excluir untracked ignorados y nombres sensibles. No redactar archivos locales; escanear y revisar la copia al exportar |
| D7 | Límites como constantes internas inicialmente, no nueve opciones públicas |
| D8 | Un fallo de captura no debe impedir trabajar; se distingue del fallo del almacenamiento de la conversación |
| D9 | Conservar versiones declaradas en los archivos capturados y resolver rutas de herramientas sin ejecutarlas. No llamar “versión efectiva” a una ruta |
| D10 | Relacionar commits por igualdad exacta de tree. Observar al iniciar el siguiente turno y completar la comparación al exportar |
| D11 | Misma regla de captura para cada sesión, incluidos hijos; registrar evidencia de concurrencia cuando sea observable |
| D12 | Captura sincrónica, con presupuesto de tiempo. Optimizar después de medir la integración |
| D13 | Conservar mientras exista la sesión, salvo presupuesto total de 5 GiB. Descartar sesiones inactivas enteras, empezando por las más antiguas, y registrar el descarte |
| D14 | Capturar por repositorio alcanzado, no solo por carpeta de inicio; registrar qué acción disparó cada captura |

Los valores de tiempo y espacio son presupuestos iniciales para validar durante la integración, no mediciones universales ni cuotas físicas exactas.

## 3. Contrato de captura

### 3.1 Límites temporales y alcance

La unidad es un repositorio de un worktree alcanzado por un turno guardado.

1. Si la carpeta inicial está dentro de un repositorio, capturar antes de la primera petición al modelo, junto al punto existente de `save_prompt_images`.
2. Antes de ejecutar una edición o comando en otro repositorio, capturarlo si todavía no tiene inicio en ese turno. Para ese repositorio, “inicio” significa antes de su primera acción detectada, no el instante en que empezó el turno.
3. Antes del cierre durable, capturar el final de cada repositorio alcanzado.
4. Steering dentro del mismo turno no crea otro inicio. Un reintento o reanudación no reemplaza el inicio original con el estado actual.
5. Un crash puede dejar inicio sin final; nunca se inventa un cierre al reabrir.

D14 toma rutas estructuradas: `target_path` de la mutación preparada y `resolved_cwd` del contexto de ejecución del comando. El texto de permisos `directorio::identidad` no sirve como ruta. La captura se conecta después de la admisión y antes de ejecutar la acción, sin modificar su autoridad.

Límite explícito: no se detecta un comando que modifica otro repositorio solo mediante sus argumentos, sin usarlo como directorio de trabajo; tampoco todos los efectos de herramientas externas. Se conserva el disparador y el alcance, sin declarar cobertura completa de toda la máquina.

Una captura no es un instante atómico. Escrituras externas y agentes concurrentes pueden interferir. El descarte de incertidumbre debe probarse; no basta un booleano sin un mecanismo que lo sostenga. Reutilizar el tree inicial al final solo puede significar “sin mutaciones observadas por fx”, no igualdad comprobada si hubo trabajo externo. Esta optimización queda condicionada al test de concurrencia de la fase 5.

### 3.2 Archivos y seguridad

- Tracked: conservar el estado del disco, incluidos binarios, modos y symlinks dentro del alcance probado; no modificar el index del usuario.
- Untracked: respetar exclusiones de Git y excluir nombres sensibles: `.env`, `.env.*`, `.envrc`, `*.pem`, `*.key`, `*.p12`, `id_rsa*`, `id_ed25519*`, `.netrc` y `.npmrc`.
- Una exclusión no se presenta como estado completo. No truncar un parche o una lista y llamarlo restaurable.
- Tracked no equivale a “ya commiteado”: puede ser un archivo recién agregado al index o un secreto nuevo en un archivo existente. La captura local puede conservarlo y debe protegerse como dato sensible.
- Submódulos: conservar el gitlink; no afirmar que se capturó su contenido dirty.
- Sin guardado de sesión o sin capacidades del host: no crear almacenes persistentes de captura.

`safe_git` conserva la frontera de ejecución. El repositorio no puede introducir hooks, filtros ni ejecutables en la captura. La configuración global y de sistema sigue la confianza actual de `safe_git`; sus efectos deben probarse, en particular Git LFS. No instalar herramientas ni ejecutar shims para descubrir versiones.

### 3.3 Completitud y fallos

Estados del registro: `complete`, `partial`, `failed`, `unavailable`, siempre dentro de un alcance declarado. Cuando falta contenido, límites o permisos de lectura, conservar un motivo observable. Si tampoco puede guardarse el registro de error, no prometer que el fallo quedó durable: usar el canal diagnóstico existente.

La restauración es una operación explícita de verificación en directorios separados. La captura nunca restaura sobre el workspace del usuario como efecto lateral.

## 4. Diseño y dueños

### 4.1 Almacén de objetos

Un repositorio bare bajo el perfil de fx por directorio Git común real. Se crea sin templates ni hooks y con permisos privados. Alternates permite leer objetos existentes del usuario; fx escribe sus propios objetos solo en su almacén. La integridad se comprueba al restaurar: los objetos prestados pueden desaparecer incluso si el checkout sigue existiendo.

Una referencia por sesión y worktree, `refs/fx/sessions/<sesión>/<worktree>`, conserva una cadena de commits de captura; borrar una sesión es borrar `refs/fx/sessions/<sesión>/*`. Cada hijo tiene su propio ID y referencia; se conserva la relación padre-hijo en la sesión, sin mezclar la historia de capturas. Los commits de captura usan identidad fija y las escrituras desactivan reflogs (`core.logAllRefUpdates=false`).

### 4.2 Index e intermedios por worktree

Los objetos se comparten por repositorio, pero cada worktree tiene index de captura, lock y temporales propios.

- Copiar el index preservando su fecha: una copia con fecha nueva puede ocultar un cambio del mismo tamaño hecho en el mismo segundo que el index original.
- Limpiar `assume-unchanged` y `skip-worktree` solo en la copia.
- En cada captura, tomar del index actual del usuario el modo y OID de entradas skip-worktree ausentes del disco. Si están en disco, leer su contenido.
- Reconstruir el index en split index; sparse index aún no soportado produce `unavailable:index_sparse`.
- Eliminar del index de captura rutas que ya no pertenecen al conjunto admitido.
- Mantener el lock durante todo el proceso, no solo durante cada comando Git. Todos los intermedios quedan aislados bajo ese lock. El test 28 reproduce la intercalación problemática entre worktrees.

El prototipo usa `flock` para liberar la exclusión al morir un proceso. En fx, demostrar el ciclo de vida de hijos antes de borrar un `index.lock`: que el padre haya muerto no basta si un proceso Git sobrevivió. Ante duda, registrar bloqueo, no borrar locks arbitrariamente.

### 4.3 Lista y ejecución Git

Reutilizar `src/core/indexer/` para listar sin procesos. Extender su lectura del index con modo, OID y skip-worktree cuando haga falta. Su listado y sus caches tienen límites y validez que la captura debe comprobar.

Respaldo con Git endurecido cuando el indexador no puede leer un formato admitido. Cada formato no soportado produce estado explícito. El prototipo usa Git para obtener entradas tracked; eso no prueba por sí solo la futura ruta nativa.

`src/core/shell_command/safe_git.zig` posee ejecución y entorno seguros; el dueño de captura en `src/core/workspace/` posee política, estado por turno y almacén. El adaptador de sesiones posee el registro durable. No agregar estado del producto a `main.zig` ni a la UI.

Operaciones a admitir con argumentos controlados: lista de archivos; `init --bare --template=`; `read-tree`; `update-index` para altas, bajas, limpieza de flags e index-info; `write-tree`; `commit-tree`; `update-ref` con valor anterior y borrado; y mantenimiento acotado. Cada una necesita límites de tiempo, entrada y salida y pruebas con repositorios trampa. No exponer un pasaje genérico de argumentos arbitrarios.

### 4.4 Sessions v2 y lifecycle

Ítem nuevo `workspace_capture`, lateral como `recovery`, fuera de `streamed`. Evitar que `streamedPrefix` lo considere una diferencia y superseda el turno.

- Inicio: incorporarlo a la primera escritura durable si el turno aún no existe, o escribirlo en el turno abierto. Un ítem pendiente solo en memoria no sobrevive a un crash; esa ventana debe quedar explícita y probada.
- Final: incorporarlo antes de `turn_committed` o `turn_interrupted`, en el lote de cierre.
- Cubrir completado, cancelación, interrupción y fallo mediante un punto común. En la base inspeccionada hay seis llamadas productivas de cierre; una séptima coincidencia era wiring de tests.
- No usar `PostTurnEnd` para esta persistencia: llega después del cierre e ignora errores.
- Condicionar por capacidades reales del host, no por el nombre de un modo. Probar native, ACP/N-API y wasm según su almacenamiento efectivo.

Campos propuestos: versión del ítem, fase, disparador, alcance/repositorio/worktree, HEAD o `unborn`, tree y commit de captura opcionales, formato de objetos, fuente del index/listado, estado y motivo, exclusiones acotadas, duración y metadatos de herramientas. Añadir solo contadores y marcas de comparabilidad/concurrencia que se puedan demostrar. Los bytes nuevos físicos y una detección completa de concurrencia no se dan por implementados.

El ítem no se agrega a los mensajes del modelo por existir en el log. La forma admite tipos desconocidos de Sessions v2, pero la compatibilidad debe probar lectura, reanudación, fork, supersesión y compactación, no solo parseo. No convertir turnos históricos.

### 4.5 Metadatos y commits posteriores

Las declaraciones de toolchains permanecen en el tree si fueron admitidas. Registrar plataforma, versión de fx y rutas resueltas de las herramientas presentes, con procedencia y momento, sin confundir rutas o declaraciones con versiones ejecutadas comprobadas. Resolver el PATH del entorno real de comandos es parte de la integración, no un hecho ya probado.

Comparar trees de capturas finales con commits del usuario, con el mismo formato de objetos y políticas de contenido compatibles. Filtros, normalización, LFS, exclusiones o capturas parciales pueden impedir la coincidencia; reportarlo.

Al iniciar el siguiente turno, revisar un rango acotado del historial si cambió HEAD. La futura exportación compara el historial que todavía exista. La primera observación puede preservar un vínculo antes de un squash o una poda; la exportación encuentra commits hechos después del último turno. Compartir el comparador, no duplicar su lógica. La ausencia de coincidencia no demuestra ausencia de contribución.

Los vínculos se guardan en registros, nunca como historia futura dentro del starter de un eval. Rebases, rangos no ancestrales y límites de exploración deben informarse, no interpretarse como búsqueda exhaustiva.

### 4.6 Presupuestos y mantenimiento

| Presupuesto inicial | Valor |
| --- | --- |
| Tiempo por captura | 2 s |
| Tamaño por untracked | 2 MiB |
| Untracked por captura | 1.000 |
| Bytes nuevos por captura | 64 MiB |
| Ocupación total del perfil de captura | 5 GiB |

Son presupuestos de admisión. El coste de índices, temporales, objetos compartidos y la gracia de GC impide prometer ocupación física instantánea exacta. Al superar un límite: resultado parcial solo si existe contenido coherente utilizable; en otro caso `unavailable`. Una cancelación no deja una referencia que aparente contenido completo.

Descartar por sesión entera: la cadena no permite liberar capturas individuales manteniendo sus descendientes. Elegir sesiones inactivas de más antigua a más reciente, con desempate determinista por ID. Proteger todas las activas, no solo la actual. El descarte de una sesión abarca sus referencias en todos los repositorios; no elimina la conversación.

El prototipo `budget.py` recibe un inventario explícito, mide bytes asignados, registra y sincroniza un journal antes del borrado, elimina referencias, limpia y vuelve a medir hasta alcanzar el presupuesto o agotar candidatas. Un fallo detiene mantenimiento; la admisión sigue bloqueada si no alcanza. El journal del perfil evita escribir logs de sesiones inactivas.

La limpieza usa gracia de una hora, no `--prune=now` en producción. La gracia es una defensa adicional, no reemplaza exclusión contra capturas activas ni un inventario consistente. Si objetos recientes, compartidos o retenidos por índices impiden bajar el uso, no borrar indiscriminadamente: dejar de admitir nuevas capturas.

Antes de integrarlo: definir inventario, exclusión de mantenimiento, recuperación de descartes interrumpidos y consulta del journal desde lectores/forks. El prototipo prueba selección y eliminación, no esas conexiones con fx.

### 4.7 Control y documentación

Un control de activación, siguiendo `.fx/skills/fx-cli-shape/SKILL.md`. Mantener los límites internos inicialmente. Definir una acción explícita de limpieza, sin multiplicar controles por anticipado.

Actualizar las páginas Data and privacy y Configuration del manual en la implementación. Exportar exige una copia separada, redacción, revisión y consentimiento, como el flujo de compartir trazas; ese exportador no se construye aquí.

## 5. Ejecución por fases: tests en cada paso

**Estado: fases 1, 2, 3a y 4 implementadas localmente, sin conectar al runtime.** Nada llama todavía a `capture_store.capture` ni a `saveWorkspaceCapture`, así que fx no captura ni escribe ítems nuevos. Pendiente para cerrar las fases 2 y 4: CI. Los modelos TLA+ ya se actualizaron y corrieron localmente. La fase 4 de la tabla es la persistencia en Sessions v2; se implementó antes que la 3 porque solo depende del registro de la fase 1.

| Fase | Entregable | Evidencia necesaria antes de avanzar |
| --- | --- | --- |
| 1 | Política pura: selección, exclusiones, sparse, resultados e ítem | Unitarios inline que fallen antes de implementar. Sin ejecución Git ni persistencia |
| 2 | Extensión acotada de `safe_git` | Tests `SentinelRepo` con controles positivos, argumentos tipados, límites/cancelación y modelo GitAdmission actualizado |
| 3 | Almacén e inventario/mantenimiento | Portar casos del prototipo; worktrees intercalados; índices, flags, fechas; límites, descarte, lock y recuperación; pruebas de allocations y fallos de I/O |
| 4 | Persistencia de ítems en Sessions v2 | Inicio pendiente/escrito, final antes del cierre, ningún superseded, crash, reanudación/fork, desconocidos. Diseño y specs afectados actualizados |
| 5 | Runtime y D14, usando lo anterior | Gateway falso: orden antes de mutar, seis caminos de cierre, steering/retry, subagente que termina después del padre, múltiples repositorios y host sin capacidad |
| 6 | Entorno y asociación de commits | Procedencia del PATH, no ejecución de shims; comparador común, rangos incompletos, squash/poda, sin filtrar solución al contexto |
| 7 | Flujo integrado y control público | Binario de este checkout y gateway falso, restauración en carpeta vacía; capture on/off; CI wiring, docs, errores y presupuestos medidos |

Elegir siempre la capa más baja que pruebe el contrato, extender los tests dueños y usar perfiles temporales. Cada bug corregido conserva un test que lo detecta. Las fallas plantadas califican el test; no sustituyen una comprobación independiente de bytes y propiedades.

La fase de persistencia precede a conectar el runtime. Un checkpoint de lógica pura puede ser revisable sin afirmar que la captura ya funciona. Antes de declarar el producto verificable: build, checks enfocados, flujo real con `./zig-out/bin/fx` y CI del commit exacto. Commit, push y PR requieren pedidos separados.

### Avance local de la fase 1

- Selección determinista y rutas prestadas: leer del worktree, conservar entradas sparse actuales, quitar rutas anteriores que salen y registrar exclusiones.
- Tracked ignorados o recién staged no reciben límites de untracked. Gitlinks presentes se refrescan desde el worktree para obtener su HEAD; no se leen recursivamente como archivos. Ausentes sparse se conservan y borrados reales se quitan.
- Validación de rutas relativas, unicidad de candidatos (el caller colapsa stages unmerged), límites de untracked y OIDs canónicos SHA-1/SHA-256.
- Registro JSON mínimo con estados y motivos compatibles; no es todavía el ítem completo persistido de Sessions v2.
- 15 tests inline de la fase, más el test de descubrimiento del harness. Incluyen barridos de fallos de asignación con `testing_allocator.no_resize`.
- Antes de implementar, los siete tests iniciales de selección fallaron; la regresión del gitlink también se observó antes de corregirla. Cuatro mutaciones temporales (borrar una ruta admitida, perder sparse, admitir secretos y omitir la validación estado/motivo) provocan fallos de comportamiento con exit 1.

Verificación local de esta fase:

| Check | Resultado |
| --- | --- |
| Harness temporal con `zig test`, filtro `capture `, Debug y ReleaseSafe | 16 pasan en cada modo: 15 tests nuevos y el harness; exit 0 |
| `zig fmt --check src/core/workspace/workspace_capture.zig src/main.zig` | Pasa, exit 0 |
| `zig build --summary all` | 7/7 pasos, exit 0 |
| `FX_SOUND=0 zig build test -Doptimize=ReleaseSafe --summary all` sobre el código final | 21/21 pasos; 10.812 tests pasan, 7 omitidos de 10.819; exit 0 |
| `FX_SOUND=0 ./zig-out/bin/fx --version` | `0.0.16`, exit 0; smoke de arranque, no captura integrada |

La suite Debug también pasó antes de los últimos ajustes de revisión; la evidencia del código final es la pasada ReleaseSafe de arriba. La revisión independiente confirmó el cierre de sus hallazgos altos y medios. CI, pruebas del runtime de captura y publicación siguen pendientes. Esta fase no crea snapshots ni cambia sesiones.

Los tests se descubren desde `main.zig` para `zig build test`. La verificación enfocada usa un harness temporal que importa el módulo y el allocator de pruebas existente. No prueba la futura captura de archivos dentro de fx. Las fases 2 y 4 se construyeron en paralelo: la 2 en esta rama y la 4 por un subagente en un worktree separado, integrada después de verificar sus tests en ambos árboles.

### Avance local de la fase 2: ruta de captura en `safe_git`

- Ruta tipada, sin pasaje genérico de argumentos: `initStore`, `runStore` con `StoreCommand` (`read_tree`, `add_remove`, `clear_flags`, `index_info`, `write_tree`, `commit_tree`, `update_ref` y `delete_ref` con compare-and-swap, `gc` con gracia de una hora) y `listRepository` como respaldo del indexador.
- El almacén no lee la config del repositorio del usuario. `GIT_DIR`, `GIT_INDEX_FILE` y `GIT_WORK_TREE` son explícitos. Overrides de hooks, fsmonitor, reflogs, firma, split index, sparse index, untracked cache y gc automático. Identidad fija `fx capture <capture@fx.invalid>`.
- `StoreReady` es un tipo distinto de `Ready`: un handle del almacén no puede llegar a las rutas que deben anular los filtros del repositorio.
- Límites: deadline por comando o compartido por captura (si ya venció no se lanza nada), tope de stdout y stderr, input por archivo único creado en exclusivo y desenlazado al abrirlo. Ante una salida temprana se envía SIGTERM y SIGCONT al grupo de procesos, así mueren también los filtros que lanzó git y git borra su lock.
- Validación de OID, refs `refs/fx/sessions/<sesión>/<worktree>` (dos segmentos `[A-Za-z0-9_-]{1,128}`, desde la fase 3a) y rutas con la regla compartida `src/core/shared/repo_path.zig`. Una ruta que git descarta con "Ignoring path" pero exit 0 produce `path_rejected`.
- `--object-format` obligatorio y `Conversions` tipadas (`fileMode`, `symlinks`, `autocrlf`, `eol`) para registrar el mismo tree que el git del usuario.
- 25 tests en `safe_git.zig` (14 nuevos) y 1 en `repo_path.zig`. Repositorio trampa: 0 ejecuciones en la captura y >0 en el control. Config global hostil, timeout con un filtro lento, CAS de refs, flags heredados, SHA-256, `fileMode=false` con control, LFS falso global y filtro requerido ausente, rutas rechazadas, listado desde un subdirectorio y deadline vencido.
- 20 mutaciones planteadas, todas detectadas: quitar cada override, `GIT_DIR`, `GIT_WORK_TREE`, la identidad, la limpieza de flags, el timeout, el kill de grupo, el tope de salida, la detección de rutas rechazadas, el formato de objetos, las conversiones, `--full-name`, la validación de refs y rutas, el CAS y el prelude del listado. El test del deadline vencido no detectaba su mutación y se rehízo hasta detectarla.

Límites conocidos de la fase 2:

- Decidido: la ruta de captura usa como `PATH` los directorios del sistema más los que `trustedExecutable` ya acepta para git (`/usr/local/bin`, `/opt/homebrew/bin`, `/opt/local/bin`, `/run/current-system/sw/bin`). Así resuelve un filtro global llamado por nombre, como el `git-lfs` de Homebrew; las rutas de git del agente conservan `/usr/bin:/bin`. Un test con el `git-lfs` real guarda el puntero LFS, y falla si se quita el `PATH` ampliado. Un filtro requerido que no se encuentra en ninguno de esos directorios sigue fallando de forma visible.
- Un `git-lfs` real escribiría objetos en `store.git/lfs/objects`, fuera del presupuesto por captura: lo debe medir la fase 3.
- `Conversions` no incluye `core.ignoreCase`, `core.precomposeUnicode` ni el `info/attributes` del usuario. La fase 3 decide de dónde leer los valores.
- `tests/tla/shell_command/GitAdmission.tla` modela la captura como segundo llamador: depende solo del git de confianza, nunca ejecuta un programa del repositorio, nunca escribe el index del usuario y queda `capture_unavailable` en vez de caer a git normal. Dos fallas plantadas (la ruta del almacén lee el repositorio) rompen `CaptureNeverFires` y `CaptureLeavesUserIndex`. `tests/tla/shell_command/check.sh` pasa sus 16 configs con el veredicto esperado (TLC v1.7.4, la misma versión que fija el CI).

### Avance local de la fase 4: ítem `workspace_capture` en Sessions v2

- `session_adapter.zig`: `beginCaptureTurn` entrega un token único por proceso; `saveWorkspaceCapture(token, payload, .start | .end)` guarda un objeto JSON opaco de hasta 256 KiB, siempre inline (D44).
- Inicios: se escriben en el turno abierto o se retienen hasta su primera escritura. Finales: en el lote de cierre, antes de `turn_committed` o `turn_interrupted`. Fuera de `streamed`: nunca provoca `superseded`, no entra a los mensajes del modelo y los builds viejos lo saltan (D17).
- Si `commitTurn` falla, o un turno nunca llega a `commitTurn`, sus capturas se descartan con traza y el turno abierto se cierra como superseded en la siguiente escritura; una captura con un token viejo devuelve `WorkspaceCaptureTurnClosed`. Ninguna captura pasa al turno siguiente.
- Corrección previa encontrada en el camino: `commitTurn` ahora reserva `turn_numbers` antes de escribir, así una falta de memoria no deja el turno cerrado en disco y abierto en memoria.
- D98 en `tests/tla/session_manager/system-design.md`: contrato, durabilidad (sobrevive a la muerte del proceso, no a un corte de energía antes del fsync de D10) y regla de lectura (la captura más nueva por repositorio y fase dentro de turnos no supersedidos).
- 17 tests nuevos (rojo antes, verde después), barridos de OOM con `testing_allocator.no_resize`, y 5 mutaciones detectadas.

Revisión de la rama (máquina `review`, PR #1811): el token quedó atado al turno que se commitea. `commitTurn` ya no escribe capturas ni termina el token; `commitTurnWithCaptures(turn, language, token)` es la única que las escribe, y solo si el token sigue vigente. El turno abierto en disco pertenece al token vigente cuando se abrió (`turn_token`); `prepareTurn`, la importación y un commit sin token abren sin capturas, y `beginCaptureTurn` adopta un turno vivo que ningún token abrió. Un commit fallido conserva las capturas para el reintento del mismo turno; el siguiente `beginCaptureTurn` las descarta. `saveRecovery`, la compactación y `close` tratan el turno viejo como cerrado, y la traza cuenta capturas retenidas y escritas. 46 tests de captura; 8 de 8 mutaciones detectadas.

Límites conocidos de la fase 4: una escritura que llega a disco y devuelve error no se puede inyectar desde el adaptador (después de ella el manager rechaza todo append, D40). El supersede de un turno abierto tras un commit fallido está modelado en `TurnStream.tla` (`FailCommit`, `StaleTurnNeverContinues`, mutante `continue_stale`). Con el código final pasan `tests/tla/session/check.sh` (41 configs), `tests/tla/subagent/check.sh` (22), los drivers `drivers/session/write.test.ts` (8 tests) y `drivers/subagent/` (11) sobre el binario de este checkout, y 11 de los 12 specs de `tests/tla/session_manager/check.sh`. `V1Conversion` se detuvo tras 17 minutos sin terminar; modela la conversión v1 a v2, que estos cambios no tocan. Hallazgo previo en `main`, sin corregir: el manager hace `panic` si recibe `data` con un salto de línea crudo; el adaptador lo evita para este ítem.

### Evidencia ajena a estos cambios

`gateway.client` "a gateway JSON request reports no connection while its TLS handshake stalls" aborta de forma intermitente con `panic: corrupted footer metadata in bucket`. Se reprodujo en un worktree limpio de `origin/main` (`aad8f094d`), 2 veces en 20 corridas aisladas, sin ninguno de estos cambios.

### Avance local de la fase 3a: almacén y captura completa

`src/core/workspace/capture_store.zig`, `capture(arena, Request) -> Outcome`. Ningún fallo es un error de Zig; solo la falta de memoria.

- Disposición: `<perfil>/captures/<sha256(common_dir)[0..16]>/` contiene `store.git` (bare, alternates a los objetos del usuario) y, al lado, `worktrees/<sha256(git_dir)[0..16]>/` con `index`, `lock` y `scratch/`. Las carpetas de worktree quedan fuera del bare porque git reserva `worktrees/` y `git gc` lo poda. Todas con permisos 0700.
- Creación del almacén siempre bajo `init.lock`: se construye en `store.git.tmp-<ns>`, se escriben los alternates y se renombra; un almacén existe completo o no existe. Se reparan alternates faltantes y se borran construcciones a medias.
- Lock por worktree con `flock`, durante toda la captura. Un `index.lock` huérfano se informa como `capture_locked` y no se borra.
- Las rutas recibidas deben coincidir con las que resuelve git (`--show-toplevel`, `--absolute-git-dir`, `--git-common-dir`); si no, `invalid_request`.
- Index de captura persistente por worktree: la primera vez, copia del index del usuario conservando su fecha; con split index, reconstrucción desde HEAD; sparse index, `unavailable:index_sparse`.
- Listado: tracked con `ls-files` del usuario; untracked con el indexador, o con git si el indexador no lista todo (incompleto, tope, rutas largas, fuera de repositorio) o si `precomposeUnicode` y hay nombres no ASCII. Con `ignoreCase`, un renombre solo de mayúsculas no aparece como archivo nuevo.
- Repos anidados sin trackear: se excluyen como `submodule` y la captura queda `partial`, nunca `complete` ni fallida.
- Disco: `lstat` sin seguir symlinks en ningún nivel; una ruta bajo una carpeta convertida en symlink está ausente, como para git. Un error distinto de "no existe" (por ejemplo, permisos) es `failed:io_error`. Pipes, sockets y dispositivos se ignoran.
- Aplicación: `clear_flag` por flag (git aplica solo la primera de `--no-assume-unchanged` y `--no-skip-worktree`), `index_info` para entradas sparse, `force_remove` para lo que sale (`--remove` no saca archivos presentes) y `add_remove` para lo que se lee.
- Una cadena por sesión y worktree, `refs/fx/sessions/<sesión>/<worktree>`, con compare-and-swap. El tree y el commit se validan como OID del formato del repositorio.
- `comparable` es falso con exclusiones o con filtros o `info/attributes` del repositorio, que el almacén no aplica.

Dos bugs de la fase 2 aparecieron al portar los casos del prototipo y se corrigieron en `safe_git` con su test: `clear_flags` limpiaba solo `assume-unchanged`, y faltaba `force_remove`. La ruta del almacén exige git 2.29 por `--object-format`.

Evidencia: 36 tests en `capture_store.zig`, 22 portados del prototipo (primero en rojo contra un stub) y 14 propios, incluidos los de una revisión independiente. 25 mutaciones de la implementación detectadas en dos tandas.

Una segunda pasada de la revisión cerró además: claves del almacén, del worktree y de la referencia calculadas con las rutas canónicas (`/tmp/x` y `/private/tmp/x` llegan a la misma cadena); git anterior a 2.29 rechazado como `unavailable:git_refused` antes de cualquier opción nueva; repos anidados según la decisión del indexador (`boundary`), igual que git, sin falsos positivos por un `.git` vacío o un `git init` dentro de una carpeta trackeada; la falta de memoria en `lstat` se propaga como error; referencias de captura con exactamente dos segmentos; y un `store.git` sin HEAD (borrado interrumpido) se aparta antes de crear el nuevo. 40 tests en `capture_store.zig`; otras 7 mutaciones detectadas.

Contrato tras la revisión de la rama (PR #1811): `capture()` recibe una sola ruta, cualquier carpeta del worktree, y devuelve en `Outcome` el repositorio canónico (symlinks resueltos) y la referencia que extiende. Una carpeta fuera de todo repositorio da `unavailable:not_git` (`safe_git.Ready.git_dir`, sin lanzar git). `encodeRecord(phase, outcome)` en `capture_store.zig` es el único codificador del ítem de sesión: `head_state` distingue `unknown`, `unborn` y `commit`; formato, listado e index quedan en `null` si la captura no llegó a medirlos; las exclusiones van como total, conteo por motivo y una muestra de hasta 32 rutas o 32 KiB, con rutas no UTF-8 en hex; un `Outcome` contradictorio se rechaza. `Record` salió de la política. El lock de worktree espera hasta el plazo, el motivo de un `partial` es la exclusión más grave sin importar el orden (`inconsistent` > límites > secretos > submódulos), y la referencia nombra la sesión con un hash del id, así que vale cualquier id que fx acepta (`[A-Za-z0-9._-]{1,255}`). 9 de 9 mutaciones detectadas.

Limpieza tras la revisión: `safe_git` es el único dueño del parser de `ls-files` (`parseStageListing`, enum `EntryMode` con su tabla en los dos sentidos) y de la validación de OID (`isOid`), con un target de fuzz (`safe_git_output`); salieron `ignored` de la política y `gc`/`delete_ref` del almacén hasta que la retención los necesite; `prepareWithin` lleva el plazo compartido a la comprobación de versión y a `rev-parse`; un filtro nombrado por comando en el `PATH` de la ruta tiene test determinista. 4 de 4 mutaciones detectadas.

Fase 5a (`fx ask`): con el ajuste del perfil `experimental.workspace_capture` encendido, `fx ask` captura el repositorio que contiene la carpeta de la sesión al inicio de cada turno, antes de cualquier request o herramienta (gancho `start_workspace_capture` del orquestador, junto a `save_prompt_images`), y al final, justo antes del commit, que usa `commitTurnWithCaptures` con el token del turno. `src/core/workspace/turn_capture.zig` captura con un plazo de 2 s, codifica el registro y lo guarda; ningún fallo frena el turno. El ajuste es solo del perfil (`.fx.json` no puede encenderlo), está apagado por defecto y `fx config get experimental.workspace_capture` lo muestra. Evidencia: E2E en `tests/e2e/sessions.test.ts` contra el binario con gateway falso (apagado: ningún ítem ni almacén; encendido: dos registros, `partial` por `.env`, HEAD y árbol con el trabajo sin commitear en `~/.fx/captures`, `.git` del usuario intacto), que falla si se quita el gancho. Fase 5b: la TUI (agente principal) y ACP capturan igual, con E2E en `tests/e2e/sessions.test.ts` que fallan si se quita su gancho. En la TUI el pacer puede reintentar el commit del mismo turno: el token y la captura de cierre se conservan hasta que el commit se guarda (`TurnCapture.committed`). En ACP el commit del turno interrumpido anterior ocurre antes del gancho de inicio del prompt nuevo, así que usa su propio token. Las builds de libfx en WebAssembly no capturan (`turn_capture.supported`); el arreglo de `has_process_groups` para WASI corrige una regresión de la limpieza anterior que rompía esa build. Fase 5c: cada instancia de la TUI hereda el ajuste por el `Seed` de instancias; los subagentes capturan sus propios turnos en su sesión hija (en la TUI por su agente alojado, que toma el `home` del almacén de su propia sesión; en `fx ask` y ACP por `execution.TurnContext`, con el gancho de inicio en `agent_adapter` y el commit con token). E2E con el binario para `/launch` y para subagentes en `fx ask`, TUI y ACP, que fallan si se quita cada conexión. Fase 5d (D14): `AgentRuntimeDeps.executeToolCall`, el único camino de ejecución de herramientas, toma de la autoridad tipada de la acción admitida la carpeta que alcanza (el `resolved_cwd` de un comando o la carpeta del destino canónico de una mutación; nunca el texto de permisos) y llama al gancho `reach_workspace` antes de ejecutar. `TurnCapture.reach` encuentra la raíz del worktree subiendo hasta un `.git` sin lanzar git; si es un repositorio que el turno todavía no alcanzó, toma su captura de inicio antes de la acción, con `trigger_tool` en el registro, y el cierre del turno toma la de fin de cada repositorio alcanzado. Hasta 8 repositorios extra por turno; llamadas paralelas al mismo repositorio esperan su captura de inicio. Conectado en `fx ask`, la TUI, ACP y subagentes. E2E: `write_file` en otro repositorio deja inicio sin el archivo y fin con él; 3 de 3 mutaciones detectadas (sin gancho, sin fin de los alcanzados, captura después de la acción). Límite que sigue del plan: un comando que modifica otro repositorio solo por sus argumentos no se detecta.

Pendiente en 3a: el deadline no corta el escaneo del indexador, y nunca se produce `untracked_timeout`; no hay barrido de fallos de allocation (cada punto lanza git; desvío consciente de la fila 3, cubierto en parte porque la falta de memoria se propaga); un renombre de carpeta solo en mayúsculas no está probado; un `core.attributesFile` definido en la config del repositorio no vuelve la captura no comparable; `ensurePrivateDir` no protege un `profile_root` inexistente ni un `captures` que sea symlink (hoy lo mitiga `~/.fx` en 0700); falta un test con el deadline vencido a mitad de camino; la copia del index carga el archivo entero en memoria. Repositorios con submódulos quedan siempre `partial` y no comparables: decidir en la fase 6 si un submódulo limpio puede ser comparable.

Fase 3b (`src/core/workspace/capture_retention.zig`): antes de cada captura, `turn_capture` pide admisión. El espacio de `~/.fx/captures` se mide como mucho cada 10 minutos (archivo `captures/usage`); por encima de 5 GiB corre un mantenimiento por perfil (`maintenance.lock`): `gc` de cada almacén, que también termina un descarte interrumpido, y descarte de sesiones enteras hasta bajar de 4 GiB, primero las que ya no existen en el catálogo y después las de captura más antigua, con desempate por clave. Nunca la sesión actual ni las que otro proceso tiene abiertas (`Manager.isBusy`). Cada descarte se escribe y sincroniza en `captures/evictions.jsonl` antes de borrar sus referencias, y el borrado es compare-and-swap. Mientras siga por encima, las capturas salen `unavailable:budget` sin escribir. Tests con almacenes reales (orden, protegidas, journal, reclamo efectivo de espacio, recuperación, locks) y un E2E con el binario; 9 de 9 mutaciones detectadas.

Desvíos del plan en 3b:

- **Poda inmediata, no gracia de una hora.** Git saca del pack los objetos de una sesión descartada con la fecha del pack que el `gc` previo acaba de escribir, así que con gracia el espacio no bajaba y el bucle descartaba sesiones de más. La gracia se reemplaza por exclusión completa: el mantenimiento toma el `init.lock` del almacén, que toda captura pasa antes de escribir objetos, y luego el lock de cada worktree; con todos tomados no hay captura en curso y `--prune=now` es seguro. Los índices de captura se borran antes de podar, porque Git confía en ellos para archivos sin cambios.
- **Orden por última captura**, no por la primera: "inactiva más antigua" es la que hace más tiempo que no se captura.
- **Tamaño aparente redondeado a 4 KiB**, no bytes asignados.
- **Borrar la sesión no borra sus capturas todavía:** fx no tiene borrado de sesiones v2 en el producto (`Manager.delete` solo lo llama un test). Las referencias de una sesión que ya no existe se descartan primero en el próximo mantenimiento. Cuando exista el borrado, debe quitar sus referencias.
- **El mantenimiento puede frenar un turno** hasta 30 s, como mucho una vez cada 10 minutos y solo por encima del presupuesto.
- Pendiente: que lectores y forks consulten el journal, y empaquetar objetos sueltos antes de llegar al presupuesto.

## 6. Estado de verificación y riesgos abiertos

### Evidencia disponible

- `bash capture-prototype/run.sh`: 86 comprobaciones pasan con el indexador real compilado desde una copia del source.
- `LIST_MODE=git bash capture-prototype/run.sh`: las mismas 86 pasan.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s capture-prototype -p test_budget.py -v`: 6 tests pasan.
- Regresiones reproducidas antes del fix: flags, sparse obsoleto, index compartido, fecha racy y temporales compartidos. Las mutaciones correspondientes vuelven a fallar.
- Pruebas de presupuesto con objetos Git reales: orden, activas protegidas, reducción efectiva, múltiples repositorios, dentro del presupuesto y retención por gracia.

Los detalles de las corridas y su alcance están en el apéndice. Los resultados son de macOS y Git del sistema. Los scripts de prueba no son el mecanismo de producción ni están integrados en CI de fx.

### Gaps que deben cerrar las fases dependientes

- Linux, Git SHA-256, Git LFS/global filters, clones parciales, otros propietarios y symlinks/archivos hostiles bajo mutación concurrente.
- Una captura puede depender de objetos que el GC del usuario elimina. No se debe convertir esa dependencia aceptada en una promesa de durabilidad absoluta.
- Exclusión completa durante inicialización del almacén, mantenimiento y procesos Git que sobreviven a su padre; el test de temporales no cubre todas esas carreras.
- Consistencia bajo cambios externos, contexto de shell y herramientas que mutan por rutas no detectadas.
- Name/shape del control público, integración del inventario/journal y recuperación tras fallos parciales.
- Compatibilidad de builds anteriores al reanudar y volver a escribir una sesión, incluidos forks.

No se bloquea el trabajo puro de la fase 1 por gaps de etapas posteriores, pero ninguna fase dependiente avanza sin su evidencia. Si la implementación contradice un supuesto del plan, se actualiza este documento antes de ampliar el alcance.

## 7. Cómo retomar

1. Leer este documento como fuente vigente; no implementar propuestas retiradas de las revisiones históricas.
2. Verificar HEAD, dirty state y reglas del checkout. No tocar el trabajo ajeno ni asumir que la base sigue actual.
3. Ejecutar los checks de [capture-prototype/README.md](capture-prototype/README.md) si cambia la política o el comportamiento de Git que se reutiliza.
4. Empezar por la primera fase sin evidencia de producto. Guardar comandos y resultados con cada cambio.
5. Mantener un solo plan; las revisiones son evidencia histórica, no otra autoridad de diseño.

Las revisiones de versiones anteriores del plan quedaron en la historia de la rama (commit "Document turn workspace capture plan and evidence") y no constituyen aprobación de esta versión ni de una implementación.

## Apéndice A. Evidencia

### A.1 Prototipo

`capture-prototype/run.sh` implementa este diseño fuera de fx y compara cada captura con lo que registraría Git del usuario para el mismo estado, descontando las exclusiones intencionales. La lista de untracked sale del indexador real de fx, compilado desde una copia del código (`capture-prototype/list_indexer.zig`). Todos los repositorios de prueba son temporales.

Resultado del 9 de noviembre de 2026, macOS, Git del sistema: **86 de 86 comprobaciones pasan**, con el indexador y también con `LIST_MODE=git`.

El oráculo tenía el mismo defecto de copia que el caso 27 y se corrigió. Los casos que comparan con el disco byte a byte no dependen de él.

| Casos | Qué comprueban |
| --- | --- |
| 1 a 3 | Archivo modificado, staged y modificado otra vez, permiso quitado, tracked borrado, renombrado, symlink, untracked en carpeta nueva, espacios y Unicode, binario, tracked que coincide con `.gitignore`, ignorados anidados y por `info/exclude`; restauración byte a byte; repositorio del usuario intacto; capturas sucesivas; igualdad con el commit del mismo estado |
| 4 | Las capturas referenciadas sobreviven a `gc --prune=now` |
| 5 a 7 | Repositorio sin commits, worktree enlazado y submódulo registrado como gitlink |
| 8 y 9 | Dos capturas simultáneas: cada una termina o informa bloqueo, nunca un error. Un `index.lock` de una captura muerta se borra bajo el `flock`; con otro proceso capturando, se informa bloqueo de inmediato; el bloqueo desaparece con el proceso |
| 10 | Si el usuario poda los objetos de la base, `fsck --connectivity-only` lo detecta |
| 11 | Con `core.autocrlf` del repositorio el tree difiere: `comparable` debe ser `false`. En fx ya no: la fase 2 copia las conversiones del repositorio al almacén y el tree coincide (`comparable` verdadero); solo filtros o `info/attributes` del repositorio lo vuelven no comparable |
| 12 | Filtros, fsmonitor y hooks plantados: 0 ejecuciones en la captura, 24 en el control |
| 14 | Sin Git, captura de archivos tocados por herramientas (evidencia para la alternativa diferida) |
| 15 | Vínculo exacto: parcial no vincula, el resto sí, `--amend` sí, commit ajeno no |
| 16 | Sparse checkout limpio y con una edición: tree correcto, archivos fuera del disco conservados |
| 17 | Split index: index reconstruido y lista por el respaldo de Git, tree correcto |
| 18 | Sparse index: `unavailable` con `index_sparse`, sin tree |
| 19 | Vínculos: el del turno siguiente sobrevive al squash y la poda; el de la exportación encuentra commits posteriores al último turno |
| 20 | Sesión en una carpeta sin Git que edita un repositorio y corre un comando en otro: cada uno se captura antes de su primera modificación, una sola vez, con su disparador; ambos al final; un tercero sin tocar no se captura |
| 21 | Archivo con assume-unchanged y archivo con skip-worktree presente en disco, ambos modificados: se capturan como están en disco; los bits del usuario quedan intactos |
| 22 | Sparse checkout que cambia entre capturas: un archivo fuera del cono que cambió en HEAD se captura en su versión actual; uno que volvió al disco y se editó se captura desde el disco |
| 23 | Dos worktrees con un mismo almacén: cada uno captura su rama, también con `core.checkStat=minimal` y archivos de igual tamaño y fecha |
| 24 | Cambio de rama entre capturas con el index persistente |
| 25 | Retención: la cadena conserva todas las capturas mientras existe la referencia; al borrar la referencia de una sesión y limpiar, su contenido propio desaparece, el almacén se achica, la otra sesión restaura byte a byte y un objeto recién escrito por una captura en curso sobrevive |
| 26 | Configuración global sin identidad, con `logAllRefUpdates=always` y con firma GPG: la captura funciona, usa la identidad de fx, no crea reflogs y no ejecuta el programa de firma |
| 27 | Archivo cambiado en el mismo segundo que el index y con el mismo tamaño: el Git del usuario lo ve y la captura también |
| 28 | Capturas de worktrees intercaladas mediante una barrera: ambas terminan y cada tree corresponde a su propio worktree |

Fallas plantadas previas con `MUTATION`, nueve detectadas en la pasada anterior: sin rutas tracked (32 casos fallan), sin quitar rutas que salen (7), skip-worktree tratado como borrado (6), copia del index con fecha nueva (2), bits heredados sin quitar (3), entradas de sparse checkout sin actualizar (1), index compartido entre worktrees (1), vincular cualquier commit (4) y capturar un repositorio después de la acción (2).

### A.2 Mediciones

Repositorios locales leídos sin modificarlos; almacenes temporales borrados después.

| Repositorio | Archivos tracked | Contenido | Primera captura sin alternates | Primera con alternates e index copiado | Captura siguiente |
| --- | --- | --- | --- | --- | --- |
| fx | 2.206 | 45 MiB | 1,5 s; 9,5 MiB empaquetado | 0,3 s; 0 bytes | 0,07 s |
| muestra intermedia | 11.934 | 275 MiB | 10,5 s; 129 MiB | No medido | 0,2 s |
| muestra mediana | 43.055 | 524 MiB | 31,7 s; 242 MiB | 1,3 s; 1,6 MiB | 0,6 s |
| muestra grande | 118.584 | 2,0 GiB | 102 s; 502 MiB | 7,5 s; 38 MiB | 4,0 s |

Captura completa del prototipo con el indexador: `muestra mediana` 2,0 s la primera y 0,75 s las siguientes; `muestra grande` 5,1 s y 2,5 s, con 38,2 MiB de objetos y 23,5 MiB de copia del index, un costo fijo por repositorio.

Indexador frente a `git ls-files`, listas idénticas archivo por archivo: fx 0,01 s frente a 0,06 s; muestra mediana 0,17 s frente a 0,59 s; muestra grande 1,6 s frente a 4,4 s. `isCurrent` sin cambios: 0,2 s en muestra grande.

No se midió por separado el aporte de la copia del index frente al de los alternates.

### A.3 Seguridad

Repositorio trampa con HOME y configuración global aislados, filtros `clean` y `process`, fsmonitor y hooks `post-index-change`, `reference-transaction` y `pre-commit`: 0 ejecuciones durante la captura y 24 con Git normal en el mismo repositorio. Un filtro de la configuración global del usuario sí corre, según la política vigente de `safe_git`.

### A.4 Otros agentes (noviembre de 2026)

| Agente | Captura |
| --- | --- |
| OpenCode | Git interno separado, antes y después de cada paso del modelo; untracked de hasta 2 MiB; sin captura fuera de Git |
| Claude Code | Copias de los archivos que editan sus herramientas; últimos 100 checkpoints; borrado a los 30 días, orientado a deshacer |
| pi | Sin captura integrada. Extensiones: el ejemplo oficial usa `git stash create` sin referencia; las de la comunidad usan un Git privado |
| Codex | Escribía en el `.git` del usuario y lo retiró después de crecimiento de 102 GiB y clientes Git rotos |

### A.5 Relación con Sessions v2

Sessions v2 es el único almacén de sesiones (PR #1072, #1116, #1197 y #1328; diseño en `tests/tla/session_manager/system-design.md`). Ignora tipos de ítem desconocidos, limita cada línea a 4 MiB y guarda blobs por sesión sin compresión ni deduplicación entre sesiones. Por eso el contenido de archivos va al almacén Git y la sesión solo guarda identificadores pequeños.

### A.6 Dónde se trabaja realmente

Medición del 9 de noviembre de 2026 sobre el historial local de fx del usuario, contando solo carpetas y rutas que aparecen en llamadas a herramientas, sin leer contenido:

| Sesiones raíz | Cantidad |
| --- | --- |
| Total | 217 |
| Workspace dentro de un repositorio Git | 10 (5 %) |
| Workspace en el home, que no es repositorio | 174 (80 %) |
| De esas, mencionan rutas dentro de algún repositorio Git | 67 |
| De esas, sin llamadas a herramientas | 48 |
| De esas, con herramientas pero sin rutas en repositorios | 59 |
| Otros workspaces sin Git | 20 (9 %) |
| Workspace que ya no existe | 13 (6 %) |

De las 67 sesiones del home que tocan repositorios, 31 tocan más de uno. La cifra cuenta rutas mencionadas, incluidas lecturas, así que sobrestima las ediciones. El informe muestra un patrón parecido: 324 de 1.786 sesiones en el home.

Consecuencia: si la captura se decidiera solo por el workspace raíz, en este historial capturaría 10 de 217 sesiones, cuando al menos 77 trabajan sobre repositorios Git. Por eso se adoptó D14.

### A.7 Revisión de GPT 6.1

Una revisión independiente de solo lectura sobre la versión de 327 líneas pidió revisar el plan. Cada hallazgo se reprodujo aparte antes de aceptarlo:

| Hallazgo | Reproducción | Resultado |
| --- | --- | --- |
| Un archivo con assume-unchanged se captura con contenido viejo | Disco `two`, captura `one` | Confirmado; corregido (caso 21) |
| Las entradas de sparse checkout quedan obsoletas en el index persistente | Captura `old` con el archivo en `new` | Confirmado; corregido (caso 22) |
| Un index compartido entre worktrees mezcla sus contenidos | Con sparse checkout capturó `main` en `side`; sin sparse solo falla con `core.checkStat=minimal` | Confirmado; corregido (caso 23) |
| La cadena de padres impide descartar capturas antiguas | La captura más antigua sobrevive a `gc` | Confirmado; se descarta por sesión entera (caso 25) |
| El destino de permisos no es una ruta | `commandPermissionTarget` devuelve `directorio::identidad` | Confirmado; sección 3.1 |
| `assistant_stream.zig:696` es un helper de tests | Está dentro de `fn hooks` de un test | Confirmado; son seis caminos |

Al verificar esas correcciones aparecieron cuatro defectos más, que ninguna revisión había señalado: la copia del index con fecha nueva (caso 27), un archivo que vuelve al disco después de estar excluido por sparse checkout (caso 22b), la falta de identidad de Git y los reflogs por configuración global (caso 26).

## Apéndice B. Alternativas descartadas

| Alternativa | Por qué se descartó |
| --- | --- |
| Objetos y referencias en el `.git` del usuario, como propuso el thread | Codex lo hizo y lo retiró por crecimiento sin control y clientes Git rotos |
| HEAD más parches en blobs de sesión | Los parches con base fija repiten cambios pendientes, no son tree IDs y llenan el almacenamiento por sesión |
| Copia completa por turno | Más de 1,3 GiB para 30 estados de fx |
| Almacén separado sin alternates | 10 a 100 s y cientos de MiB por repositorio mediano o grande |
| `git add -A` desde el almacén | Omite tracked ignorados e incluye archivos de `info/exclude`: estado incorrecto |
| Copiar el index sin reglas | Pierde archivos de sparse checkout sin aviso y falla con split index |
| Copiar el index con fecha nueva | Desactiva la comprobación de Git para archivos cambiados en el mismo segundo que el index: captura contenido viejo (caso 27) |
| Conservar en el index de captura los bits assume-unchanged o skip-worktree del usuario | Git deja de leer esos archivos (caso 21) |
| Un index de captura por repositorio, compartido entre worktrees | Con `core.checkStat=minimal` un worktree captura el contenido del otro, y sin esa opción obliga a releer todos los archivos en cada alternancia |
| Lock solo durante cada comando Git | Un `index.lock` de un proceso muerto bloquea las capturas siguientes hasta que alguien lo borra |
| Descartar capturas sueltas dentro de una sesión | La cadena de padres las mantiene alcanzables; habría que reescribirla |
| Una referencia por captura, sin cadena | Miles de referencias en sesiones largas |
| Usar la identidad de Git del usuario | Sin identidad configurada, `commit-tree` falla y no hay captura |
| Usar el destino de permisos para saber qué repositorio toca una herramienta | Para comandos es un texto, no una ruta, y las ediciones tipadas lo rechazan |
| Hook `PostTurnEnd` para la captura final | Corre cuando el turno ya está escrito e ignora errores |
| Subagentes sin captura propia | Siguen trabajando después del turno del padre |
| Vínculos solo al exportar | Pierden commits que desaparecen por squash y poda (caso 19) |
| Retención de 30 días | Borraría el estado de las sesiones que se quieren convertir |
| Nueve límites configurables | Superficie de configuración sin datos de uso |
| Captura en paralelo y anticipada | Concurrencia adicional antes de medir latencia real |
| Detector de secretos en cada captura | El escaneo pertenece a la exportación |
| Copia autocontenida para recuperar sin el repositorio original | Más almacenamiento local; el usuario no la quiso |

## Apéndice C. Fuentes

- Informe **Turning fx sessions into evals** y thread aportados por el usuario.
- [Trace2Eval](https://arxiv.org/html/2611.06506): el 82,6 % son 38 de 46 reconstrucciones evaluables en una calibración.
- [evals-from-sessions](https://github.com/ibragim-bad/evals-from-sessions/tree/4e85a197f0b0f822461457af3056a63fb39aad93): sin historia futura en la tarea y escaneo de secretos al preparar.
- [OpenCode snapshots](https://opencode.ai/docs/snapshots/), [Claude Code checkpointing](https://code.claude.com/docs/en/checkpointing), [pi `git-checkpoint.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/git-checkpoint.ts), [pi-git-checkpoints](https://pi.dev/packages/@ian-pascoe/pi-git-checkpoints), [pi-undo-redo](https://github.com/Yueby/pi-undo-redo).
- Codex: [PR #8424](https://github.com/openai/codex/pull/8424), [issue #29388](https://github.com/openai/codex/issues/29388), [issue #28241](https://github.com/openai/codex/issues/28241), [issue #9774](https://github.com/openai/codex/issues/9774).
- Documentación de fx: [Subagents](https://fx.sh/docs/capabilities/subagents.md), [Share feedback](https://fx.sh/docs/using-fx/share-feedback.md), [Data and privacy](https://fx.sh/docs/using-fx/data-and-privacy.md).

### Evidencia de la segunda pasada y cierre enfocado

GPT 6.1 confirmó el cierre de sus tres hallazgos anteriores y encontró temporales compartidos entre worktrees. Reproducido sin alterar la captura: ambas terminan con éxito pero `main` contiene el OID sparse de `side`. El test 28 falló antes del fix (`85 passed, 1 failed`, exit 1) y pasó al aislar todos los intermedios por worktree (`86 passed, 0 failed`, exit 0). Se repitió con `LIST_MODE=git bash capture-prototype/run.sh`: 86 comprobaciones, exit 0. `MUTATION=shared_temporaries bash capture-prototype/run.sh` vuelve a fallar específicamente en 28b (`main` captura `side`), exit 1; otros fallos de esa variante se deben al cambio de ubicación de los diagnósticos y no se cuentan como evidencia independiente.

Verificación enfocada del presupuesto: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s capture-prototype -p test_budget.py -v`, 6 tests, exit 0. Variantes temporales que invierten el orden, permiten descartar activas u omiten el journal fallan con exit 1. La validación es del prototipo, no del mantenimiento integrado en fx.
