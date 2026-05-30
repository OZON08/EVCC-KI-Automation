# EVCC KI-Automation – Intelligente Hausbatteriesteuerung

KI-gesteuertes System zur kostenoptimierten Ladung und Entladung der Hausbatterie (RCT Power), basierend auf dynamischen Tibber-Strompreisen, Solar-Prognosen und gemessenen Verbrauchsdaten aus InfluxDB.

## Wie es funktioniert

Täglich um 14:00 Uhr (sobald Tibber die Preise für den nächsten Tag veröffentlicht) läuft der Daily Optimizer in n8n:

1. Prüft ob KI-Steuerung in Home Assistant aktiv ist
2. Liest den **gemessenen Durchschnittsverbrauch** für den gleichen Wochentag aus InfluxDB (28 Tage, `homePower`)
3. **Claude Sonnet** liest via evcc MCP: aktuellen SoC, Tibber-Preise (next 24h, 15-min-Raster), Solar-Prognose morgen
4. Claude berechnet den optimalen Preisschwellwert und setzt ihn direkt in evcc
5. evcc lädt die Batterie automatisch wann immer der Tibber-Preis unter dem Schwellwert liegt
6. n8n schreibt Ergebnis + Begründung nach Home Assistant

Zusätzlich laufen:
- **Intraday Adjuster** (stündlich 6–22 Uhr): passt Schwellwert tagsüber nach und entscheidet ob Batterie ins Netz einspeist
- **Safety Monitor** (alle 15 min): überwacht SoC-Grenzen, deaktiviert Netzladen/Entladen bei Bedarf
- **HA Override Handler**: reagiert sofort auf HA-Schalter-Änderungen via Webhook

## Stack

| Komponente | Rolle | Adresse |
|------------|-------|---------|
| **n8n** | Orchestrator (läuft als HA-Addon) | `http://homeassistant:8081` (intern) |
| **Claude Sonnet** (`claude-sonnet-4-6`) | KI-Entscheidungsmotor via n8n AI Agent | Anthropic API |
| **evcc** | Batteriesteuerung via REST API + MCP | `http://192.168.1.8:7070` |
| **evcc MCP** | Tool-Interface für Claude (experimental) | `http://192.168.1.8:7070/mcp` |
| **RCT Power** | Hausbatterie (7,6 kWh, ~7 kW) | via evcc |
| **Tibber** | Dynamische Strompreise (15-min-Raster) | via evcc `forecast.grid` |
| **InfluxDB** | Verbrauchshistorie | `http://a0d7b954-influxdb:8086/` db=`evcc` |
| **Home Assistant** | Dashboard, Schalter, Overrides | `http://homeassistant:8123` (intern) |

## Status

| Workflow | Status | Trigger |
|----------|--------|---------|
| Daily Optimizer | ✅ Live | täglich 14:00 + sofort bei KI-Aktivierung |
| Safety Monitor | ✅ Live | alle 15 Minuten |
| HA Override Handler | ✅ Live | Webhook von HA-Schaltern |
| Intraday Adjuster | ✅ Live | stündlich 6–22 Uhr (17×/Tag) |

## Projektstruktur

```
├── docs/
│   ├── setup-phase1.md              # Setup-Anleitung Phase 1
│   └── superpowers/specs/
│       └── 2026-05-25-battery-ai-design.md  # Design-Spec
├── n8n-workflows/
│   ├── daily-optimizer.json         # Claude + evcc MCP + InfluxDB, täglich 14:00
│   ├── safety-monitor.json          # Regelbasiert, alle 15 min
│   ├── ha-override-handler.json     # Webhook-Handler, Sofortreaktion auf HA-Schalter
│   └── intraday-adjuster.json       # Claude + evcc MCP + Preisstats, stündlich 6–22 Uhr
├── ha-config/
│   ├── input_booleans.yaml          # KI-Schalter, Einspeise-Schalter
│   ├── input_numbers.yaml           # Manueller Schwellwert, Min-SoC Einspeisen
│   ├── rest_commands.yaml           # n8n Webhook-Aufruf von HA
│   ├── automations/
│   │   └── battery-ai-webhooks.yaml # Schalter → n8n Webhooks
│   └── dashboards/
│       └── battery-ai-dashboard.yaml
└── scripts/
    └── test-evcc-api.sh             # API-Test
```

## Home Assistant Entities

