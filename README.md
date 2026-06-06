# EVCC KI-Automation – Intelligente Hausbatteriesteuerung

KI-gesteuertes System zur kostenoptimierten Ladung und Entladung der Hausbatterie (RCT Power), basierend auf dynamischen Tibber-Strompreisen, Solar-Prognosen und gemessenen Verbrauchsdaten aus InfluxDB.

## Wie es funktioniert

Täglich um 16:00 Uhr läuft der Daily Optimizer in n8n:

1. Liest den **gemessenen Durchschnittsverbrauch** und das **stündliche Lastprofil** aus InfluxDB (28 Tage, `homePower`)
2. n8n holt via evcc REST API: aktuellen SoC, Tibber-Preise für morgen, Solar-Prognose, Wallbox-Status
3. **Claude Sonnet** berechnet den optimalen Preisschwellwert (Single-Turn, alle Daten bereits im Prompt)
4. n8n setzt den Schwellwert direkt in evcc per REST API
5. evcc lädt die Batterie automatisch wenn der Tibber-Preis unter dem Schwellwert liegt
6. n8n schreibt Ergebnis + Begründung nach Home Assistant

Zusätzlich laufen:
- **Intraday Adjuster** (stündlich 24/7): regelbasiert, passt Schwellwert anhand aktuellem Tibber-Preis vs. Daily-Schwellwert an, steuert Netzeinspeisung – auch nachts für günstige Ladezeiten
- **Savings Tracker** (täglich 23:55): berechnet KI-Ersparnis vs. Tagesdurchschnittspreis
- **Safety Monitor** (alle 15 min): überwacht SoC-Grenzen
- **HA Override Handler**: reagiert sofort auf HA-Schalter-Änderungen via Webhook

## Stack

| Komponente | Rolle | Adresse |
|------------|-------|---------|
| **n8n** | Orchestrator (läuft als HA-Addon) | `http://homeassistant:8081` (intern) |
| **Claude Sonnet** (`claude-sonnet-4-6`) | Tagesplanung (1× täglich, Single-Turn) | Anthropic API |
| **evcc** | Batteriesteuerung via REST API | `http://<EVCC_IP>:7070` |
| **RCT Power** | Hausbatterie (7,6 kWh, ~7 kW) | via evcc |
| **Tibber** | Dynamische Strompreise (15-min-Raster) | via evcc `tariff/grid` |
| **InfluxDB** | Verbrauchshistorie | HA Add-on, db=`evcc` |
| **Home Assistant** | Dashboard, Schalter, Overrides | `http://homeassistant:8123` (intern) |

## Workflows

| Workflow | Trigger | Funktion |
|----------|---------|---------|
| Daily Optimizer | täglich 16:00 + sofort bei KI-Aktivierung + Webhook | Preisschwellwert für morgen per Claude berechnen |
| Intraday Adjuster | stündlich 24/7 | Regelbasiert: Schwellwert prüfen, Einspeisung steuern, nächtliches Laden optimieren |
| Savings Tracker | täglich 23:55 + Webhook | Ersparnis vs. Tagesdurchschnitt berechnen |
| Safety Monitor | alle 15 Minuten | SoC-Grenzen überwachen |
| HA Override Handler | Webhook von HA-Schaltern | Sofortreaktion auf manuelle Eingriffe |

## Features

| Feature | Beschreibung |
|---------|-------------|
| Preisoptimierung | Günstigste Tibber-Slots wählen, Schwellwert mit 5% Puffer setzen |
| Intraday-Regelwerk | Stündlicher Preisvergleich: Laden wenn Preis ≤ Tagesschwellwert, Einspeisung wenn Preis > 6,7 ct |
| EV/Wallbox-Bewusstsein | Fahrzeug-Ladestand und -plan fließen in Claude-Entscheidung ein; Einspeisung pausiert wenn EV lädt |
| Einspeise-Logik | Batterie ins Netz entladen wenn Preis > 6,7 ct/kWh und SoC ausreichend |
| Lastmustererkennung | Stündliches Verbrauchsprofil (28d, gleicher Wochentag) als Claude-Kontext |
| Token-Tracking | API-Kosten pro Lauf in InfluxDB, täglich/monatlich aggregiert in HA |
| Ersparnis-Tracking | Tägliche Kosteneinsparung vs. Tagesdurchschnittspreis in HA |
| Frequenz-Kontrolle | Intraday-Häufigkeit per HA-Dropdown einstellbar (1h / 2h / 3h / 6h) |
| Manuelle Overrides | KI abschaltbar, manueller Schwellwert, Min-SoC für Einspeisung |
| Sensor-Persistenz | HA-Automation stellt alle virtuellen Sensoren nach HA-Neustart automatisch wieder her |

