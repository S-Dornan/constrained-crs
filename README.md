# The Constrained Cyber Reasoning System; an implementation of the OSS-CRS from Georgia Tech on constrained hardware

Samuel Dornan - 20385853

## Introduction
Cyber Reasoning Systems were first released in 2025 by DARPA in a Grand Challenge which attempted to use Foundation Models to automatically find and fix bugs in open-source software.[1] More recently in March 2026, researchers from Georgia Tech worked with the developers of the flagship Atlantis CRS to reduce the scale of the software down from the clusters of Azure Virtual Machines used in the original Grand Challenge down to a framework which runs on a single workstation PC.[2]

## Problem Statement
The software produced by the research team from Georgia Tech was tested on an Ubuntu workstation with 32 CPU cores and 128 gigabytes of memory. While this is an equivalent specification to an enterprise developer environment, it is a much more advanced and performant setup compared to the average developer. Given this discrepancy in hardware availability, I would like to investigate the feasibility of running the OSS-CRS on hardware that is materially constrained when compared to the original research produced by the research team in Georgia Tech.

## Objectives and Scope
The ultimate objective is to determine if a variant of the OSS-CRS can be successfully deployed on constrained hardware; no more than 8 CPU cores and no more than 32GB of memory, and a bandwidth rate limit of no more than 20MB/s in order to minimize network latency for other users while experiments are ongoing.

## Methodology
Using a Proxmox Virtual Environment, the resources allocated to the execution environment will be initialized with 8 CPU cores and 32GB of RAM, before being tested against synthetic vulnerabilities to determine the ability of the system to find and fix vulnerabilities. Each run will have its allocated resources progressively scaled down by 2 cores, 8GB of memory, and 5MB/s of bandwidth per run to determine the hardware constraints of the underlying software. Performance will be evaluated based on the success or failure of relevant experimentation runs over a period of no more than 24 hours per run. A successful experimental run is defined as the ability of the system to initialize the environment, to initialize the bug finding CRS, and to initialize the bug fixing CRS, with each individual stage limited to a maximum of 6 hours (21600 seconds), and a 2 hour buffer period for experimental logistics (log capture etc). Failure is defined as any of the inability of the system to start, the inability of the system to initialize the bug finding CRS, and the inability of the system to initialize the bug fixing CRS within the allocated time frame.

## Milestones and Timeline
* Environment baseline & formalization; Infrastructure as Code scripts to create and reproduce the experimentation environment (Expected completion: 26th June 2026)
* Resource degradation experimentation and data capture; Formal experimentation to determine the ability of the system to operate on progressively constrained hardware. (Expected completion: 24th of July 2026)
* Data analysis; Analysis of experimental performance data and log data (Expected completion: 31st July 2026) 
* First draft review and challenge; First draft of 7,500 word research paper submitted for supervisory review and challenge (Expected completion: 14th of August 2026)
* Second draft review and challenge (optional but recommended); Second draft of 7,500 word research paper with corrections from first review and challenge submitted for supervisory review (Expected completion: 21st August 2026)
* Final submission; Final submission of 7,500 word research paper submitted via Brightspace (Expected completion: 24th August 2026)

## References
[1]	Defence Advanced Research and Projects Agency. "AI Cyber Challenge." https://github.com/aixcc-public (accessed 30 April, 2026).

[2]	A. Chin et al., "OSS-CRS: Liberating AIxCC Cyber Reasoning Systems for Real-World Open-Source Security," arXiv preprint arXiv:2603.08566, 2026.

