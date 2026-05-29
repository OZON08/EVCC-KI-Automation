# Phase 6 – Token-Tracking & Kostenübersicht Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Token-Verbrauch und API-Kosten jedes Claude-Aufrufs in InfluxDB speichern und im HA-Dashboard anzeigen – pro Lauf (letzter Lauf-Sensor) sowie täglich/monatlich aggregiert.

**Architecture:** Beide Workflows bekommen nach dem Claude Agent einen Code-Node der tokenUsage ausliest (Fallback auf Schätzwerte), die Kosten berechnet und per InfluxDB Line Protocol schreibt. Der Daily Optimizer fragt zusätzlich nach jedem Lauf die Tages- und Monatssummen aus InfluxDB ab und schreibt sie als HA-Sensoren. Fan-out-Pattern aus bestehenden Workflows wird weitergeführt.

**Tech Stack:** n8n JSON workflow, InfluxDB Line Protocol (HTTP POST `/write`), InfluxDB Query API (HTTP GET `/query`), Home Assistant REST API

---

## Dateiübersicht

| Datei | Änderung |
|-------|----------|
| `n8n-workflows/intraday-adjuster.json` | 3 neue Nodes: Token berechnen + InfluxDB write + HA sensor |
| `n8n-workflows/daily-optimizer.json` | 7 neue Nodes: Token berechnen + InfluxDB write + Aggregat-Timestamps + 2× InfluxDB read + 2× HA sensor |
| `ha-config/dashboards/battery-ai-dashboard.yaml` | Neue "API-Kosten" Karte |
| `README.md` | Phase 6 auf Live setzen |

---

## Wichtige Hintergrundinformationen

### n8n-Zugriff auf Agent-Outputs in späteren Nodes
In n8n Code-Nodes kann man auf Output beliebiger vorheriger Nodes zugreifen:
```javascript
$('Claude Sonnet + evcc MCP').first()?.json?.tokenUsage
```

### InfluxDB Line Protocol schreiben
```
POST http://a0d7b954-influxdb:8086/write?db=evcc
Content-Type: text/plain
Body: ai_costs,workflow=intraday input_tokens=5000i,output_tokens=450i,cost_usd=0.02175
```
Kein JSON, sondern raw text body. Tag: `workflow=intraday` oder `workflow=daily`.

### InfluxDB Query: Summe aus Zeitreihe
```
GET http://a0d7b954-influxdb:8086/query?db=evcc&q=SELECT+sum("cost_usd")+FROM+"ai_costs"+WHERE+time+>=+'2026-05-29T00:00:00.000Z'
```
Antwort-Struktur: `results[0].series[0].values[0][1]` = Summe (oder `null` wenn keine Daten).

### Credential IDs (unveränderlich)
- Home Assistant Token: `"id": "HOwzYx39oHRQSvbp"`
- InfluxDB evcc: `"id": "r61FJRKq9t50s9A7"`

---

### Task 1: `intraday-adjuster.json` – Token-Tracking

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

Aktuelle End-Verbindung:
```
Ergebnis extrahieren -[0]-> [HA: Intraday Status aktualisieren, Einspeisen aktivieren?]
```
Neu: dritter Fan-out-Target `Token: Kosten berechnen`, das seinerseits zu InfluxDB-Write und HA-Sensor fächert.

- [ ] **Step 1: Drei neue Nodes in `nodes` Array einfügen**

Nach dem letzten Node (vor der schließenden `]`) einfügen:

```json
{
  "parameters": {
    "jsCode": "const usage = $('Claude Sonnet + evcc MCP').first()?.json?.tokenUsage ?? {};\nconst inputTokens = usage.inputTokens ?? usage.prompt_tokens ?? 5000;\nconst outputTokens = usage.outputTokens ?? usage.completion_tokens ?? 450;\nconst cost_usd = (inputTokens / 1000000 * 3) + (outputTokens / 1000000 * 15);\nconst costRounded = Math.round(cost_usd * 100000) / 100000;\nreturn [{ json: {\n  workflow: 'intraday',\n  input_tokens: inputTokens,\n  output_tokens: outputTokens,\n  cost_usd: costRounded,\n  timestamp: new Date().toISOString(),\n  line_protocol: 'ai_costs,workflow=intraday input_tokens=' + inputTokens + 'i,output_tokens=' + outputTokens + 'i,cost_usd=' + costRounded\n}}];"
  },
  "id": "token-kosten-intraday",
  "name": "Token: Kosten berechnen",
  "type": "n8n-nodes-base.code",
  "position": [2016, 240],
  "typeVersion": 2
},
{
  "parameters": {
    "method": "POST",
    "url": "http://a0d7b954-influxdb:8086/write?db=evcc",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendBody": true,
    "contentType": "raw",
    "rawContentType": "text/plain",
    "body": "={{ $json.line_protocol }}",
    "options": {}
  },
  "id": "influxdb-token-write-intraday",
  "name": "InfluxDB: Token-Kosten schreiben",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2240, 160],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
{
  "parameters": {
    "method": "POST",
    "url": "http://homeassistant:8123/api/states/sensor.battery_ai_tokens_last_run",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendBody": true,
    "specifyBody": "json",
    "jsonBody": "={{ { \"state\": String($json.cost_usd), \"attributes\": { \"input_tokens\": $json.input_tokens, \"output_tokens\": $json.output_tokens, \"workflow\": $json.workflow, \"timestamp\": $json.timestamp, \"unit_of_measurement\": \"USD\", \"friendly_name\": \"KI Tokens letzter Lauf\" } } }}",
    "options": {}
  },
  "id": "ha-token-status-intraday",
  "name": "HA: Token-Status aktualisieren",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2240, 320],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
```