## Projektstruktur

```
├── n8n-workflows/
│   ├── daily-optimizer.json         # Claude Sonnet (Single-Turn) + evcc REST + InfluxDB, täglich 16:00
│   ├── intraday-adjuster.json       # Regelbasiert (kein LLM), stündlich 24/7
│   ├── savings-tracker.json         # Ersparnis-Berechnung, täglich 23:55
│   ├── safety-monitor.json          # Regelbasiert, alle 15 min
│   └── ha-override-handler.json     # Webhook-Handler, Sofortreaktion auf HA-Schalter
├── ha-config/
│   ├── input_booleans.yaml          # KI-Schalter, Einspeise-Schalter
│   ├── input_numbers.yaml           # Manueller Schwellwert, Min-SoC Einspeisen
│   ├── input_selects.yaml           # Intraday-Häufigkeit
│   ├── rest_commands.yaml           # n8n Webhook-Aufrufe von HA
│   ├── automation-restore-sensors.yaml  # Sensor-Wiederherstellung nach HA-Neustart
│   ├── automations/
│   │   └── battery-ai-webhooks.yaml # Schalter → n8n Webhooks
│   └── dashboards/
│       └── battery-ai-dashboard.yaml
└── docs/
    └── superpowers/
        └── specs/                   # Design-Dokumente
```

## Home Assistant Entities

### Manuelle Eingaben (vor Installation anlegen)

| Entity | Typ | Funktion |
|--------|-----|----------|
| `input_boolean.ki_batteriesteuerung_aktiv` | Schalter | KI-Steuerung an/aus |
| `input_boolean.einspeise_logik_aktiv` | Schalter | Einspeise-Logik (optional) |
| `input_number.manueller_preisschwellwert` | Zahl | Override (0 = KI übernimmt) |
| `input_number.min_soc_einspeisen` | Zahl | Minimaler SoC für Einspeisen (10–50%, default 30%) |
| `input_select.intraday_frequenz` | Auswahl | Intraday-Häufigkeit: 1h / 2h / 3h / 6h (default 1h) |

### Sensoren (automatisch von n8n angelegt)

| Entity | Funktion |
|--------|----------|
| `sensor.battery_charge_threshold` | Aktueller Schwellwert + Claude-Begründung |
| `sensor.battery_intraday_adjustment` | Intraday-Aktion + Einspeise-Status + Begründung |
| `sensor.battery_ai_tokens_last_run` | API-Kosten letzter Daily-Optimizer-Lauf |
| `sensor.battery_ai_cost_today` | API-Kosten heute kumuliert (USD) |
| `sensor.battery_ai_cost_month` | API-Kosten Monat kumuliert (USD) |
| `sensor.battery_ai_savings_today` | KI-Ersparnis heute vs. Tagesdurchschnitt (EUR) |
| `sensor.battery_ai_savings_month` | KI-Ersparnis kumuliert Monat (EUR) |

---

## Installation

### Voraussetzungen

- Home Assistant mit installierten Add-ons: **n8n**, **InfluxDB**
- **evcc** im lokalen Netz mit Tibber-Integration und RCT Power Anbindung
- **Anthropic API Key** (console.anthropic.com)
- evcc schreibt Messdaten nach InfluxDB (Datenbank: `evcc`, User: `evcc`)

### Schritt 1: Home Assistant konfigurieren

**1a. YAML-Dateien einbinden**

In `configuration.yaml` folgende Includes ergänzen (falls nicht vorhanden):

```yaml
input_boolean: !include_dir_merge_named input_booleans/
input_number: !include_dir_merge_named input_numbers/
input_select: !include_dir_merge_named input_selects/
rest_command: !include rest_commands.yaml
```

Die Dateien aus `ha-config/` in die entsprechenden HA-Konfigurationsordner kopieren.  
In `ha-config/rest_commands.yaml` die n8n-URL anpassen falls abweichend von `http://homeassistant:8081`.

