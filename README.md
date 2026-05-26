# EVCC KI-Automation – Intelligente Hausbatteriesteuerung

KI-gesteuertes System zur kostenoptimierten Ladung der Hausbatterie (RCT Power) aus dem Netz, basierend auf dynamischen Tibber-Strompreisen, Solar-Prognosen und historischen Verbrauchsmustern.

## Wie es funktioniert

Täglich um 14:00 Uhr (sobald Tibber die Preise für den nächsten Tag veröffentlicht) läuft der Daily Optimizer in n8n:

1. Prüft ob KI-Steuerung in Home Assistant aktiv ist
2. **Claude Sonnet** liest via evcc MCP direkt: aktuellen SoC, Tibber-Preise (next 24h, 15-min-Raster), Solar-Prognose morgen
3. Claude berechnet den optimalen Preisschwellwert und setzt ihn direkt in evcc
4. evcc lädt die Batterie automatisch wann immer der Tibber-Preis unter dem Schwellwert liegt
5. n8n schreibt Ergebnis + Begründung nach Home Assistant

Zusätzlich läuft alle 15 Minuten ein Safety Monitor der SoC-Grenzen überwacht und Netzladen/Entladen bei Bedarf deaktiviert.

## Stack

| Komponente | Rolle | Adresse |
|------------|-------|---------|
| **n8n** | Orchestrator (läuft als HA-Addon) | `https://api-workflow.willeke.local` |
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
| Daily Optimizer | ✅ Live | täglich 14:00 |
| Safety Monitor | ✅ Live | alle 15 Minuten |
| HA Override Handler | ⏳ Phase 3 | Webhook von HA |

## Projektstruktur

```
├── docs/
│   ├── setup-phase1.md              # Setup-Anleitung
│   └── superpowers/specs/
│       └── 2026-05-25-battery-ai-design.md  # Design-Spec
├── n8n-workflows/
│   ├── daily-optimizer.json         # Claude + evcc MCP, täglich 14:00
│   ├── safety-monitor.json          # Regelbasiert, alle 15 min
│   └── ha-override-handler.json     # Webhook-Handler (Phase 3)
├── ha-config/
│   ├── input_booleans.yaml          # KI-Schalter, Einspeise-Schalter
│   ├── input_numbers.yaml           # Manueller Schwellwert
│   ├── rest_commands.yaml           # n8n Webhook-Aufruf
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

## Wichtige Erkenntnisse (Setup-Notizen)

- **evcc API**: offen ohne Auth im lokalen Netz
- **evcc Tibber-Preise**: in `forecast.grid[]` (Wert in EUR → ×100 = ct), nicht `tariffGrid`
- **evcc Solar-Prognose**: `forecast.solar.tomorrow.energy` (in Wh → ÷1000 = kWh)
- **n8n als HA-Addon**: `.local` DNS nicht auflösbar im Container → `http://homeassistant:8123` verwenden
- **n8n MCP Node**: `endpointUrl` Parameter wird beim JSON-Import nicht gesetzt → muss manuell eingetragen werden
- **n8n Code-Node mit parallelen Inputs**: crasht mit `.item` → sequentiellen Flow und `.first()` verwenden

## Nächste Phasen

### Phase 2 – InfluxDB Lernkomponente
Echter Verbrauch aus InfluxDB statt Fallback 10 kWh/Tag:
- n8n InfluxDB-Credential: URL `http://a0d7b954-influxdb:8086/`, DB `evcc`, User `evcc`
- Feldnamen verifizieren: `SHOW MEASUREMENTS` in InfluxDB
- Claude bekommt rolling avg Verbrauch nach Wochentag/Stunde (28 Tage)

### Phase 3 – HA Override Handler
Sofortreaktion auf HA-Schalter-Änderungen:
- HA `rest_commands.yaml` einbinden
- Automationen aus `ha-config/automations/battery-ai-webhooks.yaml` einrichten
- `ha-override-handler.json` in n8n importieren und publishen

### Phase 4 – Einspeise-Logik (optional)
Batterie aktiv entladen wenn Tibber-Preis hoch genug.
