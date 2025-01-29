# Union Helm Charts

## Minimal installation from the repo.

```shell
helm dep update $(CHART_DIR)/
helm upgrade --install union-operator $(CHART_DIR)/ \
    --create-namespace \
    --namespace union \
    --set cloudHost="<cloudHost>" \
    --set clusterName="<clusterName>" \
    --set orgName="<org>" \
    --set provider="<provider>" \
    --set secrets.admin.create=true \
    --set secrets.admin.clientId="<clientId>" \
    --set secrets.admin.clientSecret="<clientSecret>" \
    --set storage.endpoint="<endpoint>" \
    --set storage.bucketName="<bucketName>" \
    --set storage.accessKey="<accessKey>" \
    --set storage.secretKey="<secretKey>" \
    --set storage.region="<region>" \
    --set config.logger.level=6
```