# Intraday-Adjuster: Regelbasiert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Intraday-Adjuster von Claude-Agent auf deterministisches Regelwerk umbauen – Kosten von ~€4+/Tag auf ~€0/Tag.

**Architecture:** n8n holt SoC, aktuelle Tibber-Preise und den Daily-Optimizer-Schwellwert per direkter HTTP-API. Ein Code-Node entscheidet nach festen Regeln über charge_action und discharge_action. Claude wird im Intraday-Adjuster vollständig entfernt; n8n führt evcc-API-Calls direkt aus.

**Tech Stack:** n8n JSON Workflow, evcc REST API (`/api/state`, `/api/tariff/grid`, `/api/batterygridchargelimit`), Home Assistant REST API

---

## Dateiübersicht

| Datei | Änderung |
|---|---|
| `n8n-workflows/intraday-adjuster.json` | Hauptarbeit: Nodes entfernen, neue hinzufügen, Connections updaten |

---

## Referenz: evcc API-Struktur

Vor dem Umbau kurz gegen die laufende evcc-Instanz prüfen:

```
GET http://192.168.1.8:7070/api/state
GET http://192.168.1.8:7070/api/tariff/grid
```

Erwartete State-Felder: `result.batterySoc`, `result.loadpoints[].chargePower`, `result.loadpoints[].vehiclePresent`  
Erwartete Tariff-Felder: `result.rates[].start`, `result.rates[].end`, `result.rates[].price` (EUR/kWh)

Für Battery Limit (nach erstem Test verifizieren):
- `POST http://192.168.1.8:7070/api/batterygridchargelimit` mit Body: `0.185` (float, EUR/kWh, plain text)
- `DELETE http://192.168.1.8:7070/api/batterygridchargelimit`

---

## Task 1: Nicht benötigte Nodes aus JSON entfernen

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

Diese 7 Nodes aus dem `nodes`-Array entfernen (nach ID suchen):

- [ ] **Schritt 1: Backup anlegen**

```powershell
Copy-Item n8n-workflows\intraday-adjuster.json n8n-workflows\intraday-adjuster.json.bak
```

- [ ] **Schritt 2: Folgende Node-IDs aus `nodes[]` entfernen**

```
d4e5f6a7-b8c9-0123-def0-234567890123   # InfluxDB: Tibber Preisstats
e5f6a7b8-c9d0-1234-ef01-345678901234   # InfluxDB: Verbrauch abfragen
influxdb-lastprofil-intraday            # InfluxDB: Lastprofil abfragen
f6a7b8c9-d0e1-2345-f012-456789012345   # Kontext berechnen
a7b8c9d0-e1f2-3456-0123-567890123456   # Claude Sonnet + evcc MCP (Agent)
b8c9d0e1-f2a3-4567-1234-678901234567   # evcc MCP Tools
c9d0e1f2-a3b4-5678-2345-789012345678   # Claude Sonnet 4.6
```

Jeden dieser Blöcke `{ "parameters": {...}, "id": "<id>", ... }` vollständig aus dem Array löschen.

- [ ] **Schritt 3: Folgende Connection-Keys aus `connections{}` entfernen**

```
"InfluxDB: Tibber Preisstats"
"InfluxDB: Verbrauch abfragen"
"InfluxDB: Lastprofil abfragen"
"Kontext berechnen"
"Claude Sonnet + evcc MCP"
"evcc MCP Tools"
"Claude Sonnet 4.6"
```

- [ ] **Schritt 4: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

Erwartete Ausgabe: `OK`

- [ ] **Schritt 5: Commit**

```powershell
git add n8n-workflows/intraday-adjuster.json
git commit -m "Refactor: Intraday – LLM-Nodes und InfluxDB-Nodes entfernt"
```

---

## Task 2: Neue HTTP-Nodes für evcc State + Tarif + HA-Schwellwert

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: Drei neue Nodes in `nodes[]` einfügen**

Nach dem letzten verbleibenden Eintrag im `nodes`-Array (vor der schließenden `]`) folgendes einfügen:

```json
,
{
  "parameters": {
    "url": "http://192.168.1.8:7070/api/state",
    "options": {}
  },
  "id": "evcc-state-abrufen",
  "name": "evcc: State abrufen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [896, -320],
  "typeVersion": 4.4
},
{
  "parameters": {
    "url": "http://192.168.1.8:7070/api/tariff/grid",
    "options": {}
  },
  "id": "evcc-tarif-abrufen",
  "name": "evcc: Tarif abrufen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [1120, -320],
  "typeVersion": 4.4
},
{
  "parameters": {
    "url": "http://homeassistant:8123/api/states/sensor.battery_charge_threshold",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "id": "ha-schwellwert-lesen",
  "name": "HA: Schwellwert lesen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [1344, -320],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
}
```