**1b. Automationen einrichten**

- Inhalt von `ha-config/automations/battery-ai-webhooks.yaml` in die HA-Automationen einfügen
- Inhalt von `ha-config/automation-restore-sensors.yaml` als neue Automation anlegen (stellt Sensoren nach Neustart wieder her)

**1c. Dashboard einrichten**

`ha-config/dashboards/battery-ai-dashboard.yaml` als neues Lovelace-Dashboard einbinden.

**1d. HA neu starten**

> Wichtig: Nach YAML-Änderungen muss HA vollständig neu starten (kein YAML-Reload reicht für Input-Entities).

Alternativ: Input-Entities manuell als Helfer anlegen unter **Einstellungen → Geräte & Dienste → Helfer**:

| Typ | Name | Entity-ID | Optionen/Bereich |
|-----|------|-----------|-----------------|
| Schalter | KI-Batteriesteuerung | `ki_batteriesteuerung_aktiv` | – |
| Schalter | Einspeise-Logik | `einspeise_logik_aktiv` | – |
| Zahl | Manueller Preisschwellwert | `manueller_preisschwellwert` | 0–50, Schritt 0,1 |
| Zahl | Min. SoC Einspeisen | `min_soc_einspeisen` | 10–50, Schritt 5, default 30 |
| Auswahl | Intraday Häufigkeit | `intraday_frequenz` | 1h, 2h, 3h, 6h |

---

### Schritt 2: n8n Credentials anlegen

In n8n unter **Einstellungen → Credentials** drei Credentials anlegen:

| Name (exakt so) | Typ | Werte |
|-----------------|-----|-------|
| `Home Assistant Token` | HTTP Header Auth | Header: `Authorization`, Wert: `Bearer <LONG_LIVED_TOKEN>` |
| `Anthropic – Claude Sonnet` | Anthropic API | API Key aus console.anthropic.com |
| `InfluxDB evcc` | HTTP Basic Auth | User: `evcc`, Password: aus InfluxDB Add-on Konfiguration |

**HA Long-Lived Token erstellen:** HA → Profil → Sicherheit → Langlebige Zugriffstoken → Token erstellen.

---

### Schritt 3: Workflows importieren

Für jeden Workflow in `n8n-workflows/`:

1. n8n öffnen → **Workflows → Neuen Workflow importieren**
2. JSON-Datei auswählen
3. Alle Credentials zuweisen (bei jedem HTTP- und AI-Node prüfen)
4. In `daily-optimizer.json` und `intraday-adjuster.json`: evcc-IP in den HTTP-Nodes prüfen (`http://<EVCC_IP>:7070`)

**Reihenfolge:**
1. `safety-monitor.json`
2. `ha-override-handler.json`
3. `daily-optimizer.json`
4. `intraday-adjuster.json`
5. `savings-tracker.json`

---

### Schritt 4: Workflows aktivieren

Jeden Workflow aktivieren (Toggle oben rechts in n8n). Empfohlene Reihenfolge:

1. Safety Monitor aktivieren
2. HA Override Handler aktivieren
3. Daily Optimizer aktivieren → **manuell triggern** um ersten Schwellwert zu setzen
4. Intraday Adjuster aktivieren
5. Savings Tracker aktivieren

**Erster Test:**
- Daily Optimizer manuell triggern → in HA prüfen ob `sensor.battery_charge_threshold` einen Wert hat
- KI-Schalter in HA auf **An** setzen → Intraday Adjuster sollte beim nächsten vollen Trigger laufen

---

### Schritt 5: Sensoren prüfen

Nach dem ersten erfolgreichen Lauf erscheinen die Sensoren automatisch in HA. Im Dashboard sollten sichtbar sein:
- Aktueller Preisschwellwert (ct/kWh)
- Claude-Begründung
- Intraday-Aktion (keep / update / remove)
- API-Kosten letzter Lauf

---

## Entscheidungslogik

### Daily Optimizer (Claude Sonnet, 1× täglich)

