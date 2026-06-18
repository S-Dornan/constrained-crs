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

If that log finishes with your `Cleanroom provisioned successfully` message, your baseline is officially complete and your environment will run the smoke tests and experiments.

**4. Run the smoke tests**

Run the smoke tests with the `run-smoketests.sh` file. It should take about an hour

```bash
chmod +x run-smoketests.sh
nohup ./run-smoketests.sh > smoketest-execution.log 2>&1 &
```

You can view the output of the smoke tests with the folowing command:
```bash
tail -f smoketest-execution.log
```

And when you've seen enough of that you can exit the viewer with `Ctrl-C`, the smoke tests will continue to run for the next hour.

It's also worth noting that the experiment includes push monitors which are powered by Uptime Kuma; make sure those monitors are out of maintenance mode of you'd like to receive alerts on the length of time these are taking.

Once those smoke tests have run and passed, you can kill the task with `pkill -f run-smoketests.sh`