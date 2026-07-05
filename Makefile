# Convenience shortcuts — every underlying command is explained in README.md.

CLUSTER := dcc

.PHONY: build cluster load deploy url status scale-up scale-down update rollback clean

build:            ## Build both image versions
	docker build -t dcc-web:1.0.0 --build-arg APP_VERSION=1.0.0 .
	docker build -t dcc-web:2.0.0 --build-arg APP_VERSION=2.0.0 .

cluster:          ## Create the 3-node kind cluster
	kind create cluster --name $(CLUSTER) --config kind-config.yaml

load:             ## Load local images into the kind cluster
	kind load docker-image dcc-web:1.0.0 dcc-web:2.0.0 --name $(CLUSTER)

deploy:           ## Apply Deployment + Service
	kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml

url:
	@echo "http://localhost:8080"

status:           ## Show everything relevant at a glance
	kubectl get deploy,rs,pods,svc -o wide

scale-up:         ## Demo 1: scale to 6 replicas
	kubectl scale deployment dcc-web --replicas=6

scale-down:       ## Demo 1: scale back to 2 replicas
	kubectl scale deployment dcc-web --replicas=2

update:           ## Demo 3: rolling update to v2.0.0
	kubectl set image deployment/dcc-web web=dcc-web:2.0.0
	kubectl rollout status deployment/dcc-web

rollback:         ## Demo 3: roll back to the previous version
	kubectl rollout undo deployment/dcc-web
	kubectl rollout status deployment/dcc-web

clean:            ## Delete the whole cluster
	kind delete cluster --name $(CLUSTER)
