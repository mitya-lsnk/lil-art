#!/bin/bash
# Тесты пакета app/Core. Первая сборка после правки тестов иногда не находит плагин
# макросов Testing (особенность набора инструментов без Xcode): тогда достаточно повторить,
# поэтому скрипт повторяет один раз.
#   core-test.sh            прогнать тесты
#   core-test.sh coverage   то же и с покрытием
cd "$HOME/lil-art/app/Core"
flags=()
[ "${1:-}" = coverage ] && flags=(--enable-code-coverage)
if ! swift test "${flags[@]}" 2>&1 | tee /tmp/core-test.log | grep -q "plugin for module 'TestingMacros' not found"; then
  :
else
  echo "(плагин тестов не нашёлся с первого раза, повторяю)"
  swift test "${flags[@]}" 2>&1 | tee /tmp/core-test.log >/dev/null
fi
grep -E "error:|✘|Test run with|issue" /tmp/core-test.log | cut -c1-220
grep -q "Test run with .* passed" /tmp/core-test.log
