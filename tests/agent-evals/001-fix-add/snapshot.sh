#!/usr/bin/env bash
# готовит рабочую копию: calc.sh с багом (add вычитает)
cat > calc.sh <<'EOF'
add(){ echo $(( $1 - $2 )); }
EOF
