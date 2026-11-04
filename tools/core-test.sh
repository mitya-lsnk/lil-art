#!/bin/bash
# Тесты пакета app/Core. Первая сборка после правки тестов иногда не находит плагин
# макросов Testing (особенность набора инструментов без Xcode): тогда достаточно повторить,
# поэтому скрипт повторяет до четырёх раз.
#   core-test.sh            прогнать тесты
#   core-test.sh coverage   то же и с покрытием
cd "$HOME/lil-art/app/Core"
flags=()
[ "${1:-}" = coverage ] && flags=(--enable-code-coverage)
# a failed attempt that only says the plugin was not found is repeated (up to four times)
for attempt in 1 2 3 4; do
  swift test "${flags[@]}" 2>&1 | tee /tmp/core-test.log >/dev/null
  grep -q "plugin for module 'TestingMacros' not found" /tmp/core-test.log || break
  echo "(плагин тестов не нашёлся, попытка $attempt)"
done
grep -E "error:|✘|Test run with|issue" /tmp/core-test.log | cut -c1-220
grep -q "Test run with .* passed" /tmp/core-test.log
