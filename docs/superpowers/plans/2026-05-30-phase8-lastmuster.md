# Phase 8 – Stündliche Lastmustererkennung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stündliches Verbrauchsprofil (gleicher Wochentag, 28d) aus InfluxDB lesen und als Kontext an Claude übergeben — Daily Optimizer bekommt das volle 24h-Profil, Intraday Adjuster nur die nächsten 6 Stunden.

**Architecture:** In beide Workflows wird je ein neuer InfluxDB-Node `InfluxDB: Lastprofil abfragen` eingefügt (sequentiell, kein Fan-In). Der nachfolgende Code-Node (`Verbrauch berechnen` bzw. `Kontext berechnen`) liest die täglichen Verbrauchsdaten fortan per Named Reference und bekommt das Stundenprofil über `$input`. Der Prompt wird um einen Lastprofil-Abschnitt erweitert.

**Tech Stack:** n8n JSON workflow (Code-Node, HTTP Request), InfluxDB 1.x Query API

---

## Dateiübersicht

| Datei | Änderung |
|-------|----------|
| `n8n-workflows/daily-optimizer.json` | 1 neuer Node + `Verbrauch berechnen` aktualisiert + Connection |
| `n8n-workflows/intraday-adjuster.json` | 1 neuer Node + `Kontext berechnen` aktualisiert + Connection |
| `README.md` | Phase 8 auf Live setzen |

---

## Wichtige Hintergrundinformationen

### n8n parallele Inputs crashen Code-Nodes
Der neue InfluxDB-Node wird **sequentiell** eingeschoben — kein Fan-In. Das bedeutet die bestehende Verbindung `InfluxDB: Verbrauch abfragen` → `[Code-Node]` wird gebrochen und ersetzt durch:
```
InfluxDB: Verbrauch abfragen → InfluxDB: Lastprofil abfragen → [Code-Node]
```
Der Code-Node liest dann:
- `$input.first()` = Output von `InfluxDB: Lastprofil abfragen` (Stundenprofil)
- `$('InfluxDB: Verbrauch abfragen').first()` = Tagesdaten (Named Reference)

### InfluxDB Query für Stundenprofil
```sql
SELECT integral("value") / 3600000 FROM "homePower"
WHERE time > now() - 28d
GROUP BY time(1h) fill(0)
```
Liefert stündliche kWh-Werte der letzten 28 Tage (alle Wochentage). Filterung auf gleichen Wochentag + Aggregation nach Tagesstunde erfolgt im Code-Node.

### Timezone-Offset (dynamisch, CET/CEST-kompatibel)
```javascript
const offsetHours = -new Date().getTimezoneOffset() / 60;
// CET = +1, CEST = +2 → korrekt automatisch
```

### Credential IDs
- InfluxDB evcc: `"id": "r61FJRKq9t50s9A7"`

---

### Task 1: `daily-optimizer.json` – Lastprofil

**Files:**
- Modify: `n8n-workflows/daily-optimizer.json`

**Aktuelle Verbindung:**
```
InfluxDB: Verbrauch abfragen [672,0] → Verbrauch berechnen [896,0]
```

**Ziel:**
```
InfluxDB: Verbrauch abfragen [672,0] → InfluxDB: Lastprofil abfragen [784,80] → Verbrauch berechnen [896,0]
```

- [ ] **Step 1: Neuen Node `InfluxDB: Lastprofil abfragen` in `nodes` Array einfügen**

Nach dem Node `InfluxDB: Verbrauch abfragen` (id: `cc558740-3d4a-4b46-93e7-3e570bf5b5e7`) einfügen:

```json
{
  "parameters": {
    "url": "http://a0d7b954-influxdb:8086/query",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendQuery": true,
    "queryParameters": {
      "parameters": [
        { "name": "db", "value": "evcc" },
        { "name": "q", "value": "SELECT integral(\"value\") / 3600000 FROM \"homePower\" WHERE time > now() - 28d GROUP BY time(1h) fill(0)" }
      ]
    },
    "options": {}
  },
  "id": "influxdb-lastprofil-daily",
  "name": "InfluxDB: Lastprofil abfragen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [784, 80],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
```

- [ ] **Step 2: Connections aktualisieren**

Im `connections` Objekt:

