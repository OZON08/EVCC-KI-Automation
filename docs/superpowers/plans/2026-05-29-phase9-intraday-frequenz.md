# Phase 9 – Intraday Frequenz via HA konfigurierbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Ausführungshäufigkeit des Intraday Adjusters (aktuell fix stündlich) wird als `input_select` in Home Assistant konfigurierbar – wählbar zwischen 1h, 2h, 3h und 6h.

**Architecture:** Der Cron-Trigger bleibt auf `0 6-22 * * *` (stündlich). Zwei neue Nodes am Anfang des Workflows lesen den HA-Wert und beenden den Lauf per `return []` wenn die aktuelle Stunde nicht dem konfigurierten Intervall entspricht. Dadurch entstehen keine Claude-API-Kosten bei übersprungenen Läufen.

**Tech Stack:** n8n JSON workflow, Home Assistant YAML config (input_select), n8n Code-Node `return []` als Early-Exit

---

## Dateiübersicht

| Datei | Änderung |
|-------|----------|
| `ha-config/input_selects.yaml` | NEU – `input_select.intraday_frequenz` |
| `n8n-workflows/intraday-adjuster.json` | 2 neue Nodes + Connection-Update |
| `ha-config/dashboards/battery-ai-dashboard.yaml` | Dropdown in Steuerungskarte |
| `README.md` | Phase 9 dokumentieren |

---

### Task 1: HA Entity `input_select.intraday_frequenz` anlegen

**Files:**
- Create: `ha-config/input_selects.yaml`

- [ ] **Step 1: Datei `ha-config/input_selects.yaml` erstellen**

```yaml
input_select:
  intraday_frequenz:
    name: "Intraday Häufigkeit"
    icon: mdi:timer-outline
    options:
      - "1h"
      - "2h"
      - "3h"
      - "6h"
    initial: "1h"
```

- [ ] **Step 2: In Home Assistant anlegen**

Option A (wenn `input_selects.yaml` per `!include` in `configuration.yaml` eingebunden ist):
```
HA → Einstellungen → System → YAML neu laden → Eingabe: Auswahllisten
```

Option B (manuell als Helfer anlegen):
```
HA → Einstellungen → Helfer → + Helfer erstellen → Auswahl
Name: "Intraday Häufigkeit"
Entity-ID: input_select.intraday_frequenz
Optionen: 1h, 2h, 3h, 6h
```

Verifizieren: `input_select.intraday_frequenz` in HA Entitäten-Liste mit Wert `1h`.

- [ ] **Step 3: Commit**

```bash
git add ha-config/input_selects.yaml
git commit -m "Phase 9: Add input_select.intraday_frequenz HA entity"
```

---

### Task 2: `intraday-adjuster.json` – Frequenzprüfung einbauen

**Files:**
- Modify: `n8n-workflows/intraday-adjuster.json`

Die Logik: Cron läuft stündlich. Nach dem KI-aktiv-Check wird die konfigurierte Frequenz aus HA gelesen. Ein Code-Node prüft ob `(aktuelle_stunde - 6) % frequenz == 0`. Bei false → `return []` stoppt den Workflow ohne Claude-Aufruf.

Beispiel für `frequenz=2`:
- 6 Uhr: (6-6)%2=0 → läuft ✅
- 7 Uhr: (7-6)%2=1 → überspringen ❌
- 8 Uhr: (8-6)%2=0 → läuft ✅

- [ ] **Step 1: Neuen Node `HA: Frequenz lesen` in `nodes` Array einfügen**

Nach dem letzten Node in der `nodes` Array (vor der schließenden `]`) einfügen:

```json
{
  "parameters": {
    "url": "http://homeassistant:8123/api/states/input_select.intraday_frequenz",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "id": "ha-frequenz-lesen",
  "name": "HA: Frequenz lesen",
  "type": "n8n-nodes-base.httpRequest",
  "position": [448, 0],
  "typeVersion": 4.4,
  "credentials": {
    "httpHeaderAuth": {
      "id": "HOwzYx39oHRQSvbp",
      "name": "Home Assistant Token"
    }
  }
},
```

- [ ] **Step 2: Neuen Node `Frequenz prüfen` in `nodes` Array einfügen**

Direkt dahinter einfügen:

```json
{
  "parameters": {
    "jsCode": "const state = $input.first()?.json?.state ?? '1h';\nconst freq = parseInt(state) || 1;\nconst currentHour = new Date().getHours();\nconst shouldRun = (currentHour - 6) % freq === 0;\nif (!shouldRun) return [];\nreturn [{ json: { frequency_h: freq } }];"
  },
  "id": "frequenz-pruefen",
  "name": "Frequenz prüfen",
  "type": "n8n-nodes-base.code",
  "position": [560, 0],
  "typeVersion": 2,
  "notes": "return [] stoppt den Workflow ohne Claude-API-Aufruf wenn nicht im konfigurierten Intervall."
},
```

