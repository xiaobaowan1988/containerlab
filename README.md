# K8s + BGP Network Lab (Containerlab + FRRouting)

模拟 Kubernetes 数据中心的 BGP 网络拓扑，用 FRRouting 容器替代真实交换机和 K8s 节点。

## 拓扑结构

```
                   spine1 (AS 65000)
                  /                 \
          tor1 (AS 65001)     tor2 (AS 65002)
               |                     |
        worker1 (AS 65100)    worker2 (AS 65101)
        Pod CIDR: 10.244.1.0/24  Pod CIDR: 10.244.2.0/24
```

## IP 规划

| 链路              | 节点 A       | 节点 B       | 网段          |
|-------------------|--------------|--------------|---------------|
| spine1 ↔ tor1    | 10.0.0.0/31  | 10.0.0.1/31  | 10.0.0.0/31   |
| spine1 ↔ tor2    | 10.0.0.2/31  | 10.0.0.3/31  | 10.0.0.2/31   |
| tor1 ↔ worker1   | 10.0.1.0/31  | 10.0.1.1/31  | 10.0.1.0/31   |
| tor2 ↔ worker2   | 10.0.1.2/31  | 10.0.1.3/31  | 10.0.1.2/31   |

| 节点    | Loopback       | Pod CIDR (模拟) |
|---------|----------------|-----------------|
| spine1  | 10.255.0.1/32  | —               |
| tor1    | 10.255.0.2/32  | —               |
| tor2    | 10.255.0.3/32  | —               |
| worker1 | 10.255.0.4/32  | 10.244.1.0/24   |
| worker2 | 10.255.0.5/32  | 10.244.2.0/24   |

## 快速开始

```bash
# 部署整个 lab
make deploy

# 查看 BGP 会话状态
make bgp

# 查看路由表
make routes

# 测试跨节点连通性
make ping

# 销毁
make teardown
```

## 手动验证

```bash
# 查看 BGP 邻居
docker exec k8s-bgp-lab-spine1 vtysh -c "show bgp summary"

# 查看完整路由表
docker exec k8s-bgp-lab-spine1 vtysh -c "show ip route"

# 进入交互式 CLI
docker exec -it k8s-bgp-lab-spine1 vtysh
```

## 与真实 KinD 集成

Worker 节点换成真实 KinD 节点时，需要：
1. 在 KinD 节点安装 Calico，启用 BGP 模式（`calico_backend: bird`）
2. 配置 `BGPPeer` 资源，将 ToR 地址作为 peer
3. 在 topology.yaml 中把 worker 改为 `kind: linux` 并使用 KinD 节点的 Docker 网络

## 依赖

- Docker ≥ 20
- [Containerlab](https://containerlab.dev) ≥ 0.50
