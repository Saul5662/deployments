# AMD GPU Drivers

Installs AMD GPU drivers, ROCm compute stack, and amdgpu-fan on Ubuntu hosts.

> **Scope:** This role targets the specific AMD driver and ROCm versions used
> by the AI Horde worker stack. It is not a general-purpose GPU driver role.
>
> **Assumptions and quirks:**
> - **Requires Ubuntu 22.04 (Jammy)** — the amdgpu-install .deb URL is
>   hardcoded to the Jammy repository.
> - **Triggers an automatic reboot** after kernel module installation via
>   handler. Plan accordingly.
> - The `amdgpu-fan` Python package is installed without a version pin.

# Instructions
