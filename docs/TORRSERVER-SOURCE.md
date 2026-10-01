# Исходники встроенного TorrServer

KinoStream 0.1.x включает неизменённый официальный исполняемый файл `TorrServer-darwin-arm64` из TorrServer MatriX.145. При упаковке добавляется только локальная подпись macOS.

- Проект: https://github.com/YouROK/TorrServer
- Версия: https://github.com/YouROK/TorrServer/releases/tag/MatriX.145
- Исходники: https://github.com/YouROK/TorrServer/tree/MatriX.145
- Архив в релизе KinoStream: `TorrServer-MatriX.145-source.tar.gz`.
- Лицензия: GPL-3.0, полный текст в архиве и `KinoStream.app/Contents/Resources/ThirdPartyLicenses/TorrServer-GPL-3.0.txt`.
- SHA-256 исходного бинарника до добавления подписи: `2b1d47a2b6c57f891413fe19e28439647b3b7f02b751b8a129d848770308e864`.

Архив включает исходники сервера и веб-интерфейса, манифесты зависимостей Go/JavaScript, исходный скрипт `build-all.sh` и workflow `.github/workflows/ts_build.yml`. Требования и команды сборки смотрите в этих файлах и README архива. Для macOS требуется целевая платформа `darwin/arm64`; точные параметры официальной сборки сохранены в workflow версии.

KinoStream запускает сервер отдельным процессом, задаёт локальный адрес `127.0.0.1` и собственную директорию данных. Настройки с отключённым сетевым обнаружением находятся в `KinoStream/Vendor/TorrServer/default-settings.json`.
