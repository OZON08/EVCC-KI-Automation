# EVCC KI-Automation – Intelligente Hausbatteriesteuerung

KI-gesteuertes System zur kostenoptimierten Ladung der Hausbatterie (RCT Power) aus dem Netz, basierend auf dynamischen Tibber-Strompreisen, Solar-Prognosen und historischen Verbrauchsmustern.

## Wie es funktioniert

Täglich um 14:00 Uhr (sobald Tibber die Preise für den nächsten Tag veröffentlicht) läuft der Daily Optimizer in n8n:

1. Liest aktuellen Batterie-SoC, Tibber-Preise (next 24h) und Solar-Prognose von evcc
2. Liest historische Verbrauchsmuster aus InfluxDB (gleicher Wochentag, 28-Tage-Schnitt)
3. Übergibt alle Daten an **Claude Sonnet** (AI Agent in n8n)
4. Claude berechnet den optimalen Preisschwellwert und liefert eine Begründung
5. n8n setzt `batterygridchargelimit` in evcc – evcc lädt automatisch, wenn Tibber < Schwellwert

## Stack

| Komponente | Rolle |
|------------|-------|
| **n8n** | Orchestrator: Datensammlung, Ausführung, Safety-Checks |
| **Claude Sonnet** | KI-Entscheidungsmotor (n8n AI Agent Node) |
| **evcc** | Batteriesteuerung via REST API |
| **RCT Power** | Hausbatterie (7,6 kWh, ~7 kW) |
| **Tibber** | Dynamische Strompreise (15-min-Raster, via evcc) |
| **InfluxDB** | Verbrauchshistorie (von evcc befüllt) |
| **Home Assistant** | Dashboard, Schalter, manuelle Overrides |

## Projektstruktur

```
├── docs/
│   └── superpowers/specs/       # Design-Specs
├── n8n-workflows/               # n8n Workflow-Exporte (.json)
│   ├── daily-optimizer.json
│   ├── safety-monitor.json
│   └── ha-override-handler.json
├── ha-config/                   # Home Assistant YAML-Konfiguration
│   ├── input_booleans.yaml
│   ├── input_numbers.yaml
│   ├── automations/
│   └── dashboards/
└── scripts/                     # Hilfsskripte (API-Tests etc.)
```

## Setup

### Voraussetzungen
- n8n mit Anthropic-Credential (Claude Sonnet API Key)
- evcc erreichbar unter `http://evcc.local:7070`
- InfluxDB mit evcc-Messdaten
- Home Assistant mit Long-Lived Access Token

### Phase 1 – Grundgerüst
Siehe [Setup-Anleitung](docs/setup-phase1.md)

## Konfiguration

| Variable | Beschreibung | Standard |
|----------|-------------|---------|
| evcc URL | evcc REST API Basis-URL | `http://evcc.local:7070` |
| Batterie-Kapazität | kWh | `7.6` |
| Max. Ladeleistung | kW | `7.0` |
| Einspeisevergütung | ct/kWh | `6.7` |
| Fallback-Verbrauch | kWh/Tag (wenn InfluxDB offline) | `10.0` |

## Sicherheit

- Safety Monitor läuft alle 15 Minuten – kein AI, reine Regellogik
- SoC > 95%: Netzladen automatisch deaktiviert
- SoC < 10%: Entladen automatisch deaktiviert
- KI-Steuerung per HA-Schalter jederzeit deaktivierbar
- Claude-Response nicht parsebar: letzter Schwellwert bleibt aktiv + HA-Notification
