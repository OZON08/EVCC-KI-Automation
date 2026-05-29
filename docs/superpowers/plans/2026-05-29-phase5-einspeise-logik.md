# Phase 5 – Einspeise-Logik Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate feed-in logic into the Intraday Adjuster so Claude decides both grid charging and battery discharge based on forecast surplus, with a configurable minimum SoC via HA slider.

**Architecture:** Two new HA read nodes (Einspeise-Schalter + Min-SoC) are added sequentially before the InfluxDB queries. The Kontext berechnen Code-Node reads both values and extends the prompt. Claude returns an extended JSON with `charge_action` + `discharge_action`. After extraction, a fan-out sends the result to HA sensor update AND a new IF node that conditionally calls evcc's batterydischargecontrol endpoint.

**Tech Stack:** n8n JSON workflow, Home Assistant YAML config, evcc REST API (`POST /api/batterydischargecontrol/true|false`)

---

### Task 1: HA Entity `input_number.min_soc_einspeisen` anlegen

**Files:**
- Modify: `ha-config/input_numbers.yaml`

- [ ] **Step 1: min_soc_einspeisen in input_numbers.yaml ergänzen**

Datei öffnen und den neuen Block anhängen:

```yaml
# Home Assistant Input Numbers – KI-Batteriesteuerung
# 0 = KI übernimmt, >0 = manueller Schwellwert in ct/kWh

input_number:
  manueller_preisschwellwert:
    name: "Manueller Preisschwellwert"
    icon: mdi:currency-eur
    unit_of_measurement: "ct/kWh"
    min: 0
    max: 50
    step: 0.1
    initial: 0
    mode: slider

  min_soc_einspeisen:
    name: "Min. SoC Einspeisen"
    icon: mdi:battery-arrow-down
    unit_of_measurement: "%"
    min: 10
    max: 50
    step: 5
    initial: 30
    mode: slider
```

- [ ] **Step 2: In Home Assistant anlegen**

In HA unter Einstellungen → Helfer → Eingabe: Zahl neu anlegen ODER `configuration.yaml` neu laden (falls input_numbers.yaml per `!include` eingebunden):

```
Einstellungen → System → YAML neu laden → Eingabe: Zahlen
```

Verifizieren: `input_number.min_soc_einspeisen` erscheint in HA Entitäten-Liste mit Wert 30.

- [ ] **Step 3: Commit**

```bash
git add ha-config/input_numbers.yaml
git commit -m "Add input_number.min_soc_einspeisen for configurable discharge SoC limit"
```

---

### Task 2: `intraday-adjuster.json` erweitern

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

Dies ist die Hauptänderung. Die komplette Datei wird ersetzt mit allen Erweiterungen.

- [ ] **Step 1: Neue Nodes definieren – HA: Einspeise-Schalter lesen**

In `intraday-adjuster.json` nach dem letzten Node in der `nodes` Array folgenden Node einfügen:

```json
{
  "parameters": {
    "url": "http://homeassistant:8123/api/states/input_boolean.einspeise_logik_aktiv",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "id": "ha-einspeise-schalter",
  "name": "HA: Einspeise-Schalter lesen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [672, -160],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
```

- [ ] **Step 2: Neuer Node – HA: Min-SoC lesen**

Direkt dahinter einfügen:

```json
{
  "parameters": {
    "url": "http://homeassistant:8123/api/states/input_number.min_soc_einspeisen",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "id": "ha-min-soc",
  "name": "HA: Min-SoC lesen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [672, -320],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
```

- [ ] **Step 3: Neuer IF-Node – Einspeisen aktivieren?**

```json
{
  "parameters": {
    "conditions": {
      "string": [
        {
          "value1": "={{ $json.discharge_action }}",
          "operation": "equals",
          "value2": "enable"
        }
      ]
    },
    "options": {}
  },
  "id": "if-discharge",
  "name": "Einspeisen aktivieren?",
  "type": "n8n-nodes-base.if",
  "position": [2016, 0],
  "typeVersion": 2.3
},
```