- [ ] **Step 2: Connections aktualisieren**

`Ergebnis extrahieren` Eintrag finden und `Token: Kosten berechnen` als drittes Fan-out-Ziel hinzufügen. Außerdem neue Verbindungen für den Token-Teilgraph:

```json
"Ergebnis extrahieren": {
  "main": [[
    { "node": "HA: Intraday Status aktualisieren", "type": "main", "index": 0 },
    { "node": "Einspeisen aktivieren?", "type": "main", "index": 0 },
    { "node": "Token: Kosten berechnen", "type": "main", "index": 0 }
  ]]
},
"Token: Kosten berechnen": {
  "main": [[
    { "node": "InfluxDB: Token-Kosten schreiben", "type": "main", "index": 0 },
    { "node": "HA: Token-Status aktualisieren", "type": "main", "index": 0 }
  ]]
},
```

- [ ] **Step 3: JSON validieren**

```bash
cd "C:\Users\karst\Documents\Repos\EVCC-KI-Automation"
python -c "import json; json.load(open('n8n-workflows/intraday-adjuster.json')); print('JSON valid')"
```
Erwartete Ausgabe: `JSON valid`

- [ ] **Step 4: Commit**

```bash
git add n8n-workflows/intraday-adjuster.json
git commit -m "Phase 6: Token-Tracking in Intraday Adjuster"
```

---

### Task 2: `daily-optimizer.json` – Token-Tracking + Aggregation

**Files:**
- Modify: `n8n-workflows/daily-optimizer.json`

Aktuelle Endverbindung: `Ergebnis extrahieren` → `HA: Status aktualisieren` (Terminal, kein Eintrag in connections).

Neu: `HA: Status aktualisieren` → `Token: Kosten berechnen` → Fan-out zu [InfluxDB-Write, Aggregat-Timestamps] → Aggregat → Kosten heute → Kosten Monat → HA Heute → HA Monat.

- [ ] **Step 1: Sieben neue Nodes in `nodes` Array einfügen**

Nach dem letzten Node (vor der schließenden `]`) einfügen:

