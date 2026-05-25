# Setup Phase 1 – Grundgerüst

## Voraussetzungen

- [ ] n8n läuft und ist erreichbar
- [ ] evcc läuft unter `http://evcc.local:7070` (oder eigene IP)
- [ ] Home Assistant läuft mit Long-Lived Access Token
- [ ] Anthropic API Key vorhanden

---

## Schritt 1: evcc API testen

```bash
# API testen (evcc URL und Credentials anpassen)
bash scripts/test-evcc-api.sh
```

Prüfe ob:
- Login funktioniert (Cookie erhalten)
- `/api/state` JSON zurückgibt
- `batterygridchargelimit` setzbar und löschbar ist

---

## Schritt 2: n8n Credentials anlegen

### Anthropic (Claude Sonnet)
1. n8n → Settings → Credentials → Add Credential
2. Typ: `Anthropic`
3. API Key eintragen
4. Name: `Anthropic – Claude Sonnet`

### evcc (Cookie Auth)
1. n8n → Settings → Credentials → Add Credential
2. Typ: `Generic Credential` → `Cookie Auth`
3. Cookie Name: `auth`
4. Cookie Value: *(wird beim Login dynamisch gesetzt – Alternativ: HTTP Request Node mit Login-Step)*
5. Name: `evcc Cookie`

**Hinweis:** evcc Auth-Cookie läuft ab. Empfehlung: Jeden Workflow mit einem Login-Step beginnen und Cookie per `Set Item` weiterreichen. Alternativ: evcc ohne Passwort-Schutz im lokalen Netz betreiben.

### Home Assistant
1. n8n → Settings → Credentials → Add Credential
2. Typ: `HTTP Header Auth`
3. Name: `Authorization`
4. Value: `Bearer <dein-ha-long-lived-token>`
5. Name: `Home Assistant Token`

---

## Schritt 3: n8n Workflows importieren

1. n8n → Workflows → Import from File
2. Importiere in dieser Reihenfolge:
   - `n8n-workflows/ha-override-handler.json`
   - `n8n-workflows/safety-monitor.json`
   - `n8n-workflows/daily-optimizer.json`

3. **URLs anpassen** in allen Workflows:
   - `evcc.local:7070` → deine evcc-IP/URL
   - `homeassistant.local:8123` → deine HA-IP/URL
   - `n8n.local` → deine n8n-URL

4. Im `ha-override-handler.json`: `DAILY-OPTIMIZER-ID` mit echter Workflow-ID ersetzen

5. In allen HTTP-Nodes: Credentials den oben angelegten zuweisen

6. Claude Node: Modell auf `claude-sonnet-4-6` setzen

---

## Schritt 4: Home Assistant konfigurieren

### Input Entities
In `configuration.yaml` einfügen:
```yaml
input_boolean: !include ha-config/input_booleans.yaml
input_number: !include ha-config/input_numbers.yaml
```

### REST Command
```yaml
rest_command: !include ha-config/rest_commands.yaml
```

URL in `rest_commands.yaml` auf deine n8n-Webhook-URL anpassen.

### Automationen
In `automations.yaml` oder als `!include`:
```yaml
automation: !include_dir_merge_list ha-config/automations/
```

### HA neu starten
```
Einstellungen → System → Neustart
```

---

## Schritt 5: InfluxDB-Feldnamen verifizieren

evcc schreibt Messdaten in InfluxDB. Die genauen Feldnamen müssen geprüft werden:

```bash
# In InfluxDB CLI oder Grafana:
# Verfügbare Measurements anzeigen:
SHOW MEASUREMENTS

# Felder in Measurement anzeigen:
SHOW FIELD KEYS FROM "gridPower"
# oder:
SELECT * FROM "gridPower" LIMIT 5
```

Tatsächlichen Measurement-Namen in `daily-optimizer.json` unter `InfluxDB: Verbrauchshistorie` anpassen.

---

## Schritt 6: Erster Test

1. Safety Monitor aktivieren (n8n Workflow aktivieren)
2. Daily Optimizer manuell ausführen (n8n → Execute Workflow)
3. Prüfen ob in evcc ein `batterygridchargelimit` gesetzt wurde
4. Prüfen ob HA-Sensor `sensor.battery_charge_threshold` aktualisiert wurde

---

## Bekannte Stolpersteine

| Problem | Lösung |
|---------|--------|
| evcc Auth-Cookie läuft ab | Login-Step in jeden Workflow einbauen |
| InfluxDB-Feldname falsch | `SHOW MEASUREMENTS` in InfluxDB ausführen |
| Claude gibt kein JSON zurück | System Prompt präzisieren; Fallback-Handler prüfen |
| n8n webhook URL nicht erreichbar von HA | n8n-URL und Port in HA-Netzwerk erreichbar? |
| evcc `batterygridchargelimit` immer 0 | Prüfe ob evcc-Tariff korrekt konfiguriert (Tibber muss als dynamic tariff hinterlegt sein) |
