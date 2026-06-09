cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: crs-nvidia-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: crs-nvidia-plugin
  template:
    metadata:
      labels:
        app: crs-nvidia-plugin
    spec:
      tolerations:
      - operator: "Exists"
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.19.0
        name: crs-nvidia-plugin-ctr
        env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: all
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: compute,utility
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
EOF