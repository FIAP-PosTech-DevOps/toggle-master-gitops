# ToggleMaster — GitOps

Estado desejado dos 5 microsserviços do ToggleMaster em cada ambiente. O ArgoCD de cada cluster lê este repositório e aplica o que estiver na `main`. **Ninguém roda `kubectl apply` à mão**: para mudar algo em um ambiente, faça um commit aqui.

Este repositório tem **só manifestos**. O código de cada serviço, o Dockerfile e a pipeline de CI ficam no repositório do serviço; a infraestrutura (EKS, ArgoCD, OpenBao) fica no `toggle-master-infra`.

## Estrutura

```
toggle-master-gitops/
├── apps/                          uma pasta por microsserviço (Kustomize)
│   └── <serviço>/
│       ├── base/                  igual nos 3 ambientes
│       │   ├── namespace.yaml     namespace próprio, Pod Security "restricted"
│       │   ├── serviceaccount.yaml
│       │   ├── externalsecret.yaml   segredos vindos do OpenBao (nunca o valor)
│       │   ├── db-migration-job.yaml aplica db/init.sql antes de cada rollout
│       │   ├── deployment.yaml, service.yaml, ingress.yaml
│       │   └── hpa.yaml | keda.yaml  autoscaling (evaluation / analytics)
│       └── overlays/
│           ├── develop/           kustomization.yaml: TAG DA IMAGEM + região/fila/IRSA do ambiente
│           ├── staging/
│           └── production/
├── platform/                      ClusterSecretStore (ESO -> OpenBao)
├── clusters/                      o que o ArgoCD de cada ambiente lê
│   ├── develop/                   AppProject + Application "platform" + ApplicationSet dos serviços
│   ├── staging/
│   └── production/                idem, com janela de deploy (sync window)
└── scripts/set-aws-account.sh
```

**Kustomize para as aplicações próprias, Helm para ferramentas de terceiros.** ArgoCD, OpenBao, External Secrets, KEDA e ingress-nginx são instalados por Helm, via Terraform (`toggle-master-infra/terraform/cluster-addons`).

## Como o ArgoCD monta os ambientes

```
Terraform (cluster-addons)  ->  Application "root"  ->  clusters/<ambiente>/
                                                        ├── AppProject togglemaster
                                                        ├── Application platform     -> platform/
                                                        └── ApplicationSet           -> 1 Application por pasta
                                                                                        apps/*/overlays/<ambiente>
```

- **Uma Application por serviço.** O deploy do auth-service não toca o flag-service, e o rollback de um não afeta os outros.
- **Serviço novo = pasta nova.** O ApplicationSet descobre `apps/*/overlays/<ambiente>` sozinho, sem editar YAML do ArgoCD.
- **Sync automático com `prune` e `selfHeal`.** O que for removido do Git sai do cluster, e mudança manual no cluster é revertida para o que está no Git.

## Como uma versão chega a um ambiente

A única linha que muda num deploy é o `newTag` em `apps/<serviço>/overlays/<ambiente>/kustomization.yaml`:

```yaml
images:
  - name: flag-service
    newName: <conta>.dkr.ecr.us-east-1.amazonaws.com/togglemaster/flag-service
    newTag: v1.0.1-a1b2c3d    # <- a CI altera esta linha
```

| Evento no repositório do serviço | Quem altera | Overlay |
|---|---|---|
| push em `release/vX.Y.Z` | CI (build + push da imagem) | `develop` |
| botão "Promover p/ staging" (tag `vX.Y.Z-rc.N`) | CI, copiando a tag de develop | `staging` |
| botão "Promover p/ produção" (tag `vX.Y.Z`) | CI, copiando a tag de staging | `production` |

A imagem é construída **uma vez**. Promover é copiar o mesmo `newTag` para o overlay seguinte.

**Rollback:** `git revert` do commit que alterou o `newTag`. O ArgoCD volta a imagem anterior no próximo ciclo (até 60 s).

**Janela de produção:** em `clusters/production/project.yaml`, os serviços só sincronizam em dias úteis, das 10h às 18h (horário de Brasília). Fora da janela, a mudança fica `OutOfSync` esperando. Um sync manual pela interface continua permitido, para hotfix.

## Segredos

Nenhum valor sensível está neste repositório. Cada `ExternalSecret` diz de onde buscar no OpenBao, e o External Secrets Operator cria o `Secret` no cluster:

| Serviço | Caminho no OpenBao | Chaves |
|---|---|---|
| auth-service | `secret/togglemaster/auth-service` | `DATABASE_URL`, `MASTER_KEY` |
| flag-service | `secret/togglemaster/flag-service` | `DATABASE_URL` |
| targeting-service | `secret/togglemaster/targeting-service` | `DATABASE_URL` |
| evaluation-service | `secret/togglemaster/evaluation-service` | `SERVICE_API_KEY`, `REDIS_URL` |

Os valores são gravados por `toggle-master-infra/scripts/openbao-bootstrap.sh`. O workflow de validação reprova qualquer PR que tente commitar um `kind: Secret`.

## Migração de banco

auth-service, flag-service e targeting-service têm um `Job` de migração, um hook `Sync` do ArgoCD, que roda **antes** do Deployment a cada sincronização:

```
onda -2  Namespace, ServiceAccount
onda -1  ExternalSecret (cria a DATABASE_URL), ConfigMap com o SQL
onda  0  Job de migração (psql -f init.sql)      <- se falhar, o sync para aqui
onda  1  Deployment
```

O SQL é idempotente (`CREATE TABLE IF NOT EXISTS`...). No auth-service, o Job também registra o hash da `SERVICE_API_KEY` do evaluation-service na tabela `api_keys`, o passo manual `bootstrap-apikey.sh` da Fase 2.

`apps/<serviço>/base/db/init.sql` é cópia do `db/init.sql` do repositório do serviço. Ao mudar o schema lá, atualize aqui no mesmo ciclo de release.

## Primeira configuração

1. **Troque o account ID** (imagens, roles IRSA, filas):
   ```bash
   ./scripts/set-aws-account.sh "$(aws sts get-caller-identity --query Account --output text)"
   git commit -am "chore: configura o account ID da AWS"
   ```
2. **Repositório privado?** Cadastre a credencial de leitura no ArgoCD de cada ambiente (`toggle-master-infra/scripts/argocd-repo-credentials.sh`). Repositório público dispensa esse passo.
3. **Suba o ambiente** pelo `toggle-master-infra` (`tf.sh infra`, `tf.sh cluster-addons` e `openbao-bootstrap.sh`). O ArgoCD encontra este repositório sozinho.

Até a primeira imagem ser publicada pela CI, os overlays apontam para `v0.0.0` e os pods ficam em `ImagePullBackOff`. É esperado.

## Validar localmente

```bash
kubectl kustomize apps/evaluation-service/overlays/develop      # o YAML final de um serviço
kubectl kustomize clusters/production                           # o que o ArgoCD de production lê
```

No PR, o `.github/workflows/validate.yml` faz o mesmo para todos os overlays e valida o resultado com kubeconform, incluindo os CRDs (ExternalSecret, ScaledObject, Application).

## Acessar o ArgoCD

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# http://localhost:8080  usuário: admin
```