```json
{
  "parameters": {
    "jsCode": "const usage = $('Claude Sonnet + evcc MCP').first()?.json?.tokenUsage ?? {};\nconst inputTokens = usage.inputTokens ?? usage.prompt_tokens ?? 4500;\nconst outputTokens = usage.outputTokens ?? usage.completion_tokens ?? 500;\nconst cost_usd = (inputTokens / 1000000 * 3) + (outputTokens / 1000000 * 15);\nconst costRounded = Math.round(cost_usd * 100000) / 100000;\nreturn [{ json: {\n  workflow: 'daily',\n  input_tokens: inputTokens,\n  output_tokens: outputTokens,\n  cost_usd: costRounded,\n  timestamp: new Date().toISOString(),\n  line_protocol: 'ai_costs,workflow=daily input_tokens=' + inputTokens + 'i,output_tokens=' + outputTokens + 'i,cost_usd=' + costRounded\n}}];"
  },
  "id": "token-kosten-daily",
  "name": "Token: Kosten berechnen",
  "type": "n8n-nodes-base.code",
  "position": [1760, 208],
  "typeVersion": 2
},
{
  "parameters": {
    "method": "POST",
    "url": "http://a0d7b954-influxdb:8086/write?db=evcc",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendBody": true,
    "contentType": "raw",
    "rawContentType": "text/plain",
    "body": "={{ $json.line_protocol }}",
    "options": {}
  },
  "id": "influxdb-token-write-daily",
  "name": "InfluxDB: Token-Kosten schreiben",
  "type": "n8n-nodes-base.httpRequest",
  "position": [1984, 80],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
{
  "parameters": {
    "jsCode": "const now = new Date();\nconst todayUTC = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).toISOString();\nconst monthUTC = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();\nreturn [{ json: {\n  today_utc: todayUTC,\n  month_utc: monthUTC,\n  query_today: 'SELECT sum(\"cost_usd\") FROM \"ai_costs\" WHERE time >= \\'' + todayUTC + '\\'',\n  query_month: 'SELECT sum(\"cost_usd\") FROM \"ai_costs\" WHERE time >= \\'' + monthUTC + '\\''\n}}];"
  },
  "id": "aggregat-timestamps",
  "name": "Aggregat-Timestamps",
  "type": "n8n-nodes-base.code",
  "position": [1984, 208],
  "typeVersion": 2
},
{
  "parameters": {
    "url": "http://a0d7b954-influxdb:8086/query",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendQuery": true,
    "queryParameters": {
      "parameters": [
        { "name": "db", "value": "evcc" },
        { "name": "q", "value": "={{ $json.query_today }}" }
      ]
    },
    "options": {}
  },
  "id": "influxdb-kosten-heute",
  "name": "InfluxDB: Kosten heute",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2208, 208],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
{
  "parameters": {
    "url": "http://a0d7b954-influxdb:8086/query",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendQuery": true,
    "queryParameters": {
      "parameters": [
        { "name": "db", "value": "evcc" },
        { "name": "q", "value": "={{ $('Aggregat-Timestamps').first().json.query_month }}" }
      ]
    },
    "options": {}
  },
  "id": "influxdb-kosten-monat",
  "name": "InfluxDB: Kosten Monat",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2432, 208],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
{
  "parameters": {
    "method": "POST",
    "url": "http://homeassistant:8123/api/states/sensor.battery_ai_cost_today",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendBody": true,
    "specifyBody": "json",
    "jsonBody": "={{ { \"state\": String(Math.round(($('InfluxDB: Kosten heute').first()?.json?.results?.[0]?.series?.[0]?.values?.[0]?.[1] ?? 0) * 10000) / 10000), \"attributes\": { \"unit_of_measurement\": \"USD\", \"friendly_name\": \"KI API-Kosten heute\" } } }}",
    "options": {}
  },
  "id": "ha-kosten-heute",
  "name": "HA: Kosten heute aktualisieren",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2656, 208],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
{
  "parameters": {
    "method": "POST",
    "url": "http://homeassistant:8123/api/states/sensor.battery_ai_cost_month",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendBody": true,
    "specifyBody": "json",
    "jsonBody": "={{ { \"state\": String(Math.round(($('InfluxDB: Kosten Monat').first()?.json?.results?.[0]?.series?.[0]?.values?.[0]?.[1] ?? 0) * 10000) / 10000), \"attributes\": { \"unit_of_measurement\": \"USD\", \"friendly_name\": \"KI API-Kosten Monat\" } } }}",
    "options": {}
  },
  "id": "ha-kosten-monat",
  "name": "HA: Kosten Monat aktualisieren",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2880, 208],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
```

- [ ] **Step 2: Connections aktualisieren**

Im `connections` Objekt folgende neue Einträge hinzufügen:

```json
"HA: Status aktualisieren": {
  "main": [[
    { "node": "Token: Kosten berechnen", "type": "main", "index": 0 }
  ]]
},
"Token: Kosten berechnen": {
  "main": [[
    { "node": "InfluxDB: Token-Kosten schreiben", "type": "main", "index": 0 },
    { "node": "Aggregat-Timestamps", "type": "main", "index": 0 }
  ]]
},
"Aggregat-Timestamps": {
  "main": [[
    { "node": "InfluxDB: Kosten heute", "type": "main", "index": 0 }
  ]]
},
"InfluxDB: Kosten heute": {
  "main": [[
    { "node": "InfluxDB: Kosten Monat", "type": "main", "index": 0 }
  ]]
},
"InfluxDB: Kosten Monat": {
  "main": [[
    { "node": "HA: Kosten heute aktualisieren", "type": "main", "index": 0 }
  ]]
},
"HA: Kosten heute aktualisieren": {
  "main": [[
    { "node": "HA: Kosten Monat aktualisieren", "type": "main", "index": 0 }
  ]]
},
```

- [ ] **Step 3: JSON validieren**

```bash
cd "C:\Users\karst\Documents\Repos\EVCC-KI-Automation"
python -c "import json; json.load(open('n8n-workflows/daily-optimizer.json')); print('JSON valid')"
```
Erwartete Ausgabe: `JSON valid`

- [ ] **Step 4: Commit**

