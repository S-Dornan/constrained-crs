# Infrastructure as Code

Experimental Infrastructure as code scripts to run the experiments go here

Current template is customized and untested as at the 18th of June 2026

### The Execution Sequence

**0. Set up the dependencies**
1. Run ```rclone config``` on your personal laptop. Take the resulting ```rclone.conf``` file and drop it in the same folder as the ```vm-config.sh``` file


**1. Build the Base Template**
Run your `setup-template.sh` script on the Proxmox host. This will download the Noble Numbat image and bind it to VM 9001.

```bash
chmod +x setup-template.sh
./setup-template.sh
```

**2. Compile and Provision**
Ensure your `.env` file (with your API key), your completed `rclone.conf` file, and your `cloud-init.yaml` are sitting in the same directory as your `vm-config.sh` script. Run the compiler and watch Proxmox spin up the Cleanroom and the Log Vault.

```bash
chmod +x vm-config.sh
./vm-config.sh

```

**3. Watch the Magic Happen**
Because Cloud-Init runs silently in the background, the VM might look like it's doing nothing from the Proxmox UI. Open the console for `crs-cleanroom` and run this to watch the live installation of Docker, UV, and the GitHub clones:

```bash
tail -f /var/log/cloud-init-output.log

```

If that log finishes with your `Cleanroom provisioned successfully` message, your baseline is officially complete. You can leave the actual resource starvation tests for tomorrow, knowing the factory floor is built and fully operational.