- [ ] **Step 4: Neue evcc-Nodes für batterydischargecontrol**

```json
{
  "parameters": {
    "method": "POST",
    "url": "http://192.168.1.8:7070/api/batterydischargecontrol/true",
    "options": {}
  },
  "id": "evcc-discharge-on",
  "name": "evcc: Entladen aktivieren",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2240, -80],
  "typeVersion": 4.4
},
{
  "parameters": {
    "method": "POST",
    "url": "http://192.168.1.8:7070/api/batterydischargecontrol/false",
    "options": {}
  },
  "id": "evcc-discharge-off",
  "name": "evcc: Entladen deaktivieren",
  "type": "n8n-nodes-base.httpRequest",
  "position": [2240, 80],
  "typeVersion": 4.4
},
```

- [ ] **Step 5: "Kontext berechnen" jsCode aktualisieren**

Den bestehenden `jsCode` String in der "Kontext berechnen" Node durch folgenden ersetzen. Die Änderungen betreffen: Lesen von Einspeise-Schalter + Min-SoC, Erweiterung des Prompts, neues JSON-Format mit `charge_action` + `discharge_action`:

```javascript
const tariffRaw = $('InfluxDB: Tibber Preisstats').first()?.json ?? {};
const homeRaw = $input.first()?.json ?? {};

// Einspeise-Logik Werte aus HA lesen
const einspeiseAktiv = $('HA: Einspeise-Schalter lesen').first()?.json?.state === 'on';
const minSoc = parseFloat($('HA: Min-SoC lesen').first()?.json?.state ?? '30');

// Process tariffGrid: compute price stats for today's weekday
const tariffSeries = tariffRaw?.results?.[0]?.series?.[0]?.values ?? [];
const todayWeekday = new Date().getDay();

const sameWeekdayPrices = tariffSeries
  .filter(([time]) => new Date(time).getDay() === todayWeekday)
  .map(([, price]) => price)
  .filter(p => typeof p === 'number' && p > 0);

const allPrices = tariffSeries
  .map(([, price]) => price)
  .filter(p => typeof p === 'number' && p > 0);

const prices = sameWeekdayPrices.length >= 10 ? sameWeekdayPrices : allPrices;
const priceSource = sameWeekdayPrices.length >= 10 ? 'gleicher Wochentag (90 Tage)' : 'alle Wochentage (90 Tage)';

const avg_price = prices.length > 0 ? prices.reduce((a, b) => a + b, 0) / prices.length : 20;
const min_price = prices.length > 0 ? Math.min(...prices) : 10;
const max_price = prices.length > 0 ? Math.max(...prices) : 40;

// Process homePower: avg consumption (same weekday preferred)
const homeSeries = homeRaw?.results?.[0]?.series?.[0]?.values ?? [];
const tomorrow = new Date();
tomorrow.setDate(tomorrow.getDate() + 1);
const targetWeekday = tomorrow.getDay();

const sameWeekday = homeSeries
  .filter(([time, kwh]) => new Date(time).getDay() === targetWeekday && kwh > 1)
  .map(([, kwh]) => kwh);

const allDays = homeSeries
  .filter(([, kwh]) => kwh > 1)
  .map(([, kwh]) => kwh);

const homeValues = sameWeekday.length >= 2 ? sameWeekday : allDays;
const avg_consumption = homeValues.length > 0
  ? homeValues.reduce((a, b) => a + b, 0) / homeValues.length
  : 10;

const avgRounded = Math.round(avg_consumption * 10) / 10;
const avgPriceRounded = Math.round(avg_price * 10) / 10;
const minPriceRounded = Math.round(min_price * 10) / 10;
const maxPriceRounded = Math.round(max_price * 10) / 10;

const prompt = 'Ueberpruefe den Batterie-Preisschwellwert fuer den Rest des Tages und passe ihn bei Bedarf an.\n\n' +
  'Historische Tibber-Preise (' + priceSource + '):\n' +
  '- Durchschnitt: ' + avgPriceRounded + ' ct/kWh | Minimum: ' + minPriceRounded + ' ct/kWh | Maximum: ' + maxPriceRounded + ' ct/kWh\n\n' +
  'Erwarteter Tagesverbrauch: ' + avgRounded + ' kWh\n\n' +
  'Vorgehen:\n' +
  '1. Rufe getState auf: SoC, aktuelle PV-Leistung, Solar-Prognose rest heute und morgen\n' +
  '2. Rufe getTariffInfo mit type=grid auf: Tibber-Preise rest heute und morgen\n' +
  '3. Ladeentscheidung (charge_action):\n' +
  '   Verfuegbare Kapazitaet = (1 - SoC/100) * 7.6 kWh\n' +
  '   Restbedarf = verbleibender Tagesverbrauch - restliche Solar-Prognose heute - verfuegbare Kapazitaet\n' +
  '   - Wenn Restbedarf <= 0: charge_action = "remove"\n' +
  '   - Wenn Restbedarf > 0 und guenstige Slots verfuegbar: charge_action = "update" mit threshold_ct\n' +
  '   - Sonst: charge_action = "keep"\n' +
  '4. Einspeise-Entscheidung (discharge_action):\n' +
  '   Einspeise-Logik aktiv: ' + (einspeiseAktiv ? 'ja' : 'nein') + '\n' +
  '   Minimaler SoC fuer Einspeisen: ' + minSoc + '%\n' +
  '   Einspeiseverguetung: 6.7 ct/kWh (fix)\n' +
  '   - Wenn Einspeise-Logik aus: discharge_action = "disable"\n' +
  '   - Wenn an UND SoC > ' + minSoc + '% UND Solar+SoC deckt Restbedarf (Ueberschuss) UND aktueller Tibber-Preis > 6.7 ct: discharge_action = "enable"\n' +
  '   - Sonst: discharge_action = "disable"\n' +
  '5. Bei charge_action "update": setBatteryGridChargeLimit aufrufen (Wert in EUR/kWh)\n' +
  '6. Bei charge_action "remove": removeBatteryGridChargeLimit aufrufen\n' +
  '7. Bei discharge_action "enable": batterydischargecontrol wird von n8n gesetzt (kein MCP-Aufruf noetig)\n\n' +
  'Antworte IMMER mit validem JSON: { "charge_action": "keep", "threshold_ct": 0, "discharge_action": "disable", "reasoning": "<kurze deutsche Begruendung>" }';

return [{ json: {
  avg_consumption_kwh: avgRounded,
  avg_price_ct: avgPriceRounded,
  min_price_ct: minPriceRounded,
  max_price_ct: maxPriceRounded,
  price_source: priceSource,
  einspeise_aktiv: einspeiseAktiv,
  min_soc: minSoc,
  prompt
}}];
```

