# xdevice: запуск и сбор логов без оберток

## Установка

```bash
ACTS=/path/to/acts
pip install --user $ACTS/tools/xdevice-*.tar.gz $ACTS/tools/xdevice-ohos-*.tar.gz
```

## Запуск тестов

```bash
cd $ACTS

# Один модуль
python -m xdevice run acts \
  --testcase testcases/ActsAceButtonTest.json \
  --device_sn <serial> \
  --output /tmp/xdevice_out

# Все модули из директории
python -m xdevice run acts \
  --testcase-dir testcases/ \
  --device_sn <serial> \
  --output /tmp/xdevice_out
```

## На remote сервере

```bash
export PATH=$OHOS_TOOLS_DIR:$PATH
hdc list targets
cd $ACTS
python -m xdevice run acts \
  --testcase testcases/ActsAceButtonTest.json \
  --device_sn <serial> \
  --output /tmp/xdevice_out
```

## Где логи

xdevice сам собирает всё. hilog: делает `hilog -r` перед тестом, `hilog` после.

```
/tmp/xdevice_out/
  <timestamp>/
    result/              <- XML per модуль (pass/fail per testcase)
      ActsAceButtonTest.xml
    log/                 <- hilog с борды per модуль
      ActsAceButtonTest/
        <serial>.log
    summary_report.xml   <- сводка
```

## Структура XML

```xml
<testcase name="testButton_0100" classname="..." result="true"  time="1234"/>
<testcase name="testButton_0200" classname="..." result="false" time="5678" message="Assert failed"/>
```

## Парсинг

```bash
# Сколько модулей с ошибками
grep -rl 'result="false"' /tmp/xdevice_out/*/result/ | wc -l

# Какие тесты упали
grep -h 'result="false"' /tmp/xdevice_out/*/result/*.xml
```

## Ключевые флаги

```
--testcase <json>        путь к testcase JSON
--testcase-dir <dir>     все JSON из директории
--device_sn <serial>     конкретная борда
--output <dir>           куда писать отчеты
--filter <test_name>     фильтр по имени
--repeat <N>             повторить N раз
--help                   все опции
```