```bash
git add n8n-workflows/daily-optimizer.json
git commit -m "Phase 6: Token-Tracking + Kosten-Aggregation in Daily Optimizer"
```

---

### Task 3: Dashboard + README + Push

**Files:**
- Modify: `ha-config/dashboards/battery-ai-dashboard.yaml`
- Modify: `README.md`

- [ ] **Step 1: Neue "API-Kosten" Karte in Dashboard einfügen**

In `battery-ai-dashboard.yaml` vor dem `history-graph` Block (nach der Steuerungskarte) einfügen:

```yaml
          # API-Kosten
          - type: entities
            title: "API-Kosten (Claude)"
            entities:
              - entity: sensor.battery_ai_tokens_last_run
                name: "Letzter Lauf (USD)"
                icon: mdi:currency-usd
              - type: attribute
                entity: sensor.battery_ai_tokens_last_run
                attribute: input_tokens
                name: "Input-Tokens"
                icon: mdi:import
              - type: attribute
                entity: sensor.battery_ai_tokens_last_run
                attribute: output_tokens
                name: "Output-Tokens"
                icon: mdi:export
              - type: attribute
                entity: sensor.battery_ai_tokens_last_run
                attribute: workflow
                name: "Workflow"
                icon: mdi:cog
              - entity: sensor.battery_ai_cost_today
                name: "Heute (USD)"
                icon: mdi:calendar-today
              - entity: sensor.battery_ai_cost_month
                name: "Dieser Monat (USD)"
                icon: mdi:calendar-month
```

- [ ] **Step 2: README – Phase 6 auf Live setzen + HA Entities ergänzen**

In `README.md` den Phase-6-Abschnitt ersetzen:

```markdown
## Phase 6 – Token-Tracking & Kostenübersicht ✅ Live

Token-Verbrauch und API-Kosten jedes Claude-Aufrufs in InfluxDB gespeichert, täglich/monatlich aggregiert.

- `tokenUsage` aus Agent-Output → InfluxDB `ai_costs` Zeitreihe (Tag: `workflow=intraday|daily`)
- Daily Optimizer aggregiert täglich Tages- und Monatssummen → HA-Sensoren
- Fallback-Schätzung wenn `tokenUsage` nicht verfügbar: 5.000/450 Tokens (Intraday), 4.500/500 (Daily)
```

Außerdem in der HA Entities Tabelle drei neue Zeilen nach `sensor.battery_intraday_adjustment` einfügen:

```markdown
| `sensor.battery_ai_tokens_last_run` | Sensor | Kosten + Tokens letzter Claude-Aufruf |
| `sensor.battery_ai_cost_today` | Sensor | API-Kosten heute kumuliert (USD) |
| `sensor.battery_ai_cost_month` | Sensor | API-Kosten Monat kumuliert (USD) |
```

- [ ] **Step 3: Commit und Push**

```bash
git add ha-config/dashboards/battery-ai-dashboard.yaml README.md
git commit -m "Phase 6: Dashboard API-Kosten Karte + README"
git push
```

---

## Verifikation (End-to-End)

Nach Abschluss aller Tasks:

1. **intraday-adjuster.json** in n8n importieren, Credentials prüfen, manuell triggern
   - In n8n Execution: Node `Token: Kosten berechnen` → Output zeigt `cost_usd`, `input_tokens`, `output_tokens`
   - Node `InfluxDB: Token-Kosten schreiben` → HTTP 204 (kein Body = Erfolg)
   - Node `HA: Token-Status aktualisieren` → HTTP 200/201
   - HA: `sensor.battery_ai_tokens_last_run` zeigt Wert (z.B. `0.02175`) mit Attributen

2. **daily-optimizer.json** in n8n importieren, manuell triggern
   - Node `Aggregat-Timestamps` → `today_utc` und `month_utc` vorhanden
   - Node `InfluxDB: Kosten heute` → `results[0].series[0].values[0][1]` = Summe (oder null wenn noch keine Daten)
   - HA: `sensor.battery_ai_cost_today` zeigt Wert
   - HA: `sensor.battery_ai_cost_month` zeigt Wert

3. InfluxDB-Daten prüfen (optional):
   ```
   GET http://a0d7b954-influxdb:8086/query?db=evcc&q=SELECT+*+FROM+"ai_costs"+LIMIT+5
   ```
   Liefert Einträge mit `workflow`, `input_tokens`, `output_tokens`, `cost_usd`.

**Hinweis zu `tokenUsage`:** Falls der Agent-Node kein `tokenUsage` liefert (n8n-Version abhängig), greifen die Fallback-Schätzwerte (5.000/450 für Intraday, 4.500/500 für Daily). Erkennbar daran, dass immer exakt dieselben Werte erscheinen.