- [ ] **Step 6: "Ergebnis extrahieren" jsCode aktualisieren**

Regex von `"action"` auf `"charge_action"` umstellen, `discharge_action` parsen:

```javascript
const item = $input.first() ?? $input.item;
const data = item?.json ?? {};

const response = data.output
  ?? data.text
  ?? data.message
  ?? data.content
  ?? JSON.stringify(data);

let action = 'keep';
let threshold = 0;
let reasoning = 'Keine Begruendung';
let dischargeAction = 'disable';

// Letzten JSON-Block mit "charge_action" extrahieren
const allMatches = [...String(response).matchAll(/\{[^{}]*"charge_action"[^{}]*\}/g)];
const jsonMatch = allMatches.length > 0 ? allMatches[allMatches.length - 1][0] : null;
if (jsonMatch) {
  try {
    const parsed = JSON.parse(jsonMatch);
    action = parsed.charge_action ?? 'keep';
    threshold = parseFloat(parsed.threshold_ct ?? 0);
    reasoning = parsed.reasoning ?? reasoning;
    dischargeAction = parsed.discharge_action ?? 'disable';
  } catch(e) {}
}

// Fallback: charge_action direkt suchen
if (!['keep', 'update', 'remove'].includes(action)) {
  const actionMatch = String(response).match(/"charge_action"[^"]*"([^"]+)"/);
  if (actionMatch) action = actionMatch[1];
}

if (!['enable', 'disable'].includes(dischargeAction)) dischargeAction = 'disable';
if (isNaN(threshold)) threshold = 0;
threshold = Math.min(50, Math.max(0, threshold));

return [{ json: {
  action,
  charge_action: action,
  threshold_ct: threshold,
  discharge_action: dischargeAction,
  reasoning,
  timestamp: new Date().toISOString()
}}];
```