```
Eingabe (von n8n vorberechnet):
  Verfügbare Kapazität = (1 - SoC/100) × 7,6 kWh
  Energiebedarf = Tagesverbrauch (28d ø) − Solar morgen − verfügbare Kapazität
  + EV-Ladeenergie wenn Fahrzeug angeschlossen

Claude entscheidet:
  Wenn Bedarf ≤ 0:  Schwellwert = 0  → n8n entfernt Limit in evcc
  Wenn Bedarf > 0:  günstigste Tibber-Slots wählen bis Bedarf gedeckt
                    Schwellwert = höchster gewählter Slot × 1,05
                    → n8n setzt Limit in evcc
```

Claude berücksichtigt zusätzlich das stündliche Lastprofil (gleicher Wochentag, 28d) um SoC-Reserve für Lastspitzen einzuplanen.

### Intraday Adjuster (regelbasiert, stündlich)

```
Liest: aktueller Tibber-Preis, SoC, EV-Ladestatus, Schwellwert (von Daily Optimizer)

charge_action:
  Schwellwert = 0                          → remove (kein Netzladen)
  Preis ≤ Schwellwert                      → update (jetzt laden)
  Preis > Schwellwert, günstiger Slot <2h  → keep (warten)
  Preis > Schwellwert, kein günstiger Slot → remove

discharge_action:
  EV lädt aktiv                            → disable (Priorität EV)
  Einspeise-Logik aus                      → disable
  SoC < Min-SoC                            → disable
  Preis > 6,7 ct/kWh                       → enable
  sonst                                    → disable
```

### HA Override Handler – Events

| HA-Schalter | Event | Aktion |
|-------------|-------|--------|
| `ki_batteriesteuerung_aktiv` → off | `ai_control_disabled` | evcc: Netzladen sofort deaktivieren |
| `ki_batteriesteuerung_aktiv` → on | `ai_control_enabled` | Daily Optimizer sofort ausführen |
| `einspeise_logik_aktiv` → on | `discharge_enabled` | evcc: Entladen aktivieren |
| `einspeise_logik_aktiv` → off | `discharge_disabled` | evcc: Entladen deaktivieren |

---

## API-Kosten (Anthropic)

Claude Sonnet 4.6: $3 / 1M Input-Tokens, $15 / 1M Output-Tokens

| Workflow | Läufe/Monat | ~Tokens/Lauf | ~Kosten/Monat |
|----------|-------------|--------------|---------------|
| Daily Optimizer (1×/Tag) | 30 | ~3.000 Input + 300 Output | ~$0,13 |
| Intraday Adjuster | – | kein LLM | **€0** |
| **Gesamt** | | | **~$0,13** |

Der Intraday Adjuster nutzt kein LLM mehr – die Entscheidungslogik ist vollständig regelbasiert.

---

## Bekannte Eigenheiten

- **evcc REST API**: Batterylimit-Endpunkt `POST /api/batterygridchargelimit/{wert_eur}` – Wert in EUR/kWh (10 ct = 0,10)
- **evcc Tarif-Struktur**: `GET /api/tariff/grid` liefert `result.rates[]` mit `start`, `end`, `price` (EUR/kWh)
- **evcc Solar-Prognose**: in `result.forecast.solar.tomorrow[]` als Array von `{wh: ...}` Objekten
- **n8n als HA-Addon**: `.local` DNS nicht auflösbar → `http://homeassistant:8123` für HA, IP-Adresse für evcc
- **n8n Code-Node**: parallele Inputs crashen mit `.item` → Named References (`$('Node Name').first()`) verwenden
- **HA → n8n Webhook**: n8n URL intern = `http://homeassistant:8081/webhook/...`; Workflow muss aktiv sein
- **InfluxDB Write (204)**: HTTP 204 No Content = Erfolg; Write-Nodes haben `onError: continueRegularOutput`
- **Virtuelle Sensoren**: `POST /api/states/sensor.*` überleben keinen HA-Neustart → Automation `automation-restore-sensors.yaml` stellt sie nach 2 Minuten wieder her
- **Schwellwert-Sensor fehlt**: Intraday fällt auf `charge_action: keep` zurück solange Daily Optimizer noch nicht gelaufen ist

---

## Unterstützung

Wenn dir dieses Projekt hilft, freue ich mich über einen Kaffee ☕

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ozon-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/ozon)
[![GitHub Sponsor](https://img.shields.io/badge/GitHub-OZON08-181717?style=flat&logo=github)](https://github.com/sponsors/OZON08)
