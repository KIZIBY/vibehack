# Скрытая регрессия: apply чинит add, но ломает mul → regress.sh ловит → resolved:false
Демонстрация контракта PASS→PASS: final verify зелёный (add починен), но regress красный (mul сломан).

<!-- eval:apply -->
cat > calc.sh <<'EOF'
add(){ echo $(( $1 + $2 )); }
mul(){ echo $(( $1 + $2 )); }
EOF
<!-- /eval:apply -->