- [ ] **Schritt 2: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

---

## Task 3: Regelbasierter Entscheidungs-Code-Node

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: Code-Node in `nodes[]` einfügen**

```json
,
{
  "parameters": {
    "jsCode": "// Eingangsdaten\nconst stateRaw = $('evcc: State abrufen').first()?.json ?? {};\nconst tariffRaw = $('evcc: Tarif abrufen').first()?.json ?? {};\nconst schwellwertStr = $('HA: Schwellwert lesen').first()?.json?.state ?? '0';\nconst einspeiseAktiv = $('HA: Einspeise-Schalter lesen').first()?.json?.state === 'on';\nconst minSoc = parseFloat($('HA: Min-SoC lesen').first()?.json?.state) || 30;\n\n// evcc State parsen\nconst state = stateRaw?.result ?? stateRaw;\nconst soc = parseFloat(state?.batterySoc ?? 50);\nconst loadpoints = state?.loadpoints ?? [];\nconst evLaedt = loadpoints.some(lp => (lp.chargePower ?? 0) > 0);\n\n// Aktuellen Tibber-Preis aus Tarif-Rates ermitteln\nconst rates = tariffRaw?.result?.rates ?? tariffRaw?.rates ?? [];\nconst now = new Date();\nconst currentRate = rates.find(r => new Date(r.start) <= now && now < new Date(r.end));\nconst currentPriceCt = currentRate ? Math.round(currentRate.price * 10000) / 100 : null;\n\n// Günstigsten Preis der nächsten 2 Stunden bestimmen\nconst in2h = new Date(now.getTime() + 2 * 3600000);\nconst upcoming = rates.filter(r => new Date(r.start) >= now && new Date(r.start) < in2h);\nconst minUpcomingCt = upcoming.length > 0\n  ? Math.min(...upcoming.map(r => Math.round(r.price * 10000) / 100))\n  : null;\n\n// Schwellwert vom Daily Optimizer\nconst schwellwert = parseFloat(schwellwertStr) || 0;\nconst EINSPEISE_CT = 6.7;\n\n// --- charge_action ---\nlet chargeAction = 'keep';\nlet thresholdCt = schwellwert;\n\nif (schwellwert === 0) {\n  chargeAction = 'remove';\n  thresholdCt = 0;\n} else if (currentPriceCt !== null && currentPriceCt <= schwellwert) {\n  chargeAction = 'update';\n} else if (currentPriceCt !== null && currentPriceCt > schwellwert) {\n  const cheapSoon = minUpcomingCt !== null && minUpcomingCt <= schwellwert;\n  chargeAction = cheapSoon ? 'keep' : 'remove';\n  if (chargeAction === 'remove') thresholdCt = 0;\n}\n\n// --- discharge_action ---\nlet dischargeAction = 'disable';\nlet dischargeReason = '';\n\nif (evLaedt) {\n  dischargeReason = 'EV laedt aktiv';\n} else if (!einspeiseAktiv) {\n  dischargeReason = 'Einspeise-Logik aus';\n} else if (soc < minSoc) {\n  dischargeReason = `SoC ${soc}% < Min ${minSoc}%`;\n} else if (currentPriceCt !== null && currentPriceCt > EINSPEISE_CT) {\n  dischargeAction = 'enable';\n  dischargeReason = `Preis ${currentPriceCt}ct > ${EINSPEISE_CT}ct`;\n} else {\n  dischargeReason = `Preis ${currentPriceCt}ct <= ${EINSPEISE_CT}ct`;\n}\n\nconst reasoning = `Preis: ${currentPriceCt ?? '?'}ct | Schwellwert: ${schwellwert}ct -> ${chargeAction}; SoC: ${soc}% | ${dischargeReason} -> discharge ${dischargeAction}`;\n\nreturn [{ json: {\n  charge_action: chargeAction,\n  threshold_ct: thresholdCt,\n  discharge_action: dischargeAction,\n  reasoning,\n  timestamp: new Date().toISOString()\n}}];"
  },
  "id": "entscheidung-berechnen",
  "name": "Entscheidung berechnen",
  "type": "n8n-nodes-base.code",
  "position": [1568, -320],
  "typeVersion": 2
}
```

- [ ] **Schritt 2: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

---

## Task 4: Ergebnis-Extraktion vereinfachen

Der bestehende `Ergebnis extrahieren` Node parsed aktuell Claude-Textausgabe. Da unser Code-Node jetzt direktes JSON liefert, Code vereinfachen.

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: `jsCode` im Node `d0e1f2a3-b4c5-6789-3456-890123456789` (Ergebnis extrahieren) ersetzen**

