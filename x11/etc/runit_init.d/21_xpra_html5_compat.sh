#!/bin/bash
set -euo pipefail

# Compatibility patch for xpra 5.1.x server with packaged xpra-html5 17.x.
# Some browser keyboard events can lack event.which/event.keyCode. The HTML5
# client then sends a key-action packet whose keyval field is null/None; xpra
# 5.1.x rejects that packet and drops the proxy connection:
#   invalid None value in 'key-action' packet at index 5
# Ignore those browser events before they are encoded into an Xpra packet.

CLIENT_JS=/usr/share/xpra/www/js/Client.js
MARKER=/usr/share/xpra/www/CCC-PATCH.txt

if [ ! -f "$CLIENT_JS" ]; then
    echo "Xpra HTML5 client not found at $CLIENT_JS; skipping compatibility patch."
    exit 0
fi

python3 - <<'PY'
from pathlib import Path

client = Path('/usr/share/xpra/www/js/Client.js')
marker = Path('/usr/share/xpra/www/CCC-PATCH.txt')
text = client.read_text(encoding='utf-8', errors='replace')

replacements = [
    (
        'keycode=event.which||event.keyCode;',
        'keycode=event.which||event.keyCode||0;if(0==keycode)return!0;',
    ),
    (
        'let keycode = event.which || event.keyCode;',
        'let keycode = event.which || event.keyCode || 0;\n    if (keycode === 0) {\n      return true;\n    }',
    ),
]

changed = False
for old, new in replacements:
    if new in text:
        continue
    if old in text:
        text = text.replace(old, new, 1)
        changed = True

if changed:
    client.write_text(text, encoding='utf-8')
    marker.write_text(
        'CCC compatibility patch: ignore HTML5 keyboard events with missing '\
        'keyCode so xpra 5.1.x does not receive key-action packets with '\
        'null keyval.\n',
        encoding='utf-8',
    )
    print(f'Patched {client}')
elif any(new in text for _, new in replacements):
    print(f'{client} already contains CCC keyboard compatibility patch')
else:
    print(
        f'Warning: could not patch {client}: expected xpra-html5 keyboard '
        'keycode pattern not found. Continuing without the CCC keyboard '
        'compatibility patch.'
    )
PY
