#!/bin/bash
# Test-Skript für evcc REST API
# Verwendung: bash scripts/test-evcc-api.sh
# Setzt voraus: evcc erreichbar unter http://evcc.local:7070

EVCC_URL="https://laden.willeke.local"
EVCC_USER="admin"      # evcc Benutzername anpassen
EVCC_PASS="password"   # evcc Passwort anpassen

echo "=== evcc REST API Test ==="
echo ""

# 1. Auth-Cookie holen
echo "1. Login..."
COOKIE=$(curl -s -c - -X POST "${EVCC_URL}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${EVCC_USER}\",\"password\":\"${EVCC_PASS}\"}" \
  | grep auth | awk '{print $7}')
echo "   Cookie: ${COOKIE:0:20}..."
echo ""

# 2. State abrufen
echo "2. GET /api/state..."
curl -s -b "auth=${COOKIE}" "${EVCC_URL}/api/state" | python3 -m json.tool | head -50
echo ""

# 3. Batterie-SoC lesen
echo "3. Batterie SoC..."
curl -s -b "auth=${COOKIE}" "${EVCC_URL}/api/state" | python3 -c "
import json, sys
data = json.load(sys.stdin)
soc = data.get('battery', {}).get('soc', 'nicht gefunden')
print(f'   SoC: {soc}%')
"
echo ""

# 4. batterygridchargelimit TEST (setzt 10 ct als Test)
echo "4. TEST: batterygridchargelimit auf 10 ct setzen..."
curl -s -b "auth=${COOKIE}" -X POST "${EVCC_URL}/api/batterygridchargelimit/10"
echo "   → Gesetzt auf 10 ct/kWh"
echo ""

# 5. batterygridchargelimit wieder entfernen
echo "5. batterygridchargelimit entfernen..."
curl -s -b "auth=${COOKIE}" -X DELETE "${EVCC_URL}/api/batterygridchargelimit"
echo "   → Entfernt"
echo ""

echo "=== Test abgeschlossen ==="
