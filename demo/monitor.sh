#!/bin/sh
printf '\n'
printf '  SERVICE     CPU     MEM     STATUS\n'
printf '  api         12%%     45%%     running\n'
printf '  worker      8%%      32%%     running\n'
printf '  database    22%%     68%%     running\n'
printf '\n'
printf '16:36:18  monitoring cluster health\n'
exec sleep 3600