| Entity | Typ | Funktion |
|--------|-----|----------|
| `input_boolean.ki_batteriesteuerung_aktiv` | Schalter | KI-Steuerung an/aus |
| `input_boolean.einspeise_logik_aktiv` | Schalter | Einspeise-Logik (optional) |
| `input_number.manueller_preisschwellwert` | Zahl | Override (0 = KI übernimmt) |
| `input_number.min_soc_einspeisen` | Zahl | Minimaler SoC für Einspeisen (10–50%, default 30%) |
| `input_select.intraday_frequenz` | Auswahl | Intraday-Häufigkeit: 1h / 2h / 3h / 6h (default 1h) |
| `sensor.battery_charge_threshold` | Sensor | Aktueller Schwellwert + Claude-Begründung (Daily) |
| `sensor.battery_intraday_adjustment` | Sensor | Intraday-Aktion + Einspeise-Status + Begründung |
| `sensor.battery_ai_tokens_last_run` | Sensor | Kosten + Tokens letzter Claude-Aufruf |
| `sensor.battery_ai_cost_today` | Sensor | API-Kosten heute kumuliert (USD) |
| `sensor.battery_ai_cost_month` | Sensor | API-Kosten Monat kumuliert (USD) |
| `sensor.battery_ai_savings_today` | Sensor | KI-Ersparnis heute vs. Tagesdurchschnitt (EUR) |
| `sensor.battery_ai_savings_month` | Sensor | KI-Ersparnis kumuliert Monat (EUR) |

## Setup-Notizen

### n8n Credentials
| Name | Typ | Werte |
|------|-----|-------|
| `Home Assistant Token` | HTTP Header Auth | `Authorization: Bearer <HA_TOKEN>` |
| `Anthropic – Claude Sonnet` | Anthropic API | API Key aus console.anthropic.com |
| `InfluxDB evcc` | HTTP Basic Auth | User: `evcc`, Password: siehe HA-Addon-Config |

### Wichtige Erkenntnisse
- **evcc API**: offen ohne Auth im lokalen Netz
- **evcc Tibber-Preise**: in `forecast.grid[]` (Wert in EUR → ×100 = ct), nicht `tariffGrid`
- **evcc Solar-Prognose**: `forecast.solar.tomorrow.energy` (in Wh → ÷1000 = kWh)
- **n8n als HA-Addon**: `.local` DNS nicht auflösbar im Container → `http://homeassistant:8123` für HA, `http://192.168.1.8:7070` für evcc
- **n8n MCP Node**: `endpointUrl` Parameter wird beim JSON-Import nicht gesetzt → muss manuell eingetragen werden
- **n8n Code-Node mit parallelen Inputs**: crasht mit `.item` → sequentiellen Flow und `.first()` verwenden
- **n8n Template-Literals im Agent-Node**: `${variable}` wird nicht aufgelöst → Prompt im Code-Node per String-Konkatenation bauen, als `$json.prompt` übergeben
- **n8n Regex für Claude-Antwort**: `[^{}]*` statt `[\s\S]*?` verwenden, sonst brechen `}` in Markdown die Extraktion
- **HA → n8n Webhook**: `rest_command` URL = `http://homeassistant:8081/webhook/...` (n8n Addon intern); nach Änderung **HA-Neustart** nötig (kein YAML-Reload)
- **n8n Execute Workflow**: Ziel-Workflow braucht `executeWorkflowTrigger` Node, sonst Fehler "Missing node to start execution"

## Daily Optimizer – Entscheidungslogik

```
Verfügbare Kapazität = (1 - SoC/100) × 7,6 kWh
Energiebedarf = InfluxDB-Verbrauch (gleicher Wochentag, 28 Tage) - Solar morgen - verfügbare Kapazität

Wenn Bedarf ≤ 0:  Schwellwert = 0  → removeBatteryGridChargeLimit
Wenn Bedarf > 0:  günstigste Tibber-Slots wählen bis Bedarf gedeckt
                  Schwellwert = höchster gewählter Slot × 1,05
```

Claude setzt den Schwellwert direkt via `setBatteryGridChargeLimit` (Wert in EUR/kWh).

## HA Override Handler – Events

| HA-Schalter | Event | Aktion in n8n |
|-------------|-------|----------------|
| `ki_batteriesteuerung_aktiv` → off | `ai_control_disabled` | evcc: Netzladen sofort deaktivieren |
| `ki_batteriesteuerung_aktiv` → on | `ai_control_enabled` | Daily Optimizer sofort ausführen |
| `einspeise_logik_aktiv` → on | `discharge_enabled` | evcc: Entladen aktivieren |
| `einspeise_logik_aktiv` → off | `discharge_disabled` | evcc: Entladen deaktivieren |

## Phase 4 – Intraday Adaptive Optimization

Stündlich prüft der Intraday Adjuster ob PV-Prognose oder SoC vom Tagesplan abweichen und passt den Preisschwellwert nach.

**Workflow:** `intraday-adjuster.json` – Trigger: `0 6-22 * * *` (stündlich 6–22 Uhr, 17×/Tag)

**Flow:**
1. HA KI-Schalter prüfen (abort wenn off)
2. InfluxDB: historische `tariffGrid`-Statistik (90 Tage, ct/kWh) → Min/Avg/Max für heutigen Wochentag
3. InfluxDB: `homePower` 28-Tage-Durchschnitt → erwarteter Tagesverbrauch
4. Claude Sonnet liest via evcc MCP: SoC, PV-Ist + Prognose, Tibber-Preise rest heute/morgen
5. Claude entscheidet Laden: `keep` / `update` (setBatteryGridChargeLimit) / `remove` (removeBatteryGridChargeLimit)
6. Claude entscheidet Entladen (Phase 5): `discharge_action = enable|disable`
7. n8n setzt batterydischargecontrol, Ergebnis → `sensor.battery_intraday_adjustment` in HA

