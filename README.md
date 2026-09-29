# outegro-dev/gitops

Желаемое состояние production-кластера outegro.dev. Argo CD следит только за этим репозиторием и приводит кластер к тому, что лежит в `master`. Код приложений — в [outegro-dev/platform](https://github.com/outegro-dev/platform).

## Структура

```text
node/          подготовка VPS: bootstrap, SSH, firewall, K3s, Argo CD, секреты
bootstrap/     root.yaml — единственное приложение, которое применяется руками
applications/  приложения Argo CD (app of apps), по одному на компонент
platform/      кластерные компоненты: Argo CD, Sealed Secrets, cert-manager,
               CloudNativePG, Barman Cloud, выпуск сертификатов
apps/production/  сервисы outegro.dev и их данные: PostgreSQL, Valkey, RabbitMQ,
               приложения, миграции (PreSync), Sealed Secrets
```

Версии сторонних компонентов закреплены в `platform/*/kustomization.yaml`. Обновление — PR со сменой версии в URL.

## Как попадает релиз

1. Слияние в `master` репозитория `platform` → CI проверяет, собирает образы `ghcr.io/outegro-dev/<app>:<commit>`.
2. CI коммитит сюда новый тег в `apps/production/kustomization.yaml` (блок `images`).
3. Argo CD видит коммит: PreSync-миграции → выкатка → проверки готовности.

Откат — `git revert` коммита с тегом. Изменения инфраструктуры — обычные коммиты сюда.

## Секреты

Только Sealed Secrets: зашифрованы ключом контроллера и безопасны в git. Открытые значения не покидают сервер:

```text
# новое значение ключа провайдера — на сервере
<KEY=value> | ssh outegro-prod 'sudo bash /tmp/secrets.sh'
# зашифровать в репозиторий
ssh outegro-prod 'sudo bash -s -- outegro/<name>' < node/seal.sh > apps/production/secrets/<name>.yaml
```

Приватный ключ контроллера Sealed Secrets и ключ шифрования K3s хранятся у владельца: без них этот репозиторий не восстановить на новом сервере.

## Новый сервер

`node/`: `bootstrap.sh` → `harden-ssh.sh` → `firewall.sh` → `install-k3s.sh` → `install-argocd.sh` (выведет deploy-ключ для GitHub) → восстановить ключ Sealed Secrets → `kubectl apply -f bootstrap/root.yaml`. Остальное Argo CD поднимет сам.

## Доступ к Argo CD

Интерфейс наружу не опубликован:

```text
ssh -L 8080:localhost:8080 outegro-prod 'sudo k3s kubectl -n argocd port-forward svc/argocd-server 8080:443'
# https://localhost:8080, пользователь admin, пароль:
ssh outegro-prod "sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```