**Vorher:**
```json
"InfluxDB: Verbrauch abfragen": {
  "main": [[{ "node": "Verbrauch berechnen", "type": "main", "index": 0 }]]
}
```

**Nachher:**
```json
"InfluxDB: Verbrauch abfragen": {
  "main": [[{ "node": "InfluxDB: Lastprofil abfragen", "type": "main", "index": 0 }]]
},
"InfluxDB: Lastprofil abfragen": {
  "main": [[{ "node": "Verbrauch berechnen", "type": "main", "index": 0 }]]
},
```

- [ ] **Step 3: `Verbrauch berechnen` jsCode ersetzen**

Den bestehenden jsCode des Nodes `Verbrauch berechnen` (id: `33f8f8af-40ea-43c2-aaf0-d5b5affae010`) vollständig durch folgenden JavaScript-Code ersetzen (für JSON korrekt escapen: `"` → `\"`, Newlines → `\n`):

```javascript
const data = $('InfluxDB: Verbrauch abfragen').first()?.json ?? {};
const profileRaw = $input.first()?.json ?? {};
const series = data?.results?.[0]?.series?.[0]?.values ?? [];

// Morgen's Wochentag (0=So, 1=Mo, ..., 6=Sa)
const tomorrow = new Date();
tomorrow.setDate(tomorrow.getDate() + 1);
const targetWeekday = tomorrow.getDay();

// Gleicher Wochentag, Werte > 1 kWh (vollständige Tage)
const sameWeekday = series
  .filter(([time, kwh]) => new Date(time).getDay() === targetWeekday && kwh > 1)
  .map(([, kwh]) => kwh);

// Fallback: alle Tage mit Daten
const allDays = series
  .filter(([, kwh]) => kwh > 1)
  .map(([, kwh]) => kwh);

const values = sameWeekday.length >= 2 ? sameWeekday : allDays;
const avg = values.length > 0
  ? values.reduce((a, b) => a + b, 0) / values.length
  : 10;

const source = sameWeekday.length >= 2
  ? 'gleicher Wochentag'
  : allDays.length > 0
    ? 'Gesamtdurchschnitt'
    : 'Fallback';

const avgRounded = Math.round(avg * 10) / 10;
const dataDays = sameWeekday.length || allDays.length;

// Lastprofil berechnen (gleicher Wochentag wie morgen, 28d)
const profileSeries = profileRaw?.results?.[0]?.series?.[0]?.values ?? [];
const offsetHours = -new Date().getTimezoneOffset() / 60;
const byHour = {};
for (let h = 0; h < 24; h++) byHour[h] = [];

profileSeries
  .filter(([time]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    return local.getDay() === targetWeekday;
  })
  .forEach(([time, kwh]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    const hour = local.getHours();
    if (kwh !== null && kwh > 0) byHour[hour].push(kwh);
  });

const profile = [];
for (let h = 0; h < 24; h++) {
  const vals = byHour[h];
  profile.push({
    hour: h,
    avg_kwh: vals.length > 0 ? Math.round(vals.reduce((a, b) => a + b, 0) / vals.length * 100) / 100 : 0,
    samples: vals.length
  });
}

const profileDays = Math.max(...profile.map(p => p.samples), 0);
const hasProfile = profileDays >= 4;

const profileSection = hasProfile
  ? '\n\nStündliches Verbrauchsprofil (gleicher Wochentag, ' + profileDays + ' Messtage, 28d-Durchschnitt):\n' +
    profile.map(p => p.hour.toString().padStart(2, '0') + ':00: ' + p.avg_kwh + ' kWh').join(' | ') +
    '\n\nBerechne pro Stunde den Netto-Bedarf (Verbrauch minus PV-Prognose). Stunden mit Netto-Bedarf > 0 brauchen Batterie-Reserve. Plane die Ladestrategie so dass der SoC zu Lastspitzen ausreicht.'
  : '';

const prompt = 'Analysiere den aktuellen Zustand der Hausbatterie und optimiere die Ladekosten fuer morgen.\n\nVorgehen:\n1. Rufe getState auf um SoC, Solar-Prognose und aktuelle Situation zu sehen\n2. Rufe getTariffInfo mit type=grid auf um die Tibber-Preise fuer morgen zu sehen\n3. Berechne den optimalen Preisschwellwert:\n   - Verfuegbare Kapazitaet = (1 - SoC/100) * 7.6 kWh\n   - Energiebedarf = ' + avgRounded + ' kWh (Verbrauchsdaten: ' + source + ', ' + dataDays + ' Messtage) - Solar-Prognose morgen - verfuegbare Kapazitaet\n   - Wenn Bedarf <= 0: Schwellwert = 0 (kein Netzladen noetig, Solar reicht)\n   - Wenn Bedarf > 0: Guenstigste Preis-Slots fuer morgen waehlen bis Bedarf gedeckt, Schwellwert = hoechster gewaehlter Preis * 1.05\n4. Setze den Schwellwert mit setBatteryGridChargeLimit (Wert in EUR/kWh, also ct/100)\n   - Beispiel: 8.5 ct/kWh = 0.085 EUR/kWh\n   - Wenn Schwellwert = 0: removeBatteryGridChargeLimit aufrufen\n5. Antworte mit einer kurzen deutschen Zusammenfassung:\n   { "threshold_ct": <Zahl>, "reasoning": "<Begruendung>" }' + profileSection;

return [{ json: {
  avg_consumption_kwh: avgRounded,
  data_days: dataDays,
  source,
  prompt
}}];
```