**Setup:** In n8n importieren, Credentials zuweisen (Home Assistant Token, InfluxDB evcc, Anthropic), MCP endpointUrl manuell eintragen, aktivieren.

**HA Entity:**

| Entity | Inhalt |
|--------|--------|
| `sensor.battery_intraday_adjustment` | state: keep/update/remove, Attribute: threshold_ct, discharge_action, reasoning, last_updated |

## API-Kosten (Anthropic)

Claude Sonnet 4.6: $3 / 1M Input-Tokens, $15 / 1M Output-Tokens

Pro Lauf ca. 5.000 Input- + 450 Output-Tokens (System-Prompt + MCP-Responses + Phase 5 Einspeise-Kontext).

| Workflow | Läufe/Monat | Input-Token/Lauf | ~Kosten/Monat |
|----------|-------------|-----------------|---------------|
| Intraday Adjuster (17×/Tag) | 510 | ~5.000 | ~$10 |
| Daily Optimizer (1×/Tag) | 30 | ~4.500 | ~$0,60 |
| **Gesamt** | | | **~$10–11** |

**Sparpotenzial:**
- Intraday-Trigger auf alle 2h reduzieren (`0 6-22/2 * * *`) → ~$5–6/Monat
- Günstigeres Modell: im Agent-Node Anthropic durch OpenAI ersetzen, Rest bleibt gleich

| Modell | Input | Output | ~Kosten/Monat |
|--------|-------|--------|---------------|
| Claude Sonnet 4.6 | $3/MTok | $15/MTok | ~$11 |
| GPT-4o | $2,50/MTok | $10/MTok | ~$8 |
| GPT-4o mini | $0,15/MTok | $0,60/MTok | ~$0,50 |

GPT-4o mini ist am günstigsten, Reasoning-Qualität bei Energieoptimierung aber ungetestet.

## Phase 5 – Einspeise-Logik ✅ Live

Batterie ins Netz entladen wenn Überschuss prognostiziert (Solar + SoC deckt Restbedarf) und Tibber-Preis > Einspeisevergütung. In Intraday Adjuster integriert.

- Claude entscheidet: `discharge_action = enable|disable`
- Neue HA Entity: `input_number.min_soc_einspeisen` (10–50%, default 30%)
- Dashboard: Slider für Min-SoC, Einspeise-Status in Intraday-Karte

## Phase 6 – Token-Tracking & Kostenübersicht ✅ Live

Token-Verbrauch und API-Kosten jedes Claude-Aufrufs in InfluxDB gespeichert, täglich/monatlich aggregiert.

- `tokenUsage` aus Agent-Output → InfluxDB `ai_costs` Zeitreihe (Tag: `workflow=intraday|daily`)
- Daily Optimizer aggregiert täglich Tages- und Monatssummen → HA-Sensoren
- Fallback-Schätzung wenn `tokenUsage` nicht verfügbar: 5.000/450 Tokens (Intraday), 4.500/500 (Daily)

**Neue HA Entities:** `sensor.battery_ai_tokens_last_run`, `sensor.battery_ai_cost_today`, `sensor.battery_ai_cost_month`

## Phase 7 – Ersparnis-Tracking ✅ Live

Täglich 23:55 berechnet `savings-tracker.json` die KI-gesteuerte Ersparnis vs. Tagesdurchschnittspreis.

```
Ersparnis = Σ (Energie geladen × Tagesdurchschnitt) − Σ (Energie geladen × tatsächlicher Slot-Preis)
```

- `batteryPower` + `tariffGrid` aus InfluxDB → stündliche Ersparnis pro Slot
- Negative Slots (wenn Slot-Preis > Durchschnitt) werden auf 0 gekürzt
- Tageswert in InfluxDB `battery_savings` gespeichert → Monatssumme aggregiert

**Neue HA Entities:** `sensor.battery_ai_savings_today`, `sensor.battery_ai_savings_month`

## Phase 8 – Stündliche Lastmustererkennung (geplant)

Wiederkehrende Verbrauchsspitzen (z.B. Wärmepumpe 7–9 Uhr) aus InfluxDB erkennen und Claude als stündliches Lastprofil übergeben. Claude berechnet Netto-Bedarf (Lastprofil − PV-Prognose) und plant SoC-Reserve vorausschauend.

- `homePower GROUP BY time(1h)` der letzten 28 Tage → Ø-Verbrauch pro Stunde
- Integration in Daily Optimizer (24h-Profil) + Intraday Adjuster (nächste 6h)
- Timezone-Offset dynamisch via `getTimezoneOffset()`
- Spec: `docs/superpowers/specs/2026-05-29-phase8-stundliche-lastmuster.md`

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