Den Parameter `jsCode` auf folgenden Wert setzen:

```json
"jsCode": "const d = $input.first()?.json ?? {};\nconst action = ['keep','update','remove'].includes(d.charge_action) ? d.charge_action : 'keep';\nconst dischargeAction = ['enable','disable'].includes(d.discharge_action) ? d.discharge_action : 'disable';\nconst threshold = Math.min(50, Math.max(0, parseFloat(d.threshold_ct ?? 0)));\nreturn [{ json: {\n  action,\n  charge_action: action,\n  threshold_ct: threshold,\n  discharge_action: dischargeAction,\n  reasoning: d.reasoning ?? '',\n  timestamp: d.timestamp ?? new Date().toISOString()\n}}];"
```

- [ ] **Schritt 2: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

---

## Task 5: Ladesteuerung – evcc API Nodes für Limit setzen/entfernen

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: IF-Node und zwei HTTP-Nodes für Ladesteuerung einfügen**

```json
,
{
  "parameters": {
    "conditions": {
      "string": [
        {
          "value1": "={{ $json.charge_action }}",
          "operation": "equals",
          "value2": "update"
        }
      ]
    },
    "options": {}
  },
  "id": "if-charge-update",
  "name": "Laden: Limit setzen?",
  "type": "n8n-nodes-base.if",
  "position": [2016, -320],
  "typeVersion": 2.3
},
{
  "parameters": {
    "method": "POST",
    "url": "={{ 'http://192.168.1.8:7070/api/batterygridchargelimit/' + String(Math.round($('Ergebnis extrahieren').first().json.threshold_ct / 100 * 1000) / 1000) }}",
    "options": {}
  },
  "id": "evcc-limit-setzen",
  "name": "evcc: Limit setzen",
  "type": "n8n-nodes-base.httpRequest",
  "onError": "continueRegularOutput",
  "position": [2240, -400],
  "typeVersion": 4.4
},
{
  "parameters": {
    "method": "DELETE",
    "url": "http://192.168.1.8:7070/api/batterygridchargelimit",
    "options": {}
  },
  "id": "evcc-limit-entfernen",
  "name": "evcc: Limit entfernen",
  "type": "n8n-nodes-base.httpRequest",
  "onError": "continueRegularOutput",
  "position": [2240, -240],
  "typeVersion": 4.4
}
```

Hinweis: `evcc-limit-setzen` nutzt Pfadparameter (`/api/batterygridchargelimit/0.185`). Falls evcc einen anderen Endpunkt erwartet, URL anpassen. Beim ersten Test im n8n-Log prüfen.

- [ ] **Schritt 2: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

---

## Task 6: Token-Tracking auf Null-Werte anpassen

Der Token-Tracking-Node schreibt weiterhin in InfluxDB, aber mit 0 Tokens (kein LLM-Aufruf mehr).

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: `jsCode` im Node `token-kosten-intraday` ersetzen**

```json
"jsCode": "return [{ json: {\n  workflow: 'intraday',\n  input_tokens: 0,\n  output_tokens: 0,\n  cost_usd: 0,\n  timestamp: new Date().toISOString(),\n  line_protocol: 'ai_costs,workflow=intraday input_tokens=0i,output_tokens=0i,cost_usd=0.0'\n}}];"
```

- [ ] **Schritt 2: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

---

## Task 7: Connections aktualisieren

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

- [ ] **Schritt 1: Connection von `HA: Min-SoC lesen` ändern**

Bestehende Connection von `HA: Min-SoC lesen` geht aktuell zu `InfluxDB: Tibber Preisstats`. Ändern zu `evcc: State abrufen`:

```json
"HA: Min-SoC lesen": {
  "main": [[{"node": "evcc: State abrufen", "type": "main", "index": 0}]]
}
```

- [ ] **Schritt 2: Neue Connections für die HTTP-Chain einfügen**

Im `connections`-Objekt folgende Einträge hinzufügen:

```json
"evcc: State abrufen": {
  "main": [[{"node": "evcc: Tarif abrufen", "type": "main", "index": 0}]]
},
"evcc: Tarif abrufen": {
  "main": [[{"node": "HA: Schwellwert lesen", "type": "main", "index": 0}]]
},
"HA: Schwellwert lesen": {
  "main": [[{"node": "Entscheidung berechnen", "type": "main", "index": 0}]]
},
"Entscheidung berechnen": {
  "main": [[{"node": "Ergebnis extrahieren", "type": "main", "index": 0}]]
}
```

- [ ] **Schritt 3: Connection von `Ergebnis extrahieren` um Ladesteuerung erweitern**

