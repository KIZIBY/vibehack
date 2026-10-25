#!/usr/bin/env bash
cat > calc.sh <<'EOF'
add(){ echo $(( $1 - $2 )); }
mul(){ echo $(( $1 * $2 )); }
EOF
