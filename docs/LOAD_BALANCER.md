# Load Distribution

ElixirGateway supports active-active load distribution across a cluster of nodes. DNS points to the primary node, which distributes traffic to secondary nodes based on configurable weights.

For full documentation see [CLUSTERING.md](CLUSTERING.md).

## Quick Summary

- **Weight-based routing**: each node declares its own weight (`NODE_WEIGHT`); the primary allocates traffic proportionally
- **Session affinity**: requests from the same client always go to the same node
- **Traffic threshold**: below `MIN_REQ_THRESHOLD` req/min all traffic stays local (avoids unnecessary RPC overhead)
- **Graceful degradation**: if a secondary is unreachable, the primary handles the request locally
- **Dynamic**: nodes can join/leave without reconfiguration

## Configuration

```bash
LOAD_DISTRIBUTION_ENABLED=true
NODE_WEIGHT=70          # relative capacity of this node
MIN_REQ_THRESHOLD=20    # req/min below which all traffic stays local
```

See [CLUSTERING.md](CLUSTERING.md) for the full setup, metrics, and troubleshooting guide.
