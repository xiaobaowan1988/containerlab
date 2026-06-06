.PHONY: deploy verify teardown bgp routes ping

deploy:
	bash scripts/deploy.sh

verify:
	bash scripts/verify.sh

teardown:
	bash scripts/teardown.sh

bgp:
	@for node in spine1 tor1 tor2 worker1 worker2; do \
		echo "=== $$node ==="; \
		docker exec k8s-bgp-lab-$$node vtysh -c "show bgp summary" 2>/dev/null || true; \
		echo ""; \
	done

routes:
	@echo "=== spine1 routing table ==="; \
	docker exec k8s-bgp-lab-spine1 vtysh -c "show ip route" 2>/dev/null || true

ping:
	@echo "worker2 -> 10.244.1.1 (worker1 pod CIDR):"; \
	docker exec k8s-bgp-lab-worker2 ping -c 3 10.244.1.1 2>/dev/null || true; \
	echo ""; \
	echo "worker1 -> 10.244.2.1 (worker2 pod CIDR):"; \
	docker exec k8s-bgp-lab-worker1 ping -c 3 10.244.2.1 2>/dev/null || true