- [ ] **Step 4: JSON validieren**

```bash
cd "C:\Users\karst\Documents\Repos\EVCC-KI-Automation"
python -c "import json; json.load(open('n8n-workflows/daily-optimizer.json')); print('JSON valid')"
```
Erwartete Ausgabe: `JSON valid`

- [ ] **Step 5: Commit**

```bash
git add n8n-workflows/daily-optimizer.json
git commit -m "Phase 8: Lastprofil in Daily Optimizer"
```

---

### Task 2: `intraday-adjuster.json` – Lastprofil (nächste 6h)

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

**Aktuelle Verbindung:**
```
InfluxDB: Verbrauch abfragen [1120,-160] → Kontext berechnen [1344,-160]
```

**Ziel:**
```
InfluxDB: Verbrauch abfragen [1120,-160] → InfluxDB: Lastprofil abfragen [1232,-160] → Kontext berechnen [1344,-160]
```

- [ ] **Step 1: Neuen Node `InfluxDB: Lastprofil abfragen` in `nodes` Array einfügen**

Nach dem Node `InfluxDB: Verbrauch abfragen` (id: `e5f6a7b8-c9d0-1234-ef01-345678901234`) einfügen:

```json
{
  "parameters": {
    "url": "http://a0d7b954-influxdb:8086/query",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpBasicAuth",
    "sendQuery": true,
    "queryParameters": {
      "parameters": [
        { "name": "db", "value": "evcc" },
        { "name": "q", "value": "SELECT integral(\"value\") / 3600000 FROM \"homePower\" WHERE time > now() - 28d GROUP BY time(1h) fill(0)" }
      ]
    },
    "options": {}
  },
  "id": "influxdb-lastprofil-intraday",
  "name": "InfluxDB: Lastprofil abfragen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [1232, -160],
  "typeVersion": 4.4,
  "credentials": {
    "httpBasicAuth": {
      "id": "r61FJRKq9t50s9A7",
      "name": "InfluxDB evcc"
    }
  }
},
```

- [ ] **Step 2: Connections aktualisieren**

Im `connections` Objekt:

**Vorher:**
```json
"InfluxDB: Verbrauch abfragen": {
  "main": [[{ "node": "Kontext berechnen", "type": "main", "index": 0 }]]
}
```

**Nachher:**
```json
"InfluxDB: Verbrauch abfragen": {
  "main": [[{ "node": "InfluxDB: Lastprofil abfragen", "type": "main", "index": 0 }]]
},
"InfluxDB: Lastprofil abfragen": {
  "main": [[{ "node": "Kontext berechnen", "type": "main", "index": 0 }]]
},
```

- [ ] **Step 3: `Kontext berechnen` jsCode anpassen**

Im jsCode des Nodes `Kontext berechnen` (id: `f6a7b8c9-d0e1-2345-f012-456789012345`) folgende **drei Änderungen** vornehmen:

**Änderung A** — Zeile 2 des jsCode (homeRaw):
```javascript
// ALT:
const homeRaw = $input.first()?.json ?? {};
// NEU:
const homeRaw = $('InfluxDB: Verbrauch abfragen').first()?.json ?? {};
```

