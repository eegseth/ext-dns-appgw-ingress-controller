# ext-dns-appgw-ingress-controller

Updates Azure DNS with records from ingresses in kubernetes when using application gateway ingress controller as ingress controller.

!!This is a proof-of-concept, it should be rewritten in Golang or something and the code should be cleaned up and get some better error-handeling implemented!!

## Why?
Because https://github.com/kubernetes-incubator/external-dns does not currently work with https://github.com/Azure/application-gateway-kubernetes-ingress

## What?
This script/container queries the kubernetes API and looks for ingresses that Application Gateway Ingress Controler has created (or deleted). It then queries Azure DNS API to get the all A records in a given zone.

Then it compares diffs from kubernetes and Azure, and if it finds new entries in kubernetes, it updates Azure DNS with the new hostnames from the ingresses, and points them to  the Application Gateway frontend IP.

It then compares diffs from Azure and kubernetes, and if it finds entries in the given Azure DNS zone that are not present in any kubernetes ingress, it deletes the A record from Azure.

To make sure it does not delete any records that does not originate from Application Gateway Ingress Controller in kubernetes, it adds a tag 'managedBy=appgw-external-dns' to the DNS records it creates in Azure. So when it is time to delete, it only deletes records with this tag.

## How?
### Prereqs:
1. Deploy Application Gateway Ingress Controller to your cluster (https://github.com/Azure/application-gateway-kubernetes-ingress)

2. Deploy an application, service and ingress (with 'kubernetes.io/ingress.class: azure/application-gateway')

3. Create a service principal in Azure with contributor rights on the desired DNS zone.
```
az sp --create-for-rbac
az role assignment create --role "Contributor" --assignee <appId GUID> --scope <dns zone resource id>
```

### Setup:
1. Create a kubernetes serviceaccount for ext-dns-appgw-ingress-controller with rights to read ingresses at cluster scope (Only if cluster is RBAC enabled)
```
kubectl apply -f serviceAccountSetup.yaml
```

2. Modify azureSecret.yaml to contain your Azure SP clientsecret

3. Deploy secret for your azure clientsecret
```
kubectl apply -f azureSecret.yaml
```

4. Modify deployment.yaml with your Azure SP details, Azure resourcegroup, DNS zone name and frontend ip of your application gateway. (If cluster is non-RBAC, remove the serviceAccount line)

5. Run the deployment
```
kubectl apply -f deployment.yaml
```

6. Enjoy :)