- [ ] **Step 3: Connections aktualisieren**

Im `connections` Objekt drei Änderungen:

**Vorher:**
```json
"KI aktiv?": {
  "main": [
    [{ "node": "HA: Einspeise-Schalter lesen", "type": "main", "index": 0 }],
    []
  ]
}
```

**Nachher:**
```json
"KI aktiv?": {
  "main": [
    [{ "node": "HA: Frequenz lesen", "type": "main", "index": 0 }],
    []
  ]
},
"HA: Frequenz lesen": {
  "main": [[{ "node": "Frequenz prüfen", "type": "main", "index": 0 }]]
},
"Frequenz prüfen": {
  "main": [[{ "node": "HA: Einspeise-Schalter lesen", "type": "main", "index": 0 }]]
},
```

- [ ] **Step 4: Workflow in n8n importieren und testen**

1. JSON-Datei in n8n importieren (bestehenden Workflow ersetzen)
2. MCP `endpointUrl` prüfen: `http://192.168.1.8:7070/mcp`
3. Credentials zuweisen (Home Assistant Token, InfluxDB evcc, Anthropic)
4. `input_select.intraday_frequenz` in HA auf `2h` setzen
5. Workflow manuell triggern:
   - Bei gerader Stunde (6, 8, 10, ...): Workflow läuft durch → Claude wird aufgerufen
   - Bei ungerader Stunde (7, 9, 11, ...): `Frequenz prüfen` gibt `[]` zurück → Workflow endet nach diesem Node, kein Claude-Aufruf
6. `input_select.intraday_frequenz` zurück auf `1h` setzen

Verifizieren: In n8n Execution-Log sichtbar ob Workflow nach `Frequenz prüfen` stoppt.

- [ ] **Step 5: Commit**

```bash
git add n8n-workflows/intraday-adjuster.json
git commit -m "Phase 9: Intraday frequency skip logic via HA input_select"
```

---

### Task 3: Dashboard + README + Push

**Files:**
- Modify: `ha-config/dashboards/battery-ai-dashboard.yaml`
- Modify: `README.md`

- [ ] **Step 1: `intraday_frequenz` Dropdown zur Steuerungskarte hinzufügen**

In `battery-ai-dashboard.yaml` die Steuerungskarte erweitern. Aktueller Stand nach Phase 5:

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

Ersetzen durch:

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
              - entity: input_select.intraday_frequenz
                name: "Intraday Häufigkeit"
              - entity: input_number.manueller_preisschwellwert
                name: "Manueller Schwellwert (0 = KI)"
```

- [ ] **Step 2: README – Phase 9 ergänzen und HA Entities Tabelle aktualisieren**

In `README.md` die HA Entities Tabelle erweitern:

```markdown
| `input_select.intraday_frequenz` | Auswahl | Intraday-Häufigkeit: 1h / 2h / 3h / 6h (default 1h) |
```

Nach Phase 8 einen neuen Abschnitt einfügen:

```markdown
## Phase 9 – Intraday Frequenz konfigurierbar ✅ Live

Häufigkeit des Intraday Adjusters über HA-Dropdown einstellbar (1h / 2h / 3h / 6h).

- Cron-Trigger bleibt stündlich – Skip-Logik im Workflow verhindert Claude-Aufruf wenn nicht im Intervall
- Keine API-Kosten für übersprungene Läufe
- Bei 2h: ~$5–6/Monat statt ~$10–11/Monat

| Frequenz | Läufe/Tag | Läufe/Monat | ~Kosten/Monat |
|----------|-----------|-------------|---------------|
| 1h (default) | 17 | 510 | ~$11 |
| 2h | 9 | 270 | ~$6 |
| 3h | 6 | 180 | ~$4 |
| 6h | 3 | 90 | ~$2 |
```

- [ ] **Step 3: Commit und Push**

```bash
git add ha-config/dashboards/battery-ai-dashboard.yaml README.md
git commit -m "Phase 9: Dashboard + README – Intraday Frequenz"
git push
```

---

## Verifikation (End-to-End)

1. HA: `input_select.intraday_frequenz` auf `2h` setzen
2. n8n: Workflow manuell triggern bei ungerader Stunde (z.B. 7:xx Uhr) → Execution stoppt nach `Frequenz prüfen`, kein Claude-Aufruf in Log
3. n8n: Workflow manuell triggern bei gerader Stunde (z.B. 8:xx Uhr) → Execution läuft vollständig durch
4. HA: Wert zurück auf `1h` → jeder stündliche Lauf läuft durch wie bisher
