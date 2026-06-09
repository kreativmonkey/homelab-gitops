# MCP Server Integration ins n8n Alert Triage Workflow

## Status: Proposal

Ersetzt die externen OpenAI LLM-Aufrufe im Homelab Alert Triage Workflow durch
die cluster-eigene Kubernetes MCP Server Infrastruktur.

---

## Aktuelle Architektur (OpenAI)

```
Alertmanager → Parse Alert → LLM Triage (OpenAI) → Merge Triage → Route Outcome
                                                              ↓
                              Call Investigate → LLM Root Cause (OpenAI) → Route Fix
```

**Probleme:**
- OpenAI API-Key extern, potenziell kostenpflichtig
- LLM-Halluzinationen bei unklaren Alert-Daten
- Kein Zugriff auf Live-Cluster-Status
- Telegram-Credential fehlt (`CONFIGURE_ME`)

---

## Ziel-Architektur (MCP)

```
Alertmanager → Parse Alert → MCP Triage → Route Outcome
                                 ↓
         ┌───────────────────────┴──────────────────────┐
         ↓                                               ↓
   MCP Gather (K8s Tools)                       Remediation API
         ↓                                               ↓
   MCP Investigator (Code)                 LLM Root Cause (optional)
         ↓                                               ↓
   Route Outcome → Telegram                       Route Fix
```

---

## Optionen

### Option A: MCP Tool Calls + Code Node (empfohlen)

Ersetzt **beide** OpenAI-Nodes durch deterministische Code-Nodes, die
MCP-Tools via JSON-RPC/HTTP ansprechen.

**Vorgehen:**

1. **MCP Gather Node** (HTTP Request):
   - POST JSON-RPC an `http://kubernetes-mcp-server.mcp-system:8080/message`
   - Ruft nacheinander `pods_get`, `events_list`, `pods_log` auf
   - Sammelt Pod-Status, Events, Logs

2. **MCP Investigator Node** (Code):
   - Analysiert MCP-Daten deterministisch:
     - terminationReason=OOMKilled → root_cause=OOM
     - ImagePullBackOff → root_cause=CONFIG_ERROR
     - CrashLoopBackOff + connection refused → root_cause=DEPENDENCY
   - Liefert strukturiertes JSON (gleiches Format wie bisher)

3. **Remove** OpenAI Nodes:
   - `LLM Triage` (gpt-4o-mini)
   - `LLM Root Cause` (gpt-4o-mini)

**Vorteile:**
- Kein externer API-Call mehr
- Deterministisch, keine Halluzinationen
- Live-Cluster-Daten statt LLM-Raten
- Kein OpenAI-Token-Verbrauch

**Nachteile:**
- Komplexität im Code-Node (MCP JSON-RPC Client)
- Weniger flexibel bei unbekannten Fehlerbildern

### Option B: MCP + OpenAI Hybrid

Behält OpenAI bei, reichert den Prompt aber mit MCP-Clusterdaten an.

**Vorgehen:**

1. Vor dem OpenAI-Call: MCP Gather Node sammelt Pod-Logs + Events
2. OpenAI-Prompt enthält jetzt echte Cluster-Daten statt nur Alert-Meta
3. Bessere Entscheidungen durch Live-Daten

**Vorteile:**
- Weniger Änderungen am Workflow
- LLM-Flexibilität bleibt

**Nachteile:**
- OpenAI-Abhängigkeit bleibt
- Token-Verbrauch steigt durch größere Prompts

### Option C: Volle K8s API (ohne MCP)

n8n ruft direkt die Kubernetes API auf (via ServiceAccount), nicht via MCP.

**Vorgehen:**

1. n8n ServiceAccount mit Read-Rechten erstellen
2. HTTP Request Node an `https://kubernetes.default.svc/api/v1/...`
3. Code Node extrahiert Pod-Logs, Events, Status

**Vorteile:**
- Einfacher als MCP JSON-RPC (REST-API direkt)
- n8n-eigene Auth (kein extra Secret)

**Nachteile:**
- Umgeht die MCP-Abstraktion
- Kein Standardprotokoll für AI-Tools

---

## MCP JSON-RPC Zugriff (Technische Details)

Der Kubernets MCP Server verwendet **SSE Transport**:

```
1. GET /sse → session_id, message endpoint URL
2. POST /message?session_id=XXX → JSON-RPC initialize
3. POST /message?session_id=XXX → JSON-RPC tools/call
```

n8n Code-Node Implementierung (Pseudocode):

```javascript
// 1. Session initialisieren
const sseResp = await fetch('http://kubernetes-mcp-server.mcp-system:8080/sse');
// SSE stream parsen → session_id extrahieren

// 2. MCP Tool aufrufen
await fetch(`http://kubernetes-mcp-server.mcp-system:8080/message?session_id=${sid}`, {
  method: 'POST',
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'tools/call',
    params: { name: 'pods_get', arguments: { name: podName, namespace: ns } }
  })
});
```

**Hinweis:** MCP SSE ist stream-basiert — die Antwort kommt asynchron über
den SSE-Kanal zurück. Ein Code-Node müsste SSE über `fetch` + `ReadableStream`
parsen oder den HTTP EventSource-Ansatz nutzen.

---

## Voraussetzungen (bereits erledigt)

- [x] MCP-Server läuft in `mcp-system` (Port 8080)
- [x] RBAC erweitert um `metrics.k8s.io`, `nodes/stats`, `nodes/proxy`
- [x] Service `kubernetes-mcp-server.mcp-system:8080` existiert
- [x] n8n Workflow ist aktiviert
- [x] `N8N_BLOCK_ENV_ACCESS_IN_NODE: false` (Code-Nodes können fetch() nutzen)

## Noch offen

- [ ] Telegram Bot Token in n8n hinterlegen (sonst keine Notifications)
- [ ] Option wählen (A/B/C)
- [ ] Workflow-JSON exportieren/patchen
- [ ] n8n Deployment ggf. um Docker-Image ergänzen (fetch-Unterstützung)

---

## RBAC Update

Bereits durchgeführt — `infrastructure/base/mcp-server/rbac.yaml` um
`metrics.k8s.io` und `nodes/stats`/`nodes/proxy` erweitert.

```
# Vorher
  - apiGroups: [""]
    resources: ["namespaces", "nodes"]

# Nachher
  - apiGroups: [""]
    resources: ["namespaces", "nodes", "nodes/stats", "nodes/proxy"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["nodes", "pods"]
```

Damit sind alle MCP-Tools (nodes_top, pods_top, nodes_stats_summary)
nutzbar. Flux wendet das beim nächsten Sync automatisch an.

---

## Empfehlung

**Option A (MCP Tool Calls + Code Node)** — vollständiger OpenAI-Verzicht.

Das Homelab hat ~25 Applikationen mit bekannten Fehlerbildern (OOM,
ConfigError, Dependency). Deterministische Analyse via MCP-Tools ist
für diese Szenarien ausreichend und eliminiert externe Abhängigkeiten.

Bei unbekannten Fehlerbildern kann der Workflow weiterhin auf
"needs_human" routen (gleich wie bisher bei low-confidence).
