# Infrastructure as Code

Experimental Infrastructure as code scripts to run the experiments go here

Current template is customized and validated as at the 26th of July 2026

### Prerequisites

* Server with [Proxmox VE installed,](https://www.proxmox.com/en/products/proxmox-virtual-environment/get-started) DHCP for the virtual machines created by the system, and shell access over the web interface.
  > [!NOTE]
  > It **is** possible to run these experiments with shell access restricted to users on the LAN only, inbound access to the hypervisor from the internet is not required.

  > [!Caution]
  > 
  > * Outbound access from the hypervisor to the internet is required.
  > * Outbound access from the cleanroom to the internet is required in the setup phase.
  > * Outbound access from the logging VM to the internet is required at all times.
* Git installed on the hypervisor
* Rclone installed on your development environment.
* [Optional] Uptime Kuma set up and running

### The Execution Sequence

**0. Set up the dependencies**

Run ```rclone config``` on your development environment. Take the resulting ```rclone.conf``` file and drop it in the same folder as the ```vm-config.sh``` file

> [!Caution]
> 
>The ```rclone.conf``` file enables anyone with access to the file and ```rclone``` installed to access the remote environment. Do not share it with anyone who does not have a documented need to access it, and do not save it to the Git repository.

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

**3. Watch the Setup Happen**

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

Once those smoke tests have run and passed, you can kill the task with 

```bash
pkill -f run-smoketests.sh
```

When the time comes to run the experiments, you can run them with the `run-experiments.sh` file. This operates similarly to the smoke tests you saw earlier.

```bash
chmod +x run-experiments.sh
nohup ./run-experiments.sh > experiment-execution.log 2>&1 &
```

You can view the output of the smoke tests with the folowing command:
```bash
tail -f experiment-execution.log
```

And when you've seen enough of that you can exit the viewer with `Ctrl-C`, the smoke tests will continue to run for the next hour.

In the event you need to interrupt the experiments, you can interrupt them with

```bash
pkill -f run-experiments.sh
```

This should be expected to have a material impact on the system however, and it's strongly recommended that after you run this command you leave the system in its slightly degraded state for at least 15 minutes so that it can settle and any available data in the log vault can be synced to the cloud.

When you're finished with the infrastructure, you can delete it all with 

```bash
chmod +x teardown.sh
./teardown.sh
```

**Keep in mind that this will destroy all data on all associated machines.**