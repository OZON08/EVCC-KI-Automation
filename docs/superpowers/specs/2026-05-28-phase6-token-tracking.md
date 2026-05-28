# Phase 6 – Token-Tracking & Kostenübersicht Design Spec
_Datum: 2026-05-28_

## Ziel

Token-Verbrauch und API-Kosten jedes Claude-Aufrufs in InfluxDB speichern, täglich und monatlich aggregieren, im HA-Dashboard anzeigen.

## Architektur

```
Pro Claude-Lauf (Intraday + Daily):
  → Code-Node liest tokenUsage aus Agent-Output
  → Kosten berechnen
  → HTTP POST → InfluxDB (Zeitreihe)
  → HTTP POST → HA: sensor.battery_ai_tokens_last_run

Täglich (im Daily Optimizer, nach HA-Status-Update):
  → InfluxDB: SELECT sum(cost_usd) WHERE heute
  → InfluxDB: SELECT sum(cost_usd) WHERE dieser Monat
  → HA: sensor.battery_ai_cost_today
  → HA: sensor.battery_ai_cost_month
```

## Token-Extraktion (Code-Node)

n8n AI Agent Node gibt nach dem Lauf `tokenUsage` zurück. Zugriff:
```javascript
const usage = $input.first()?.json?.tokenUsage ?? {};
const inputTokens = usage.inputTokens ?? usage.prompt_tokens ?? 0;
const outputTokens = usage.outputTokens ?? usage.completion_tokens ?? 0;
```

**Fallback:** Falls `tokenUsage` nicht verfügbar (n8n-Version abhängig), Schätzung:
- Intraday: 4.500 Input / 400 Output (fix)
- Daily: 5.000 Input / 500 Output (fix)

Kosten berechnen:
```javascript
const cost_usd = (inputTokens / 1_000_000 * 3) + (outputTokens / 1_000_000 * 15);
```

## InfluxDB Write (Line Protocol)

```
POST http://a0d7b954-influxdb:8086/write?db=evcc
Content-Type: text/plain
Authorization: Basic <base64>

ai_costs,workflow=intraday input_tokens=4500i,output_tokens=400i,cost_usd=0.0195
```

Tag `workflow` = `intraday` oder `daily` je nach Workflow.

## InfluxDB Aggregations-Queries (täglich im Daily Optimizer)

```sql
-- Kosten heute (UTC-Tagesbeginn berechnen im Code-Node)
SELECT sum("cost_usd") FROM "ai_costs" WHERE time >= '<heute-00:00:00Z>'

-- Kosten dieser Monat
SELECT sum("cost_usd") FROM "ai_costs" WHERE time >= '<monat-01-00:00:00Z>'
```

Timestamps werden im Code-Node berechnet:
```javascript
const now = new Date();
const todayUTC = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).toISOString();
const monthUTC = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
```

## Neue HA Entities

| Entity | Inhalt |
|--------|--------|
| `sensor.battery_ai_tokens_last_run` | state: cost_usd (letzter Lauf), Attribute: input_tokens, output_tokens, workflow, timestamp |
| `sensor.battery_ai_cost_today` | state: cost_usd heute kumuliert (USD) |
| `sensor.battery_ai_cost_month` | state: cost_usd Monat kumuliert (USD) |

## Dateien die geändert werden

- `n8n-workflows/intraday-adjuster.json` — Token-Node + InfluxDB-Write nach Agent
- `n8n-workflows/daily-optimizer.json` — Token-Node + InfluxDB-Write + Aggregations-Query + HA-Sensoren
- `ha-config/dashboards/battery-ai-dashboard.yaml` — neue Karte "API-Kosten"

## Dashboard-Karte

```
API-Kosten
  Letzter Lauf: X.XX ct (N Input / M Output Tokens)
  Heute: $X.XX
  Dieser Monat: $X.XX
  [History Graph: cost_usd letzte 7 Tage]
```

## Hinweis

tokenUsage-Verfügbarkeit in n8n hängt von der installierten Version ab. Nach dem Import testen: Agent-Output in n8n Execution anschauen ob `tokenUsage` im JSON vorhanden ist. Falls nicht → Fallback-Schätzung aktivieren.
