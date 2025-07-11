```bash
#!/bin/bash
if pgrep -x "hex-cli" > /dev/null; then
  pkill -HUP hex-cli
else
  hex-cli --clipboard; notify.sh "Hex CLI" "Matn is ready."
fi
```