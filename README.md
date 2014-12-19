To run:

```
ssh-keygen -f id_rsa -t rsa -q -N ""
heat stack-create -f rpc_multi_node.yml rpc -P "key_name=<keyname>;rpc_version=<branch/tag>;cluster_prefix=<prefix>" -t 150
```

(Replace `<keyname>` with your nova key, `<branch/tag>` with the desired RPC version to deploy and <prefix> with the prefix to use in all the instances)

Failing to specify `-t 150` will result in the stack-create timing out and failing as a result.