- [ ] **Step 7: "HA: Intraday Status aktualisieren" jsonBody aktualisieren**

`discharge_action` als Attribut ergänzen:

```
={{ { "state": $json.action, "attributes": { "threshold_ct": $json.threshold_ct, "unit_of_measurement": "ct/kWh", "friendly_name": "Batterie Intraday Anpassung", "reasoning": $json.reasoning, "discharge_action": $json.discharge_action, "last_updated": $json.timestamp } } }}
```

- [ ] **Step 8: Connections aktualisieren**

In `connections` folgende Änderungen vornehmen:

```json
"KI aktiv?": {
  "main": [
    [{ "node": "HA: Einspeise-Schalter lesen", "type": "main", "index": 0 }],
    []
  ]
},
"HA: Einspeise-Schalter lesen": {
  "main": [[{ "node": "HA: Min-SoC lesen", "type": "main", "index": 0 }]]
},
"HA: Min-SoC lesen": {
  "main": [[{ "node": "InfluxDB: Tibber Preisstats", "type": "main", "index": 0 }]]
},
"Ergebnis extrahieren": {
  "main": [[
    { "node": "HA: Intraday Status aktualisieren", "type": "main", "index": 0 },
    { "node": "Einspeisen aktivieren?", "type": "main", "index": 0 }
  ]]
},
"Einspeisen aktivieren?": {
  "main": [
    [{ "node": "evcc: Entladen aktivieren", "type": "main", "index": 0 }],
    [{ "node": "evcc: Entladen deaktivieren", "type": "main", "index": 0 }]
  ]
},
```

- [ ] **Step 9: Workflow in n8n importieren und testen**

1. JSON-Datei in n8n importieren (bestehenden Workflow ersetzen)
2. MCP `endpointUrl` manuell prüfen/setzen: `http://192.168.1.8:7070/mcp`
3. Credentials zuweisen (alle drei: Home Assistant Token, InfluxDB evcc, Anthropic)
4. Workflow manuell triggern
5. In Execution prüfen:
   - "HA: Einspeise-Schalter lesen" → `state: on/off`
   - "HA: Min-SoC lesen" → `state: 30`
   - "Kontext berechnen" → `einspeise_aktiv: true/false`, `min_soc: 30` im Output
   - "Ergebnis extrahieren" → `discharge_action: enable/disable` vorhanden
   - "Einspeisen aktivieren?" → korrekter Branch genommen
   - evcc-Node → HTTP 200

- [ ] **Step 10: Commit**

```bash
git add n8n-workflows/intraday-adjuster.json
git commit -m "Phase 5: Einspeise-Logik in Intraday Adjuster integriert"
```

---

### Task 3: Dashboard erweitern

**Files:**
- Modify: `ha-config/dashboards/battery-ai-dashboard.yaml`

- [ ] **Step 1: discharge_action Attribut zur Intraday-Karte hinzufügen**