**Änderung B** — Direkt nach der neuen homeRaw-Zeile einfügen:
```javascript
const profileRaw = $input.first()?.json ?? {};
```

**Änderung C** — Direkt vor `const prompt = ...` einfügen:
```javascript
// Lastprofil nächste 6 Stunden berechnen
const profileSeries = profileRaw?.results?.[0]?.series?.[0]?.values ?? [];
const offsetHours = -new Date().getTimezoneOffset() / 60;
const currentHour = new Date().getHours();
const weekday = new Date().getDay();
const byHour = {};
for (let h = 0; h < 24; h++) byHour[h] = [];

profileSeries
  .filter(([time]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    return local.getDay() === weekday;
  })
  .forEach(([time, kwh]) => {
    const local = new Date(new Date(time).getTime() + offsetHours * 3600000);
    const hour = local.getHours();
    if (kwh !== null && kwh > 0) byHour[hour].push(kwh);
  });

const next6Hours = [];
for (let i = 0; i < 6; i++) {
  const h = (currentHour + i) % 24;
  const vals = byHour[h];
  next6Hours.push({
    hour: h,
    avg_kwh: vals.length > 0 ? Math.round(vals.reduce((a, b) => a + b, 0) / vals.length * 100) / 100 : 0,
    samples: vals.length
  });
}

const profileDays = Math.max(...next6Hours.map(p => p.samples), 0);
const profileSection = profileDays >= 4
  ? '\n\nStündliches Verbrauchsprofil (nächste 6h, gleicher Wochentag, ' + profileDays + ' Messtage):\n' +
    next6Hours.map(p => p.hour.toString().padStart(2, '0') + ':00: ' + p.avg_kwh + ' kWh').join(' | ') +
    '\n\nStunden mit hohem Verbrauch: SoC-Reserve einplanen.'
  : '';
```

**Änderung D** — Am Ende des prompt-Strings (vor dem schließenden `'`) `+ profileSection` anhängen:
```javascript
// Das letzte ' des prompt-Strings:
'Antworte IMMER mit validem JSON: ...' + profileSection;
```

- [ ] **Step 4: JSON validieren**

```bash
cd "C:\Users\karst\Documents\Repos\EVCC-KI-Automation"
python -c "import json; json.load(open('n8n-workflows/intraday-adjuster.json')); print('JSON valid')"
```
Erwartete Ausgabe: `JSON valid`

- [ ] **Step 5: Commit**

```bash
git add n8n-workflows/intraday-adjuster.json
git commit -m "Phase 8: Lastprofil in Intraday Adjuster (nächste 6h)"
```

---

### Task 3: README + Push

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Phase 8 Abschnitt auf Live setzen**

Den bestehenden Phase-8-Abschnitt (von `## Phase 8` bis zur Leerzeile vor `## Phase 9`) ersetzen durch:

```markdown
## Phase 8 – Stündliche Lastmustererkennung ✅ Live

Wiederkehrende Verbrauchsspitzen (z.B. Wärmepumpe 7–9 Uhr) aus InfluxDB erkannt und Claude als stündliches Lastprofil übergeben.

- `homePower GROUP BY time(1h)` der letzten 28 Tage → Ø-Verbrauch pro Stunde (gleicher Wochentag)
- Daily Optimizer: vollständiges 24h-Profil für morgen
- Intraday Adjuster: nur nächste 6 Stunden (Prompt-Effizienz)
- Timezone-Offset dynamisch via `getTimezoneOffset()` (CET/CEST automatisch)
- Fallback: wenn < 4 Messtage vorhanden → Profil-Abschnitt wird weggelassen
```

- [ ] **Step 2: Commit und Push**

```bash
git add README.md
git commit -m "Phase 8: README aktualisiert"
git push
```

---

## Verifikation (End-to-End)

1. **Daily Optimizer** manuell triggern → `Verbrauch berechnen` Output prüfen: enthält `prompt` mit "Stündliches Verbrauchsprofil" Abschnitt
2. **Intraday Adjuster** manuell triggern → `Kontext berechnen` Output prüfen: enthält "nächste 6h" Profil
3. Falls Profil fehlt (< 4 Messtage oder `homePower` leer): `profileSection = ''` → Workflow läuft trotzdem durch
4. Claude-Reasoning prüfen: erwähnt stündliche Lastspitzen oder plant SoC-Reserve
