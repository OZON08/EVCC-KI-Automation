# EVCC KI-Automation – Intelligente Hausbatteriesteuerung

KI-gesteuertes System zur kostenoptimierten Ladung der Hausbatterie (RCT Power) aus dem Netz, basierend auf dynamischen Tibber-Strompreisen, Solar-Prognosen und gemessenen Verbrauchsdaten aus InfluxDB.

## Wie es funktioniert

Täglich um 14:00 Uhr (sobald Tibber die Preise für den nächsten Tag veröffentlicht) läuft der Daily Optimizer in n8n:

1. Prüft ob KI-Steuerung in Home Assistant aktiv ist
2. Liest den **gemessenen Durchschnittsverbrauch** für den gleichen Wochentag aus InfluxDB (28 Tage, `homePower`)
3. **Claude Sonnet** liest via evcc MCP: aktuellen SoC, Tibber-Preise (next 24h, 15-min-Raster), Solar-Prognose morgen
4. Claude berechnet den optimalen Preisschwellwert und setzt ihn direkt in evcc
5. evcc lädt die Batterie automatisch wann immer der Tibber-Preis unter dem Schwellwert liegt
6. n8n schreibt Ergebnis + Begründung nach Home Assistant

Zusätzlich laufen:
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
│   ├── input_numbers.yaml           # Manueller Schwellwert
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
| `sensor.battery_charge_threshold` | Sensor | Aktueller Schwellwert + Claude-Begründung |

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
5. Claude entscheidet: `keep` / `update` (setBatteryGridChargeLimit) / `remove` (removeBatteryGridChargeLimit)
6. Ergebnis → `sensor.battery_intraday_adjustment` in HA

**Setup:** In n8n importieren, Credentials zuweisen (Home Assistant Token, InfluxDB evcc, Anthropic), MCP endpointUrl manuell eintragen, aktivieren.

**Neue HA Entity:**

| Entity | Inhalt |
|--------|--------|
| `sensor.battery_intraday_adjustment` | state: keep/update/remove, Attribute: threshold_ct, reasoning, last_updated |

## API-Kosten (Anthropic)

Claude Sonnet 4.6: $3 / 1M Input-Tokens, $15 / 1M Output-Tokens

Pro Lauf ca. 4.500 Input- + 400 Output-Tokens (System-Prompt + MCP-Responses von getState + getTariffInfo).

| Workflow | Läufe/Monat | Kosten/Monat |
|----------|-------------|--------------|
| Intraday Adjuster (17×/Tag) | 510 | ~$10 |
| Daily Optimizer (1×/Tag) | 30 | ~$0,60 |
| **Gesamt** | | **~$10–15** |

Sparpotenzial: Intraday-Trigger auf alle 2h reduzieren (`0 6-22/2 * * *`) → ~$5–8/Monat.

## Phase 5 – Einspeise-Logik (optional)

Batterie aktiv entladen wenn Tibber-Preis hoch genug:
- Einspeise-Schwellwert berechnen (Tibber-Preis > Einspeisevergütung 6,7 ct + Puffer)
- `batterydischargecontrol` in Daily Optimizer integrieren
- HA-Schalter `einspeise_logik_aktiv` bereits verdrahtet
