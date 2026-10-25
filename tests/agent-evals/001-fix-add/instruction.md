# Почини add()
`calc.sh` содержит `add()`, который вычитает вместо сложения. Сделай так, чтобы `add 2 3` возвращало 5.

<!-- eval:apply -->
cat > calc.sh <<'EOF'
add(){ echo $(( $1 + $2 )); }
EOF
<!-- /eval:apply -->