In der "Intraday Anpassung" Entities-Karte nach dem `threshold_ct` Attribut einfügen:

```yaml
          # Intraday Anpassung
          - type: entities
            title: "Intraday Anpassung (stündlich)"
            entities:
              - entity: sensor.battery_intraday_adjustment
                name: "Letzte Aktion (Laden)"
                icon: mdi:refresh-auto
              - type: attribute
                entity: sensor.battery_intraday_adjustment
                attribute: threshold_ct
                name: "Schwellwert (ct/kWh)"
                icon: mdi:currency-eur
              - type: attribute
                entity: sensor.battery_intraday_adjustment
                attribute: discharge_action
                name: "Einspeisen"
                icon: mdi:transmission-tower-export
              - type: attribute
                entity: sensor.battery_intraday_adjustment
                attribute: reasoning
                name: "Begründung (Intraday)"
                icon: mdi:brain
              - type: attribute
                entity: sensor.battery_intraday_adjustment
                attribute: last_updated
                name: "Letzte Prüfung"
                icon: mdi:clock-outline
```

- [ ] **Step 2: Min-SoC Slider zur Steuerungskarte hinzufügen**

In der "Steuerung" Entities-Karte nach `einspeise_logik_aktiv` einfügen:

```yaml
          # Steuerung
          - type: entities
            title: "Steuerung"
            entities:
              - entity: input_boolean.ki_batteriesteuerung_aktiv
                name: "KI-Steuerung"
              - entity: input_boolean.einspeise_logik_aktiv
                name: "Einspeise-Logik"
              - entity: input_number.min_soc_einspeisen
                name: "Min. SoC Einspeisen"
              - entity: input_number.manueller_preisschwellwert
                name: "Manueller Schwellwert (0 = KI)"
```

- [ ] **Step 3: Dashboard in HA übernehmen und verifizieren**

Dashboard-YAML in HA laden (je nach Setup: Datei neu laden oder manuell in Lovelace Editor einfügen).

Verifizieren:
- Steuerungskarte zeigt Min-SoC Slider (Wert: 30%)
- Intraday-Karte zeigt "Einspeisen: enable/disable" nach nächstem Workflow-Lauf

- [ ] **Step 4: Commit**

```bash
git add ha-config/dashboards/battery-ai-dashboard.yaml
git commit -m "Phase 5: Dashboard – Min-SoC Slider und discharge_action Attribut"
```

---

### Task 4: README aktualisieren und pushen

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Phase 5 auf Live setzen**

In README.md Phase 5 Abschnitt aktualisieren:

```markdown
## Phase 5 – Einspeise-Logik ✅ Live

Batterie ins Netz entladen wenn Überschuss prognostiziert (Solar + SoC deckt Restbedarf) und Tibber-Preis > Einspeisevergütung. In Intraday Adjuster integriert.

- Claude entscheidet: `discharge_action = enable|disable`
- Neue HA Entity: `input_number.min_soc_einspeisen` (10–50%, default 30%)
- Dashboard: Slider für Min-SoC, Einspeise-Status in Intraday-Karte
```

- [ ] **Step 2: Commit und Push**

```bash
git add README.md
git commit -m "Docs: Phase 5 Einspeise-Logik als Live markiert"
git push
```

---

## Verifikation (End-to-End)

Nach Abschluss aller Tasks:

1. `einspeise_logik_aktiv` in HA auf **off** → Workflow triggern → `discharge_action: disable`, evcc: Entladen deaktivieren
2. `einspeise_logik_aktiv` auf **on**, SoC < 30% → `discharge_action: disable` (unter Min-SoC)
3. `einspeise_logik_aktiv` auf **on**, SoC > 30%, hoher Tibber-Preis, Solar-Überschuss → `discharge_action: enable`, evcc: Entladen aktivieren
4. `sensor.battery_intraday_adjustment` in HA zeigt `discharge_action` Attribut