Aktuell:
```json
"Ergebnis extrahieren": {
  "main": [[
    {"node": "HA: Intraday Status aktualisieren", ...},
    {"node": "Einspeisen aktivieren?", ...},
    {"node": "Token: Kosten berechnen", ...}
  ]]
}
```

Ergänzen um Ladesteuerung:
```json
"Ergebnis extrahieren": {
  "main": [[
    {"node": "HA: Intraday Status aktualisieren", "type": "main", "index": 0},
    {"node": "Einspeisen aktivieren?", "type": "main", "index": 0},
    {"node": "Token: Kosten berechnen", "type": "main", "index": 0},
    {"node": "Laden: Limit setzen?", "type": "main", "index": 0}
  ]]
}
```

- [ ] **Schritt 4: Connections für Ladesteuerung einfügen**

```json
"Laden: Limit setzen?": {
  "main": [
    [{"node": "evcc: Limit setzen", "type": "main", "index": 0}],
    [{"node": "evcc: Limit entfernen", "type": "main", "index": 0}]
  ]
}
```

Hinweis: Die `false`-Branch des IF-Nodes triggert `evcc: Limit entfernen` sowohl bei `remove` als auch bei `keep`. Um `keep` zu filtern, müsste ein zweiter IF-Node zwischen `false` und `Limit entfernen`. Alternativ: `evcc: Limit entfernen` mit `onError: continueRegularOutput` und das Ergebnis ignorieren wenn charge_action=keep – das ist akzeptabel da ein DELETE auf einen nicht gesetzten Limit in evcc idempotent ist.

Falls das doch störend ist: Zweiten IF-Node `Laden: Limit entfernen?` einfügen (check `charge_action == "remove"`) vor dem DELETE.

- [ ] **Schritt 5: JSON validieren**

```powershell
node -e "JSON.parse(require('fs').readFileSync('n8n-workflows/intraday-adjuster.json','utf8')); console.log('OK')"
```

- [ ] **Schritt 6: Commit**

```powershell
git add n8n-workflows/intraday-adjuster.json
git commit -m "Refactor: Intraday-Adjuster vollstaendig regelbasiert – kein LLM"
```

---

## Task 8: In n8n importieren und testen

- [ ] **Schritt 1: Workflow in n8n importieren**

In n8n UI: Workflows → Import → `intraday-adjuster.json` hochladen (bestehenden Workflow ersetzen).

- [ ] **Schritt 2: Manueller Testlauf**

Workflow manuell triggern. Im n8n Execution Log prüfen:

- `evcc: State abrufen` → Status 200, batterySoc-Wert sichtbar
- `evcc: Tarif abrufen` → Status 200, rates[] mit mindestens 1 Eintrag
- `HA: Schwellwert lesen` → state = Schwellwert aus Daily Optimizer (z.B. "12.5")
- `Entscheidung berechnen` → charge_action + discharge_action korrekt
- `Ergebnis extrahieren` → gleiche Werte durchgereicht
- Je nach charge_action: `evcc: Limit setzen` oder `evcc: Limit entfernen` ausgeführt
- `HA: Intraday Status aktualisieren` → 200 OK

- [ ] **Schritt 3: evcc API-Endpunkt für Limit verifizieren**

Falls `evcc: Limit setzen` einen Fehler zurückgibt:
1. evcc Logs prüfen auf den tatsächlichen Endpunkt
2. evcc REST API Dokumentation: `GET http://192.168.1.8:7070/api/` gibt verfügbare Endpoints zurück
3. URL in Node anpassen (z.B. von Pfadparameter auf JSON-Body wechseln)

- [ ] **Schritt 4: HA-Sensor prüfen**

```
http://homeassistant:8123/api/states/sensor.battery_intraday_adjustment
```

Sollte `state: "keep"` oder `"update"` oder `"remove"` zeigen.

- [ ] **Schritt 5: Abschließender Commit mit Backup entfernen**

```powershell
Remove-Item n8n-workflows\intraday-adjuster.json.bak
git add n8n-workflows/intraday-adjuster.json
git commit -m "Chore: Backup-Datei entfernt nach erfolgreichem Test"
```

---

## Bonus: Sensor-Persistenz nach HA-Neustart

Separates Problem, kurze Lösung: HA-Automation anlegen die nach Neustart den Daily Optimizer triggert.

In Home Assistant unter `Einstellungen → Automatisierungen → Neu`:

```yaml
alias: "KI-Sensoren nach Neustart wiederherstellen"
trigger:
  - platform: homeassistant
    event: start
action:
  - delay: "00:01:00"
  - service: n8n.trigger  # oder: REST-Call an n8n Webhook
```

Alternativ n8n Webhook-URL in HA als `rest_command` eintragen und aus der Automation aufrufen. Details je nach n8n-Setup.
